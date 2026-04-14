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

struct ConversationHistoryPreviewTurn: Identifiable {
    let turnID: UUID
    let turnNumber: Int
    let userPreviewText: String
    let assistantPreviewText: String

    var id: UUID { turnID }
}

struct AIRequestConfiguration: Equatable {
    let provider: AIProvider
    let endpointURL: URL
    let apiKey: String
    let modelID: String
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
    @Published private(set) var activeSessionArchive: ClickySessionArchive?
    @Published private(set) var selectedConversationTurnID: UUID?
    @Published private(set) var needsSessionRestoreDecision = false
    @Published var settingsPanelFeedbackMessage: String?
    @Published var settingsPanelFeedbackIsError = false

    let settingsStore: ClickySettingsStore
    let overlayWindowManager: OverlayWindowManager
    let responseOverlayManager: CompanionResponseOverlayManager

    private lazy var promptComposerPanelManager = PromptComposerPanelManager(companionManager: self)

    private let sessionArchiveStore: SessionArchiveStore
    private var recoverableSessionArchive: ClickySessionArchive?
    private var currentResponseTask: Task<Void, Never>?
    private var activeRequestIdentifier: UUID?
    private var registeredShortcutHandler = false
    private var cancellables = Set<AnyCancellable>()

    convenience init() {
        self.init(
            settingsStore: ClickySettingsStore(),
            sessionArchiveStore: SessionArchiveStore(),
            overlayWindowManager: OverlayWindowManager(),
            responseOverlayManager: CompanionResponseOverlayManager()
        )
    }

    convenience init(
        settingsStore: ClickySettingsStore,
        sessionArchiveStore: SessionArchiveStore
    ) {
        self.init(
            settingsStore: settingsStore,
            sessionArchiveStore: sessionArchiveStore,
            overlayWindowManager: OverlayWindowManager(),
            responseOverlayManager: CompanionResponseOverlayManager()
        )
    }

    init(
        settingsStore: ClickySettingsStore,
        sessionArchiveStore: SessionArchiveStore,
        overlayWindowManager: OverlayWindowManager,
        responseOverlayManager: CompanionResponseOverlayManager
    ) {
        self.settingsStore = settingsStore
        self.sessionArchiveStore = sessionArchiveStore
        self.overlayWindowManager = overlayWindowManager
        self.responseOverlayManager = responseOverlayManager

        observeSettingsStore()
    }

    var canSendPromptDraft: Bool {
        !promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var completedConversationTurns: [ClickyConversationTurnRecord] {
        activeSessionArchive?.completedConversationTurns ?? []
    }

    var conversationTurnsIncludedInAIContext: [ClickyConversationTurnRecord] {
        Array(completedConversationTurns.suffix(settingsStore.conversationContextTurnLimit))
    }

    var recentConversationHistoryPreviewTurns: [ConversationHistoryPreviewTurn] {
        let allCompletedConversationTurns = completedConversationTurns
        let contextTurnsIncludedInAIContext = conversationTurnsIncludedInAIContext
        let previewTurnNumberOffset = allCompletedConversationTurns.count - contextTurnsIncludedInAIContext.count

        return contextTurnsIncludedInAIContext.enumerated().map { previewTurnIndex, turnRecord in
            ConversationHistoryPreviewTurn(
                turnID: turnRecord.turnID,
                turnNumber: previewTurnNumberOffset + previewTurnIndex + 1,
                userPreviewText: Self.previewText(for: turnRecord.userPromptText),
                assistantPreviewText: Self.previewText(for: turnRecord.assistantResponseText)
            )
        }
    }

    var selectedConversationTurnDetail: ClickyConversationTurnRecord? {
        guard let selectedConversationTurnID else {
            return nil
        }

        return conversationTurnsIncludedInAIContext.first { conversationTurn in
            conversationTurn.turnID == selectedConversationTurnID
        }
    }

    var selectedConversationTurnNumber: Int? {
        guard let selectedConversationTurnID else {
            return nil
        }

        return completedConversationTurns.firstIndex { conversationTurn in
            conversationTurn.turnID == selectedConversationTurnID
        }.map { $0 + 1 }
    }

    var recoverableSessionTurnCount: Int {
        recoverableSessionArchive?.completedConversationTurns.count ?? 0
    }

    var canStartNewSession: Bool {
        !completedConversationTurns.isEmpty
            || !displayedResponseText.isEmpty
            || lastPromptSubmitted != nil
            || currentResponseTask != nil
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

        if needsSessionRestoreDecision {
            return "Session waiting"
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
        prepareSessionStateForCurrentLaunch()
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

    func prepareSessionStateForCurrentLaunch() {
        sessionArchiveStore.prepareSessionRestoreDecisionForCurrentLaunch()

        do {
            recoverableSessionArchive = try sessionArchiveStore.loadRecoverableActiveSessionArchive()
            needsSessionRestoreDecision = recoverableSessionArchive != nil

            if needsSessionRestoreDecision {
                activeSessionArchive = nil
                selectedConversationTurnID = nil
                return
            }

            activeSessionArchive = try sessionArchiveStore.loadActiveSessionArchiveIfAvailable()
            ensureSelectedConversationTurnStillVisible()
        } catch {
            recoverableSessionArchive = nil
            activeSessionArchive = nil
            selectedConversationTurnID = nil
            needsSessionRestoreDecision = false
            sessionArchiveStore.hasPendingSessionRestoreDecision = false
            composerValidationMessage = "Clicky couldn't read the previous session archive."
        }
    }

    func refreshPermissions() {
        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()
    }

    func requestPromptEditorFocus() {
        promptEditorFocusToken += 1
    }

    func openPromptComposer() {
        composerValidationMessage = nil

        if !needsSessionRestoreDecision {
            do {
                try ensureActiveConversationSessionExists()
            } catch {
                composerValidationMessage = "Clicky couldn't prepare a local session archive."
            }
        }

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
        guard !needsSessionRestoreDecision else {
            composerValidationMessage = "Choose whether to resume the previous session before sending."
            return
        }

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

        do {
            try ensureActiveConversationSessionExists()
        } catch {
            composerValidationMessage = "Clicky couldn't prepare a local session archive."
            return
        }

        composerValidationMessage = nil
        promptDraft = ""
        dismissPromptComposer()
        sendPromptWithScreenshot(prompt: trimmedPromptDraft)
    }

    func startNewSession() {
        cancelActiveRequestAndResetTransientUI()

        do {
            activeSessionArchive = try sessionArchiveStore.createNewConversationSession()
            recoverableSessionArchive = nil
            needsSessionRestoreDecision = false
            selectedConversationTurnID = nil
            composerValidationMessage = nil
        } catch {
            activeSessionArchive = nil
            composerValidationMessage = "Clicky couldn't create a new session archive."
        }

        interfaceState = promptComposerPanelManager.isVisible ? .composing : .idle
        if promptComposerPanelManager.isVisible, !needsSessionRestoreDecision {
            requestPromptEditorFocus()
        }
    }

    func openSessionArchivesFolder() {
        do {
            let sessionsDirectoryURL = try sessionArchiveStore.sessionsDirectoryURLForOpening()
            let didOpenDirectory = NSWorkspace.shared.open(sessionsDirectoryURL)

            if didOpenDirectory {
                settingsPanelFeedbackMessage = "Opened Session Archives in Finder."
                settingsPanelFeedbackIsError = false
            } else {
                settingsPanelFeedbackMessage = "Clicky couldn't open the Session Archives folder."
                settingsPanelFeedbackIsError = true
            }
        } catch {
            settingsPanelFeedbackMessage = "Clicky couldn't prepare the Session Archives folder."
            settingsPanelFeedbackIsError = true
        }
    }

    func clearAllSessionArchives() {
        cancelActiveRequestAndResetTransientUI()

        do {
            try sessionArchiveStore.clearAllSessionArchives()
            activeSessionArchive = nil
            recoverableSessionArchive = nil
            needsSessionRestoreDecision = false
            composerValidationMessage = nil
            settingsPanelFeedbackMessage = "Cleared all archived session JSON files."
            settingsPanelFeedbackIsError = false
        } catch {
            settingsPanelFeedbackMessage = "Clicky couldn't clear the archived session files."
            settingsPanelFeedbackIsError = true
        }

        interfaceState = promptComposerPanelManager.isVisible ? .composing : .idle
    }

    func resumePendingSession() {
        do {
            let recoverableSessionArchive = try recoverableSessionArchive
                ?? sessionArchiveStore.loadRecoverableActiveSessionArchive()

            guard let recoverableSessionArchive else {
                composerValidationMessage = "The previous session is no longer available."
                return
            }

            self.recoverableSessionArchive = nil
            self.activeSessionArchive = recoverableSessionArchive
            self.needsSessionRestoreDecision = false
            self.selectedConversationTurnID = nil
            sessionArchiveStore.activeSessionID = recoverableSessionArchive.sessionID
            sessionArchiveStore.hasPendingSessionRestoreDecision = false
            composerValidationMessage = nil
            ensureSelectedConversationTurnStillVisible()
            requestPromptEditorFocus()
        } catch {
            composerValidationMessage = "Clicky couldn't restore the previous session archive."
        }
    }

    func selectConversationTurn(turnID: UUID) {
        selectedConversationTurnID = turnID
    }

    func clearSelectedConversationTurn() {
        selectedConversationTurnID = nil
    }

    private func observeSettingsStore() {
        settingsStore.$conversationContextTurnLimit
            .dropFirst()
            .sink { [weak self] _ in
                self?.ensureSelectedConversationTurnStillVisible()
            }
            .store(in: &cancellables)
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
            if !needsSessionRestoreDecision {
                requestPromptEditorFocus()
            }
            return
        }

        openPromptComposer()
    }

    private func ensureActiveConversationSessionExists() throws {
        guard !needsSessionRestoreDecision else {
            return
        }

        guard activeSessionArchive == nil else {
            return
        }

        activeSessionArchive = try sessionArchiveStore.createNewConversationSession()
    }

    private func cancelActiveRequestAndResetTransientUI() {
        currentResponseTask?.cancel()
        currentResponseTask = nil
        activeRequestIdentifier = nil

        promptDraft = ""
        lastPromptSubmitted = nil
        displayedResponseText = ""
        selectedConversationTurnID = nil

        clearDetectedElementLocation()
        responseOverlayManager.hideOverlay()
    }

    private func ensureSelectedConversationTurnStillVisible() {
        guard let selectedConversationTurnID else {
            return
        }

        guard conversationTurnsIncludedInAIContext.contains(where: { conversationTurn in
            conversationTurn.turnID == selectedConversationTurnID
        }) else {
            self.selectedConversationTurnID = nil
            return
        }
    }

    private func appendCompletedConversationTurnToArchive(
        userPromptText: String,
        assistantResponseText: String
    ) throws {
        try ensureActiveConversationSessionExists()

        guard let activeSessionArchive else {
            throw NSError(
                domain: "CompanionManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Missing active session archive."]
            )
        }

        let updatedSessionArchive = activeSessionArchive.appendingConversationTurn(
            userPromptText: userPromptText,
            assistantResponseText: assistantResponseText
        )

        try sessionArchiveStore.saveArchive(updatedSessionArchive)
        self.activeSessionArchive = updatedSessionArchive
        ensureSelectedConversationTurnStillVisible()
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

            guard let requestConfiguration = currentAIRequestConfiguration() else {
                composerValidationMessage = "The configured endpoint is invalid."
                return
            }

            do {
                let screenCapture = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
                guard !Task.isCancelled else { return }

                responseOverlayManager.beginStreaming(on: screenCapture.screen)
                displayedResponseText = ""

                let labeledImage = (
                    data: screenCapture.imageData,
                    label: "\(screenCapture.label) (image dimensions: \(screenCapture.screenshotWidthInPixels)x\(screenCapture.screenshotHeightInPixels) pixels)"
                )

                let conversationHistoryForRequest = conversationTurnsIncludedInAIContext.map { conversationTurn in
                    (
                        userPrompt: conversationTurn.userPromptText,
                        assistantResponse: conversationTurn.assistantResponseText
                    )
                }

                let fullResponseText = try await analyzeImageStreaming(
                    requestConfiguration: requestConfiguration,
                    images: [labeledImage],
                    conversationHistoryForRequest: conversationHistoryForRequest,
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

                do {
                    try appendCompletedConversationTurnToArchive(
                        userPromptText: prompt,
                        assistantResponseText: finalDisplayText
                    )
                } catch {
                    composerValidationMessage = "Clicky replied, but couldn't save this turn to the session archive."
                }

                if let pointCoordinate = parseResult.coordinate {
                    let mappedLocation = mapPointCoordinate(pointCoordinate, from: screenCapture)
                    detectedElementScreenLocation = mappedLocation
                    detectedElementDisplayFrame = screenCapture.displayFrame
                    detectedElementBubbleText = parseResult.elementLabel ?? "right here"
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
                    responseOverlayManager.presentError(errorMessage, on: targetScreen)
                }
            }
        }
    }

    func currentAIRequestConfiguration() -> AIRequestConfiguration? {
        guard let endpointURL = settingsStore.resolvedEndpointURL() else {
            return nil
        }

        return AIRequestConfiguration(
            provider: settingsStore.selectedProvider,
            endpointURL: endpointURL,
            apiKey: settingsStore.trimmedAPIKey,
            modelID: settingsStore.trimmedModelID
        )
    }

    private func analyzeImageStreaming(
        requestConfiguration: AIRequestConfiguration,
        images: [(data: Data, label: String)],
        conversationHistoryForRequest: [(userPrompt: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        switch requestConfiguration.provider {
        case .anthropic:
            let claudeAPI = ClaudeAPI(
                endpointURL: requestConfiguration.endpointURL,
                apiKey: requestConfiguration.apiKey,
                modelID: requestConfiguration.modelID
            )

            return try await claudeAPI.analyzeImageStreaming(
                images: images,
                systemPrompt: Self.textResponseSystemPrompt,
                conversationHistory: conversationHistoryForRequest,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        case .openAI:
            let openAIAPI = OpenAIAPI(
                endpointURL: requestConfiguration.endpointURL,
                apiKey: requestConfiguration.apiKey,
                modelID: requestConfiguration.modelID
            )

            return try await openAIAPI.analyzeImageStreaming(
                images: images,
                systemPrompt: Self.textResponseSystemPrompt,
                conversationHistory: conversationHistoryForRequest,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
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

    private static func previewText(for text: String) -> String {
        let collapsedWhitespaceText = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsedWhitespaceText.isEmpty else {
            return "(Empty response)"
        }

        let maximumPreviewLength = 88
        guard collapsedWhitespaceText.count > maximumPreviewLength else {
            return collapsedWhitespaceText
        }

        let previewEndIndex = collapsedWhitespaceText.index(
            collapsedWhitespaceText.startIndex,
            offsetBy: maximumPreviewLength
        )

        let truncatedPreviewText = collapsedWhitespaceText[..<previewEndIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return "\(truncatedPreviewText)…"
    }
}
