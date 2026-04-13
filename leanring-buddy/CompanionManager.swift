//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for Clicky's text-first workflow.
//

import AppKit
import Combine
import Foundation
import KeyboardShortcuts
import SwiftUI

enum CompanionInterfaceState {
    case idle
    case composing
    case processing
    case streaming
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var interfaceState: CompanionInterfaceState = .idle
    @Published private(set) var hasScreenRecordingPermission = false
    @Published var promptDraft: String = ""
    @Published var composerValidationMessage: String?
    @Published private(set) var lastPromptSubmitted: String?
    @Published private(set) var displayedResponseText: String = ""
    @Published var detectedElementScreenLocation: CGPoint?
    @Published var detectedElementDisplayFrame: CGRect?
    @Published var detectedElementBubbleText: String?
    @Published private(set) var promptEditorFocusToken: Int = 0

    let settingsStore = ClickySettingsStore()
    let overlayWindowManager = OverlayWindowManager()
    let responseOverlayManager = CompanionResponseOverlayManager()

    private lazy var promptComposerPanelManager = PromptComposerPanelManager(companionManager: self)

    private var conversationHistory: [(userPrompt: String, assistantResponse: String)] = []
    private var currentResponseTask: Task<Void, Never>?
    private var activeRequestIdentifier: UUID?
    private var registeredShortcutHandler = false

    var canSendPromptDraft: Bool {
        !promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var shouldShowSettingsPanelOnLaunch: Bool {
        !settingsStore.isConfigurationComplete || !settingsStore.hasConfiguredShortcut || !hasScreenRecordingPermission
    }

    var statusText: String {
        if !settingsStore.isConfigurationComplete {
            return "Settings needed"
        }

        if !settingsStore.hasConfiguredShortcut {
            return "Set a shortcut"
        }

        if !hasScreenRecordingPermission {
            return "Grant screen access"
        }

        switch interfaceState {
        case .idle:
            return "Ready"
        case .composing:
            return "Composing"
        case .processing:
            return "Thinking"
        case .streaming:
            return "Streaming"
        }
    }

    func start() {
        refreshPermissions()
        registerShortcutHandlerIfNeeded()
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
    }

    func stop() {
        currentResponseTask?.cancel()
        overlayWindowManager.hideOverlay()
        responseOverlayManager.hideOverlay()
        dismissPromptComposer()
    }

    func refreshPermissions() {
        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()
    }

    func requestPromptEditorFocus() {
        promptEditorFocusToken += 1
    }

    func openPromptComposer() {
        composerValidationMessage = nil
        interfaceState = .composing
        promptComposerPanelManager.show(on: NSScreen.screenContainingPoint(NSEvent.mouseLocation))
    }

    func dismissPromptComposer() {
        promptComposerPanelManager.hide()

        if currentResponseTask == nil {
            interfaceState = .idle
        }
    }

    func sendCurrentPromptDraft() {
        let trimmedPromptDraft = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPromptDraft.isEmpty else {
            composerValidationMessage = "Write a prompt before sending."
            return
        }

        guard settingsStore.isConfigurationComplete else {
            composerValidationMessage = "Fill in Endpoint, API Key, and Model in the menu bar panel first."
            return
        }

        guard hasScreenRecordingPermission else {
            _ = WindowPositionManager.requestScreenRecordingPermission()
            refreshPermissions()
            composerValidationMessage = "Grant Screen Recording, then try again. macOS may require reopening Clicky."
            return
        }

        composerValidationMessage = nil
        promptDraft = ""
        dismissPromptComposer()
        sendPromptWithScreenshot(prompt: trimmedPromptDraft)
    }

    private func registerShortcutHandlerIfNeeded() {
        guard !registeredShortcutHandler else { return }
        registeredShortcutHandler = true

        KeyboardShortcuts.onKeyUp(for: .openPromptComposer) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleGlobalShortcutTriggered()
            }
        }
    }

    private func handleGlobalShortcutTriggered() {
        if promptComposerPanelManager.isVisible {
            requestPromptEditorFocus()
            return
        }

        openPromptComposer()
    }

    private func sendPromptWithScreenshot(prompt: String) {
        currentResponseTask?.cancel()
        clearDetectedElementLocation()
        responseOverlayManager.hideOverlay()

        lastPromptSubmitted = prompt
        let requestMouseLocation = NSEvent.mouseLocation
        let requestIdentifier = UUID()
        activeRequestIdentifier = requestIdentifier

        currentResponseTask = Task { @MainActor in
            interfaceState = .processing
            defer {
                if activeRequestIdentifier == requestIdentifier {
                    interfaceState = .idle
                    currentResponseTask = nil
                    activeRequestIdentifier = nil
                }
            }

            guard let endpointURL = settingsStore.resolvedEndpointURL() else {
                composerValidationMessage = "The configured endpoint is invalid."
                return
            }

            let claudeAPI = ClaudeAPI(
                endpointURL: endpointURL,
                apiKey: settingsStore.trimmedAPIKey,
                modelID: settingsStore.trimmedModelID
            )

            do {
                let screenCapture = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
                guard !Task.isCancelled else { return }

                responseOverlayManager.beginStreaming(on: screenCapture.screen, referencePoint: requestMouseLocation)
                displayedResponseText = ""

                let labeledImage = (
                    data: screenCapture.imageData,
                    label: "\(screenCapture.label) (image dimensions: \(screenCapture.screenshotWidthInPixels)x\(screenCapture.screenshotHeightInPixels) pixels)"
                )

                let fullResponseText = try await claudeAPI.analyzeImageStreaming(
                    images: [labeledImage],
                    systemPrompt: Self.textResponseSystemPrompt,
                    conversationHistory: conversationHistory,
                    userPrompt: prompt,
                    onTextChunk: { [weak self] accumulatedText in
                        guard let self else { return }
                        if self.interfaceState == .processing {
                            self.interfaceState = .streaming
                        }
                        let displayText = Self.textForDisplayDuringStreaming(accumulatedText)
                        self.displayedResponseText = displayText
                        self.responseOverlayManager.updateStreamingText(displayText)
                    }
                )

                guard !Task.isCancelled else { return }

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let finalDisplayText = parseResult.displayText.isEmpty ? "(No response text returned.)" : parseResult.displayText
                displayedResponseText = finalDisplayText
                responseOverlayManager.finishStreaming(finalText: finalDisplayText)

                conversationHistory.append((userPrompt: prompt, assistantResponse: finalDisplayText))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                if let pointCoordinate = parseResult.coordinate {
                    let mappedLocation = mapPointCoordinate(pointCoordinate, from: screenCapture)
                    detectedElementScreenLocation = mappedLocation
                    detectedElementDisplayFrame = screenCapture.displayFrame
                    detectedElementBubbleText = parseResult.elementLabel ?? "right here"
                    responseOverlayManager.updateAnchorIfNeeded(for: mappedLocation)
                }
            } catch is CancellationError {
                if activeRequestIdentifier == requestIdentifier {
                    responseOverlayManager.hideOverlay()
                }
            } catch {
                let errorMessage = "Clicky couldn't get a response.\n\n\(error.localizedDescription)"
                displayedResponseText = errorMessage
                if activeRequestIdentifier == requestIdentifier,
                   let targetScreen = NSScreen.screenContainingPoint(requestMouseLocation) {
                    responseOverlayManager.presentError(errorMessage, on: targetScreen, referencePoint: requestMouseLocation)
                }
            }

        }
    }

    private func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    private func mapPointCoordinate(
        _ pointCoordinate: CGPoint,
        from screenCapture: CompanionScreenCapture
    ) -> CGPoint {
        let screenshotWidth = CGFloat(screenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(screenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(screenCapture.displayHeightInPoints)

        let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
        let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY

        return CGPoint(
            x: displayLocalX + screenCapture.displayFrame.origin.x,
            y: appKitY + screenCapture.displayFrame.origin.y
        )
    }

    private static let textResponseSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's mac. the user asked a question while looking at their screen. write for on-screen reading, not for speech.

    rules:
    - default to short, dense paragraphs.
    - plain text only. no markdown tables.
    - if the screenshot is relevant, reference what you can actually see.
    - if the question is conceptual and the screenshot is irrelevant, answer directly.
    - be concrete when explaining code, command output, or UI.
    - if you receive a screenshot label with image dimensions, use that coordinate space for pointing.

    element pointing:
    - if pointing would help, append a single terminal tag in this exact format: [POINT:x,y:label]
    - if no pointing is useful, append [POINT:none]
    - coordinates use the screenshot image space where origin is top-left
    - keep the label short, 1 to 3 words
    - the point tag must be the final thing in the response
    """

    struct PointingParseResult {
        let displayText: String
        let coordinate: CGPoint?
        let elementLabel: String?
    }

    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?)\]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let tagRange = Range(match.range, in: responseText) else {
            return PointingParseResult(
                displayText: responseText.trimmingCharacters(in: .whitespacesAndNewlines),
                coordinate: nil,
                elementLabel: nil
            )
        }

        let displayText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(displayText: displayText, coordinate: nil, elementLabel: nil)
        }

        let labelRange = Range(match.range(at: 3), in: responseText)
        let elementLabel = labelRange.map { String(responseText[$0]).trimmingCharacters(in: .whitespaces) }
        return PointingParseResult(
            displayText: displayText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel
        )
    }

    static func textForDisplayDuringStreaming(_ responseText: String) -> String {
        guard let pointTagStart = responseText.range(of: "[POINT:") else {
            return responseText
        }

        return String(responseText[..<pointTagStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
