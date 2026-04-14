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

enum CurrentConversationTurnPhase: Equatable {
    case processing
    case streaming
    case completed
    case failed
}

struct CurrentConversationTurn: Equatable {
    let promptText: String
    let responseText: String
    let phase: CurrentConversationTurnPhase
}

enum ConversationHistorySelection: Equatable {
    case currentTurn
    case archivedTurn(UUID)
}

struct ConversationHistoryPreviewTurn: Identifiable, Equatable {
    let turnID: UUID
    let turnNumber: Int
    let userPreviewText: String
    let assistantPreviewText: String

    var id: UUID { turnID }
}

struct CurrentConversationPreviewTurn: Identifiable, Equatable {
    let promptPreviewText: String
    let responsePreviewText: String
    let phase: CurrentConversationTurnPhase

    var id: String { "current-turn" }
}

enum ConversationHistorySidebarItem: Identifiable, Equatable {
    case currentTurn(CurrentConversationPreviewTurn)
    case archivedTurn(ConversationHistoryPreviewTurn)

    var id: String {
        switch self {
        case .currentTurn:
            return "current-turn"
        case .archivedTurn(let previewTurn):
            return previewTurn.turnID.uuidString
        }
    }
}

struct AIRequestConfiguration: Equatable {
    let provider: AIProvider
    let endpointURL: URL
    let apiKey: String
    let modelID: String
}

typealias ScreenCaptureProvider = @MainActor @Sendable () async throws -> CompanionScreenCapture
typealias StreamingResponseAnalyzer = @MainActor @Sendable (
    AIRequestConfiguration,
    String,
    [(data: Data, label: String)],
    [(userPrompt: String, assistantResponse: String)],
    String,
    @escaping @MainActor @Sendable (String) -> Void
) async throws -> String

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var interfaceState: CompanionInterfaceState = .idle
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var isPromptComposerPresented = false
    @Published var promptDraft: String = ""
    @Published var composerValidationMessage: String?
    @Published private(set) var currentConversationTurn: CurrentConversationTurn?
    @Published var detectedElementScreenLocation: CGPoint?
    @Published var detectedElementDisplayFrame: CGRect?
    @Published var detectedElementBubbleText: String?
    @Published private(set) var promptEditorFocusToken: Int = 0
    @Published private(set) var activeSessionArchive: ClickySessionArchive?
    @Published private(set) var selectedConversationHistorySelection: ConversationHistorySelection?
    @Published private(set) var needsSessionRestoreDecision = false
    @Published var settingsPanelFeedbackMessage: String?
    @Published var settingsPanelFeedbackIsError = false

    let settingsStore: ClickySettingsStore
    let overlayWindowManager: OverlayWindowManager

    private lazy var promptComposerPanelManager = PromptComposerPanelManager(companionManager: self)

    private let sessionArchiveStore: SessionArchiveStore
    private let promptStore: ClickyPromptStore
    private let screenCaptureProvider: ScreenCaptureProvider
    private let streamingResponseAnalyzer: StreamingResponseAnalyzer
    private var recoverableSessionArchive: ClickySessionArchive?
    private var currentResponseTask: Task<Void, Never>?
    private var activeRequestIdentifier: UUID?
    private var registeredShortcutHandler = false
    private var cancellables = Set<AnyCancellable>()

    convenience init() {
        self.init(
            settingsStore: ClickySettingsStore(),
            sessionArchiveStore: SessionArchiveStore(),
            promptStore: ClickyPromptStore(),
            overlayWindowManager: OverlayWindowManager(),
            hasScreenRecordingPermission: false,
            screenCaptureProvider: CompanionScreenCaptureUtility.captureCursorScreenAsJPEG,
            streamingResponseAnalyzer: CompanionManager.defaultStreamingResponseAnalyzer
        )
    }

    convenience init(
        settingsStore: ClickySettingsStore,
        sessionArchiveStore: SessionArchiveStore
    ) {
        self.init(
            settingsStore: settingsStore,
            sessionArchiveStore: sessionArchiveStore,
            promptStore: ClickyPromptStore(),
            overlayWindowManager: OverlayWindowManager(),
            hasScreenRecordingPermission: false,
            screenCaptureProvider: CompanionScreenCaptureUtility.captureCursorScreenAsJPEG,
            streamingResponseAnalyzer: CompanionManager.defaultStreamingResponseAnalyzer
        )
    }

    init(
        settingsStore: ClickySettingsStore,
        sessionArchiveStore: SessionArchiveStore,
        promptStore: ClickyPromptStore = ClickyPromptStore(),
        overlayWindowManager: OverlayWindowManager,
        hasScreenRecordingPermission: Bool = false,
        screenCaptureProvider: @escaping ScreenCaptureProvider = CompanionScreenCaptureUtility.captureCursorScreenAsJPEG,
        streamingResponseAnalyzer: @escaping StreamingResponseAnalyzer = CompanionManager.defaultStreamingResponseAnalyzer
    ) {
        self.settingsStore = settingsStore
        self.sessionArchiveStore = sessionArchiveStore
        self.promptStore = promptStore
        self.overlayWindowManager = overlayWindowManager
        self.hasScreenRecordingPermission = hasScreenRecordingPermission
        self.screenCaptureProvider = screenCaptureProvider
        self.streamingResponseAnalyzer = streamingResponseAnalyzer

        observeSettingsStore()
    }

    var canSendPromptDraft: Bool {
        !promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSubmitCurrentPromptDraft: Bool {
        canSendPromptDraft && currentResponseTask == nil
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

    var currentConversationPreviewTurn: CurrentConversationPreviewTurn? {
        guard let currentConversationTurn else {
            return nil
        }

        return CurrentConversationPreviewTurn(
            promptPreviewText: Self.previewText(for: currentConversationTurn.promptText),
            responsePreviewText: Self.previewText(for: currentConversationTurn.responseText),
            phase: currentConversationTurn.phase
        )
    }

    var conversationHistorySidebarItems: [ConversationHistorySidebarItem] {
        var sidebarItems: [ConversationHistorySidebarItem] = []

        if let currentConversationPreviewTurn {
            sidebarItems.append(.currentTurn(currentConversationPreviewTurn))
        }

        sidebarItems.append(
            contentsOf: recentConversationHistoryPreviewTurns
                .reversed()
                .map(ConversationHistorySidebarItem.archivedTurn)
        )

        return sidebarItems
    }

    var selectedArchivedConversationTurnDetail: ClickyConversationTurnRecord? {
        guard case .archivedTurn(let selectedConversationTurnID) = selectedConversationHistorySelection else {
            return nil
        }

        return conversationTurnsIncludedInAIContext.first { conversationTurn in
            conversationTurn.turnID == selectedConversationTurnID
        }
    }

    var selectedArchivedConversationTurnNumber: Int? {
        guard case .archivedTurn(let selectedConversationTurnID) = selectedConversationHistorySelection else {
            return nil
        }

        return completedConversationTurns.firstIndex { conversationTurn in
            conversationTurn.turnID == selectedConversationTurnID
        }.map { $0 + 1 }
    }

    var isCurrentConversationTurnSelected: Bool {
        selectedConversationHistorySelection == .currentTurn && currentConversationTurn != nil
    }

    var recoverableSessionTurnCount: Int {
        recoverableSessionArchive?.completedConversationTurns.count ?? 0
    }

    var canStartNewSession: Bool {
        !completedConversationTurns.isEmpty
            || currentConversationTurn != nil
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
        dismissPromptComposer()
    }

    func prepareSessionStateForCurrentLaunch() {
        sessionArchiveStore.prepareSessionRestoreDecisionForCurrentLaunch()

        do {
            recoverableSessionArchive = try sessionArchiveStore.loadRecoverableActiveSessionArchive()
            needsSessionRestoreDecision = recoverableSessionArchive != nil

            if needsSessionRestoreDecision {
                activeSessionArchive = nil
                selectedConversationHistorySelection = nil
                return
            }

            activeSessionArchive = try sessionArchiveStore.loadActiveSessionArchiveIfAvailable()
            ensureSelectedConversationSelectionStillVisible()
        } catch {
            recoverableSessionArchive = nil
            activeSessionArchive = nil
            selectedConversationHistorySelection = nil
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
        isPromptComposerPresented = true
        promptComposerPanelManager.show(on: NSScreen.screenContainingPoint(NSEvent.mouseLocation))
    }

    func dismissPromptComposer() {
        promptComposerPanelManager.hide()
        isPromptComposerPresented = false

        if currentResponseTask == nil {
            interfaceState = .idle
        }
    }

    func sendCurrentPromptDraft() {
        guard !needsSessionRestoreDecision else {
            composerValidationMessage = "Choose whether to resume the previous session before sending."
            return
        }

        guard currentResponseTask == nil else {
            composerValidationMessage = "Wait for the current reply to finish before sending again."
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
        selectedConversationHistorySelection = .currentTurn
        sendPromptWithScreenshot(prompt: trimmedPromptDraft)
    }

    func startNewSession() {
        cancelActiveRequestAndResetTransientUI()

        do {
            activeSessionArchive = try sessionArchiveStore.createNewConversationSession()
            recoverableSessionArchive = nil
            needsSessionRestoreDecision = false
            selectedConversationHistorySelection = nil
            composerValidationMessage = nil
        } catch {
            activeSessionArchive = nil
            composerValidationMessage = "Clicky couldn't create a new session archive."
        }

        interfaceState = isPromptComposerPresented ? .composing : .idle
        if isPromptComposerPresented, !needsSessionRestoreDecision {
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

    func openPromptOverridesFolder() {
        do {
            let promptsDirectoryURL = try promptStore.promptsDirectoryURLForOpening()
            let didOpenDirectory = NSWorkspace.shared.open(promptsDirectoryURL)

            if didOpenDirectory {
                settingsPanelFeedbackMessage = "Opened Prompt Overrides in Finder."
                settingsPanelFeedbackIsError = false
            } else {
                settingsPanelFeedbackMessage = "Clicky couldn't open the Prompt Overrides folder."
                settingsPanelFeedbackIsError = true
            }
        } catch {
            settingsPanelFeedbackMessage = "Clicky couldn't prepare the Prompt Overrides folder."
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
            self.selectedConversationHistorySelection = nil
            sessionArchiveStore.activeSessionID = recoverableSessionArchive.sessionID
            sessionArchiveStore.hasPendingSessionRestoreDecision = false
            composerValidationMessage = nil
            ensureSelectedConversationSelectionStillVisible()
            requestPromptEditorFocus()
        } catch {
            composerValidationMessage = "Clicky couldn't restore the previous session archive."
        }
    }

    func selectCurrentConversationTurn() {
        guard currentConversationTurn != nil else {
            return
        }

        selectedConversationHistorySelection = .currentTurn
    }

    func selectArchivedConversationTurn(turnID: UUID) {
        selectedConversationHistorySelection = .archivedTurn(turnID)
    }

    func clearSelectedConversationHistorySelection() {
        selectedConversationHistorySelection = nil
    }

    private func observeSettingsStore() {
        settingsStore.$conversationContextTurnLimit
            .dropFirst()
            .sink { [weak self] _ in
                self?.ensureSelectedConversationSelectionStillVisible()
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
        currentConversationTurn = nil
        selectedConversationHistorySelection = nil

        clearDetectedElementLocation()
    }

    private func ensureSelectedConversationSelectionStillVisible() {
        guard let selectedConversationHistorySelection else {
            return
        }

        switch selectedConversationHistorySelection {
        case .currentTurn:
            guard currentConversationTurn != nil else {
                self.selectedConversationHistorySelection = nil
                return
            }
        case .archivedTurn(let selectedConversationTurnID):
            guard conversationTurnsIncludedInAIContext.contains(where: { conversationTurn in
                conversationTurn.turnID == selectedConversationTurnID
            }) else {
                self.selectedConversationHistorySelection = nil
                return
            }
        }
    }

    private func setCurrentConversationTurn(
        promptText: String,
        responseText: String,
        phase: CurrentConversationTurnPhase
    ) {
        currentConversationTurn = CurrentConversationTurn(
            promptText: promptText,
            responseText: responseText,
            phase: phase
        )
        selectedConversationHistorySelection = .currentTurn
    }

    private func clearCurrentConversationTurn() {
        currentConversationTurn = nil

        if selectedConversationHistorySelection == .currentTurn {
            selectedConversationHistorySelection = nil
        }
    }

    private func appendCompletedConversationTurnToArchive(
        userPromptText: String,
        assistantResponseText: String
    ) throws -> ClickyConversationTurnRecord {
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
        ensureSelectedConversationSelectionStillVisible()
        guard let appendedConversationTurn = updatedSessionArchive.completedConversationTurns.last else {
            throw NSError(
                domain: "CompanionManager",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Saved archive missing appended conversation turn."]
            )
        }

        return appendedConversationTurn
    }

    private func currentTurnResponseText(for phase: CurrentConversationTurnPhase, existingResponseText: String) -> String {
        if !existingResponseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existingResponseText
        }

        switch phase {
        case .processing:
            return "Capturing your current screen and preparing the request..."
        case .streaming:
            return "Waiting for the first response chunk..."
        case .completed:
            return "(No response text returned.)"
        case .failed:
            return "Clicky couldn't get a response."
        }
    }

    private func updateCurrentConversationTurnResponse(
        promptText: String,
        responseText: String,
        phase: CurrentConversationTurnPhase
    ) {
        let visibleResponseText = currentTurnResponseText(for: phase, existingResponseText: responseText)
        setCurrentConversationTurn(
            promptText: promptText,
            responseText: visibleResponseText,
            phase: phase
        )
    }

    private func updateInterfaceStateAfterRequestCompletion() {
        interfaceState = isPromptComposerPresented ? .composing : .idle
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

    private func sendPromptWithScreenshot(prompt: String) {
        currentResponseTask?.cancel()
        clearDetectedElementLocation()
        updateCurrentConversationTurnResponse(
            promptText: prompt,
            responseText: "",
            phase: .processing
        )

        let requestMouseLocation = NSEvent.mouseLocation
        let requestIdentifier = UUID()
        activeRequestIdentifier = requestIdentifier

        currentResponseTask = Task { @MainActor in
            interfaceState = .processing
            defer {
                if activeRequestIdentifier == requestIdentifier {
                    updateInterfaceStateAfterRequestCompletion()
                    currentResponseTask = nil
                    activeRequestIdentifier = nil
                }
            }

            guard let requestConfiguration = currentAIRequestConfiguration() else {
                composerValidationMessage = "The configured endpoint is invalid."
                updateCurrentConversationTurnResponse(
                    promptText: prompt,
                    responseText: "The configured endpoint is invalid.",
                    phase: .failed
                )
                return
            }

            do {
                let resolvedSystemPrompt = try promptStore.resolvedPrompt(for: .textResponseSystem)
                let screenCapture = try await screenCaptureProvider()
                guard !Task.isCancelled else { return }

                updateCurrentConversationTurnResponse(
                    promptText: prompt,
                    responseText: "",
                    phase: .processing
                )

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

                let fullResponseText = try await streamingResponseAnalyzer(
                    requestConfiguration,
                    resolvedSystemPrompt.text,
                    [labeledImage],
                    conversationHistoryForRequest,
                    prompt,
                    { [weak self] accumulatedText in
                        guard let self else { return }
                        if self.interfaceState == .processing {
                            self.interfaceState = .streaming
                        }
                        let displayText = Self.textForDisplayDuringStreaming(accumulatedText)
                        self.updateCurrentConversationTurnResponse(
                            promptText: prompt,
                            responseText: displayText,
                            phase: .streaming
                        )
                    }
                )

                guard !Task.isCancelled else { return }

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let finalDisplayText = parseResult.displayText.isEmpty ? "(No response text returned.)" : parseResult.displayText
                updateCurrentConversationTurnResponse(
                    promptText: prompt,
                    responseText: finalDisplayText,
                    phase: .completed
                )

                do {
                    let appendedConversationTurn = try appendCompletedConversationTurnToArchive(
                        userPromptText: prompt,
                        assistantResponseText: finalDisplayText
                    )
                    clearCurrentConversationTurn()
                    selectedConversationHistorySelection = .archivedTurn(appendedConversationTurn.turnID)
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
                    clearCurrentConversationTurn()
                }
            } catch {
                let errorMessage = "Clicky couldn't get a response.\n\n\(error.localizedDescription)"
                composerValidationMessage = errorMessage
                updateCurrentConversationTurnResponse(
                    promptText: prompt,
                    responseText: errorMessage,
                    phase: .failed
                )

                if activeRequestIdentifier == requestIdentifier,
                   let targetScreen = NSScreen.screenContainingPoint(requestMouseLocation) {
                    detectedElementDisplayFrame = targetScreen.frame
                }
            }
        }
    }

    static func defaultStreamingResponseAnalyzer(
        requestConfiguration: AIRequestConfiguration,
        systemPrompt: String,
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
                systemPrompt: systemPrompt,
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
                systemPrompt: systemPrompt,
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
