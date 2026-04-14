//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import AppKit
import Foundation
import Testing
@testable import Clicky

@MainActor
struct leanring_buddyTests {

    actor StreamGate {
        private var didStart = false
        private var startedContinuations: [CheckedContinuation<Void, Never>] = []
        private var didFinish = false
        private var finishContinuations: [CheckedContinuation<Void, Never>] = []

        func markStarted() {
            didStart = true
            let continuations = startedContinuations
            startedContinuations.removeAll()
            continuations.forEach { $0.resume() }
        }

        func waitUntilStarted() async {
            if didStart {
                return
            }

            await withCheckedContinuation { continuation in
                startedContinuations.append(continuation)
            }
        }

        func allowFinish() {
            didFinish = true
            let continuations = finishContinuations
            finishContinuations.removeAll()
            continuations.forEach { $0.resume() }
        }

        func waitUntilAllowedToFinish() async {
            if didFinish {
                return
            }

            await withCheckedContinuation { continuation in
                finishContinuations.append(continuation)
            }
        }
    }

    private func configureCompleteSettingsStore(_ settingsStore: ClickySettingsStore) {
        settingsStore.selectedProvider = .openAI
        settingsStore.endpointURLString = "https://api.openai.com"
        settingsStore.modelID = "gpt-5.2-2025-12-11"
        settingsStore.apiKey = "openai-key"
    }

    private func makeTestScreenCapture() -> CompanionScreenCapture {
        let availableScreen = NSScreen.main ?? NSScreen.screens.first!
        return CompanionScreenCapture(
            imageData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            label: "test screen",
            displayWidthInPoints: Int(availableScreen.frame.width),
            displayHeightInPoints: Int(availableScreen.frame.height),
            displayFrame: availableScreen.frame,
            screenshotWidthInPixels: 800,
            screenshotHeightInPixels: 600,
            screen: availableScreen
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let timeoutSeconds = Double(timeoutNanoseconds) / 1_000_000_000
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while await MainActor.run(body: condition) == false {
            try await Task.sleep(nanoseconds: 10_000_000)
            if Date() >= deadline {
                break
            }
        }

        #expect(await MainActor.run(body: condition))
    }

    private struct TestStorageEnvironment {
        let suiteName: String
        let userDefaults: UserDefaults
        let sessionsDirectoryURL: URL
        let keychainSecretStore: KeychainSecretStore

        init() {
            suiteName = "clicky-tests-\(UUID().uuidString)"
            userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
            userDefaults.removePersistentDomain(forName: suiteName)
            sessionsDirectoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            keychainSecretStore = KeychainSecretStore(serviceName: "clicky-tests.\(UUID().uuidString)")
        }

        func makeSessionArchiveStore() -> SessionArchiveStore {
            SessionArchiveStore(
                userDefaults: userDefaults,
                sessionsDirectoryURL: sessionsDirectoryURL
            )
        }

        @MainActor
        func makeSettingsStore() -> ClickySettingsStore {
            ClickySettingsStore(
                userDefaults: userDefaults,
                keychainSecretStore: keychainSecretStore
            )
        }

        func cleanup() {
            for provider in AIProvider.allCases {
                keychainSecretStore.deleteSecret(for: "clicky.\(provider.rawValue).apiKey")
            }
            userDefaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: sessionsDirectoryURL)
        }
    }

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func anthropicEndpointRootURLGetsNormalizedToMessagesPath() async throws {
        let normalizedEndpointURL = ClickySettingsStore.normalizedEndpointURL(
            from: "https://api.anthropic.com",
            provider: .anthropic
        )

        #expect(normalizedEndpointURL?.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test func openAIEndpointRootURLGetsNormalizedToChatCompletionsPath() async throws {
        let normalizedEndpointURL = ClickySettingsStore.normalizedEndpointURL(
            from: "https://api.openai.com",
            provider: .openAI
        )

        #expect(normalizedEndpointURL?.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test func fullAnthropicMessagesEndpointURLIsPreserved() async throws {
        let normalizedEndpointURL = ClickySettingsStore.normalizedEndpointURL(
            from: "https://proxy.example.com/custom/v1/messages",
            provider: .anthropic
        )

        #expect(normalizedEndpointURL?.absoluteString == "https://proxy.example.com/custom/v1/messages")
    }

    @Test func fullOpenAIChatCompletionsEndpointURLIsPreserved() async throws {
        let normalizedEndpointURL = ClickySettingsStore.normalizedEndpointURL(
            from: "https://proxy.example.com/custom/v1/chat/completions",
            provider: .openAI
        )

        #expect(normalizedEndpointURL?.absoluteString == "https://proxy.example.com/custom/v1/chat/completions")
    }

    @Test func invalidEndpointURLReturnsNil() async throws {
        let normalizedEndpointURL = ClickySettingsStore.normalizedEndpointURL(
            from: "localhost:8787",
            provider: .anthropic
        )

        #expect(normalizedEndpointURL == nil)
    }

    @Test func contextTurnLimitDefaultsToFourAndClampsInvalidValues() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        await MainActor.run {
            let settingsStore = testStorageEnvironment.makeSettingsStore()

            #expect(settingsStore.conversationContextTurnLimit == 4)

            settingsStore.conversationContextTurnLimit = 0
            #expect(settingsStore.conversationContextTurnLimit == 1)

            settingsStore.conversationContextTurnLimit = 7
            #expect(settingsStore.conversationContextTurnLimit == 7)
        }

        let reloadedSettingsStore = await MainActor.run {
            testStorageEnvironment.makeSettingsStore()
        }
        #expect(await MainActor.run { reloadedSettingsStore.conversationContextTurnLimit } == 7)
    }

    @Test func providerSpecificConfigurationIsRememberedAcrossSwitches() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        await MainActor.run {
            let settingsStore = testStorageEnvironment.makeSettingsStore()

            settingsStore.selectedProvider = .anthropic
            settingsStore.endpointURLString = "https://anthropic-proxy.example.com"
            settingsStore.modelID = "claude-test"
            settingsStore.apiKey = "anthropic-key"

            settingsStore.selectedProvider = .openAI
            settingsStore.endpointURLString = "https://openai-proxy.example.com"
            settingsStore.modelID = "gpt-test"
            settingsStore.apiKey = "openai-key"

            settingsStore.selectedProvider = .anthropic
            #expect(settingsStore.endpointURLString == "https://anthropic-proxy.example.com")
            #expect(settingsStore.modelID == "claude-test")
            #expect(settingsStore.apiKey == "anthropic-key")

            settingsStore.selectedProvider = .openAI
            #expect(settingsStore.endpointURLString == "https://openai-proxy.example.com")
            #expect(settingsStore.modelID == "gpt-test")
            #expect(settingsStore.apiKey == "openai-key")
        }
    }

    @Test func configurationCompletenessOnlyUsesSelectedProvider() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        await MainActor.run {
            let settingsStore = testStorageEnvironment.makeSettingsStore()

            settingsStore.selectedProvider = .anthropic
            settingsStore.endpointURLString = "https://api.anthropic.com"
            settingsStore.modelID = "claude-test"
            settingsStore.apiKey = "anthropic-key"

            settingsStore.selectedProvider = .openAI
            settingsStore.endpointURLString = "https://api.openai.com"
            settingsStore.modelID = "gpt-test"
            settingsStore.apiKey = ""

            #expect(!settingsStore.isConfigurationComplete)

            settingsStore.apiKey = "openai-key"
            #expect(settingsStore.isConfigurationComplete)

            settingsStore.selectedProvider = .anthropic
            #expect(settingsStore.isConfigurationComplete)
        }
    }

    @Test func sessionArchiveRoundTripsConversationTurnsThroughJSON() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        let sessionArchiveStore = testStorageEnvironment.makeSessionArchiveStore()
        var createdSessionArchive = try sessionArchiveStore.createNewConversationSession(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        createdSessionArchive = createdSessionArchive.appendingConversationTurn(
            userPromptText: "What changed in this PR?",
            assistantResponseText: "The prompt flow is now text-first.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        try sessionArchiveStore.saveArchive(createdSessionArchive)
        let loadedSessionArchive = try sessionArchiveStore.loadArchive(for: createdSessionArchive.sessionID)

        #expect(loadedSessionArchive == createdSessionArchive)
        #expect(loadedSessionArchive?.completedConversationTurns.count == 1)
        #expect(loadedSessionArchive?.completedConversationTurns.first?.userPromptText == "What changed in this PR?")
    }

    @Test func managerContextWindowUsesLatestConfiguredNumberOfTurns() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        let sessionArchiveStore = testStorageEnvironment.makeSessionArchiveStore()

        var createdSessionArchive = try sessionArchiveStore.createNewConversationSession(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        createdSessionArchive = createdSessionArchive.appendingConversationTurn(
            userPromptText: "First",
            assistantResponseText: "Reply one",
            createdAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
        createdSessionArchive = createdSessionArchive.appendingConversationTurn(
            userPromptText: "Second",
            assistantResponseText: "Reply two",
            createdAt: Date(timeIntervalSince1970: 1_700_000_020)
        )
        createdSessionArchive = createdSessionArchive.appendingConversationTurn(
            userPromptText: "Third",
            assistantResponseText: "Reply three",
            createdAt: Date(timeIntervalSince1970: 1_700_000_030)
        )
        try sessionArchiveStore.saveArchive(createdSessionArchive)
        sessionArchiveStore.prepareSessionRestoreDecisionForCurrentLaunch()

        let companionManager = await MainActor.run {
            let settingsStore = testStorageEnvironment.makeSettingsStore()
            settingsStore.conversationContextTurnLimit = 2
            return CompanionManager(
                settingsStore: settingsStore,
                sessionArchiveStore: sessionArchiveStore
            )
        }

        await MainActor.run {
            companionManager.prepareSessionStateForCurrentLaunch()
            companionManager.resumePendingSession()
            #expect(companionManager.conversationTurnsIncludedInAIContext.map(\.userPromptText) == ["Second", "Third"])
            #expect(companionManager.recentConversationHistoryPreviewTurns.count == 2)
        }
    }

    @Test func startNewSessionCreatesANewArchiveAndPreservesTheOldOne() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        let sessionArchiveStore = testStorageEnvironment.makeSessionArchiveStore()
        var createdSessionArchive = try sessionArchiveStore.createNewConversationSession()
        createdSessionArchive = createdSessionArchive.appendingConversationTurn(
            userPromptText: "Explain this screen.",
            assistantResponseText: "It is the previous session.",
            createdAt: Date()
        )
        try sessionArchiveStore.saveArchive(createdSessionArchive)

        let companionManager = await MainActor.run {
            let settingsStore = testStorageEnvironment.makeSettingsStore()
            return CompanionManager(
                settingsStore: settingsStore,
                sessionArchiveStore: sessionArchiveStore
            )
        }

        let previousSessionID = createdSessionArchive.sessionID

        await MainActor.run {
            companionManager.prepareSessionStateForCurrentLaunch()
            companionManager.startNewSession()
            #expect(companionManager.activeSessionArchive?.sessionID != previousSessionID)
            #expect(companionManager.conversationTurnsIncludedInAIContext.isEmpty)
        }

        #expect(sessionArchiveStore.archiveExists(for: previousSessionID))
        let newSessionID = try #require(await MainActor.run { companionManager.activeSessionArchive?.sessionID })
        #expect(sessionArchiveStore.archiveExists(for: newSessionID))
    }

    @Test func pendingSessionRestoreCanResumeOrStartFresh() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        let sessionArchiveStore = testStorageEnvironment.makeSessionArchiveStore()
        var createdSessionArchive = try sessionArchiveStore.createNewConversationSession()
        createdSessionArchive = createdSessionArchive.appendingConversationTurn(
            userPromptText: "Resume me",
            assistantResponseText: "Here is the saved answer.",
            createdAt: Date()
        )
        try sessionArchiveStore.saveArchive(createdSessionArchive)
        sessionArchiveStore.prepareSessionRestoreDecisionForCurrentLaunch()

        let resumeManager = await MainActor.run {
            let settingsStore = testStorageEnvironment.makeSettingsStore()
            return CompanionManager(
                settingsStore: settingsStore,
                sessionArchiveStore: sessionArchiveStore
            )
        }

        await MainActor.run {
            resumeManager.prepareSessionStateForCurrentLaunch()
            #expect(resumeManager.needsSessionRestoreDecision)
            #expect(resumeManager.activeSessionArchive == nil)

            resumeManager.resumePendingSession()
            #expect(!resumeManager.needsSessionRestoreDecision)
            #expect(resumeManager.activeSessionArchive?.sessionID == createdSessionArchive.sessionID)
        }

        sessionArchiveStore.prepareSessionRestoreDecisionForCurrentLaunch()

        let startFreshManager = await MainActor.run {
            let settingsStore = testStorageEnvironment.makeSettingsStore()
            return CompanionManager(
                settingsStore: settingsStore,
                sessionArchiveStore: sessionArchiveStore
            )
        }

        await MainActor.run {
            startFreshManager.prepareSessionStateForCurrentLaunch()
            #expect(startFreshManager.needsSessionRestoreDecision)

            startFreshManager.startNewSession()
            #expect(!startFreshManager.needsSessionRestoreDecision)
            #expect(startFreshManager.activeSessionArchive?.sessionID != createdSessionArchive.sessionID)
        }
    }

    @Test func clearingSessionArchivesRemovesFilesAndActiveRestoreState() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        let sessionArchiveStore = testStorageEnvironment.makeSessionArchiveStore()
        let createdSessionArchive = try sessionArchiveStore.createNewConversationSession()

        #expect(sessionArchiveStore.archiveExists(for: createdSessionArchive.sessionID))
        #expect(sessionArchiveStore.activeSessionID == createdSessionArchive.sessionID)

        try sessionArchiveStore.clearAllSessionArchives()

        #expect(!sessionArchiveStore.archiveExists(for: createdSessionArchive.sessionID))
        #expect(sessionArchiveStore.activeSessionID == nil)
        #expect(!sessionArchiveStore.hasPendingSessionRestoreDecision)
    }

    @Test func managerRequestConfigurationUsesSelectedProviderSettings() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        let companionManager = await MainActor.run {
            let settingsStore = testStorageEnvironment.makeSettingsStore()
            settingsStore.selectedProvider = .openAI
            settingsStore.endpointURLString = "https://api.openai.com"
            settingsStore.modelID = "gpt-5.2-2025-12-11"
            settingsStore.apiKey = "openai-key"

            return CompanionManager(
                settingsStore: settingsStore,
                sessionArchiveStore: testStorageEnvironment.makeSessionArchiveStore()
            )
        }

        let openAIRequestConfiguration = try #require(await MainActor.run {
            companionManager.currentAIRequestConfiguration()
        })
        #expect(openAIRequestConfiguration.provider == .openAI)
        #expect(openAIRequestConfiguration.endpointURL.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(openAIRequestConfiguration.modelID == "gpt-5.2-2025-12-11")
        #expect(openAIRequestConfiguration.apiKey == "openai-key")

        await MainActor.run {
            companionManager.settingsStore.selectedProvider = .anthropic
            companionManager.settingsStore.endpointURLString = "https://api.anthropic.com"
            companionManager.settingsStore.modelID = "claude-sonnet-4-6"
            companionManager.settingsStore.apiKey = "anthropic-key"
        }

        let anthropicRequestConfiguration = try #require(await MainActor.run {
            companionManager.currentAIRequestConfiguration()
        })
        #expect(anthropicRequestConfiguration.provider == .anthropic)
        #expect(anthropicRequestConfiguration.endpointURL.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(anthropicRequestConfiguration.modelID == "claude-sonnet-4-6")
        #expect(anthropicRequestConfiguration.apiKey == "anthropic-key")
    }

    @Test func pointCoordinateParserExtractsDisplayTextAndCoordinate() async throws {
        let parseResult = CompanionManager.parsePointingCoordinates(
            from: "Open the highlighted button first. [POINT:320,240:run button]"
        )

        #expect(parseResult.displayText == "Open the highlighted button first.")
        #expect(parseResult.coordinate?.x == 320)
        #expect(parseResult.coordinate?.y == 240)
        #expect(parseResult.elementLabel == "run button")
    }

    @Test func pointNoneParserKeepsTextAndSkipsCoordinate() async throws {
        let parseResult = CompanionManager.parsePointingCoordinates(
            from: "This command just prints the current branch. [POINT:none]"
        )

        #expect(parseResult.displayText == "This command just prints the current branch.")
        #expect(parseResult.coordinate == nil)
        #expect(parseResult.elementLabel == nil)
    }

    @Test func streamingDisplayTextStripsPointTagPrefix() async throws {
        let displayText = CompanionManager.textForDisplayDuringStreaming(
            "The button is near the bottom toolbar. [POINT:4"
        )

        #expect(displayText == "The button is near the bottom toolbar.")
    }

    @Test func sendKeepsComposerOpenAndShowsTemporaryCurrentTurnOutsideContext() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        let screenCapture = makeTestScreenCapture()
        let streamGate = StreamGate()

        let companionManager = await MainActor.run {
            let settingsStore = testStorageEnvironment.makeSettingsStore()
            configureCompleteSettingsStore(settingsStore)

            return CompanionManager(
                settingsStore: settingsStore,
                sessionArchiveStore: testStorageEnvironment.makeSessionArchiveStore(),
                overlayWindowManager: OverlayWindowManager(),
                hasScreenRecordingPermission: true,
                screenCaptureProvider: { screenCapture },
                streamingResponseAnalyzer: { _, _, _, _, onTextChunk in
                    await onTextChunk("First streamed sentence")
                    await streamGate.markStarted()
                    await streamGate.waitUntilAllowedToFinish()
                    return "First streamed sentence [POINT:none]"
                }
            )
        }

        await MainActor.run {
            companionManager.openPromptComposer()
            companionManager.promptDraft = "Explain the highlighted area."
            companionManager.sendCurrentPromptDraft()

            #expect(companionManager.isPromptComposerPresented)
            #expect(companionManager.isCurrentConversationTurnSelected)
            #expect(companionManager.currentConversationTurn?.promptText == "Explain the highlighted area.")
            #expect(companionManager.conversationTurnsIncludedInAIContext.isEmpty)
            #expect(!companionManager.canSubmitCurrentPromptDraft)
        }

        await streamGate.waitUntilStarted()

        await MainActor.run {
            #expect(companionManager.interfaceState == .streaming)
            #expect(companionManager.currentConversationTurn?.phase == .streaming)
            #expect(companionManager.currentConversationTurn?.responseText == "First streamed sentence")
            if case .currentTurn(let previewTurn)? = companionManager.conversationHistorySidebarItems.first {
                #expect(previewTurn.phase == .streaming)
                #expect(previewTurn.promptPreviewText.contains("Explain the highlighted area"))
                #expect(previewTurn.responsePreviewText.contains("First streamed sentence"))
            } else {
                Issue.record("Expected the temporary current turn to be first in the sidebar.")
            }
        }

        await streamGate.allowFinish()
        try await waitUntil {
            companionManager.interfaceState == .composing && companionManager.currentConversationTurn == nil
        }

        await MainActor.run {
            #expect(companionManager.isPromptComposerPresented)
            #expect(companionManager.completedConversationTurns.count == 1)
            #expect(companionManager.completedConversationTurns.first?.assistantResponseText == "First streamed sentence")
            let completedTurnID = companionManager.completedConversationTurns.first?.turnID
            #expect(companionManager.selectedConversationHistorySelection == completedTurnID.map(ConversationHistorySelection.archivedTurn))
        }
    }

    @Test func streamingTurnAllowsDraftingButBlocksSecondSendUntilCompletion() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        let screenCapture = makeTestScreenCapture()
        let streamGate = StreamGate()

        let companionManager = await MainActor.run {
            let settingsStore = testStorageEnvironment.makeSettingsStore()
            configureCompleteSettingsStore(settingsStore)

            return CompanionManager(
                settingsStore: settingsStore,
                sessionArchiveStore: testStorageEnvironment.makeSessionArchiveStore(),
                overlayWindowManager: OverlayWindowManager(),
                hasScreenRecordingPermission: true,
                screenCaptureProvider: { screenCapture },
                streamingResponseAnalyzer: { _, _, _, _, onTextChunk in
                    await onTextChunk("Streaming now")
                    await streamGate.markStarted()
                    await streamGate.waitUntilAllowedToFinish()
                    return "Streaming now [POINT:none]"
                }
            )
        }

        await MainActor.run {
            companionManager.promptDraft = "First prompt"
            companionManager.sendCurrentPromptDraft()
        }

        await streamGate.waitUntilStarted()

        await MainActor.run {
            companionManager.promptDraft = "Second draft"
            #expect(companionManager.canSendPromptDraft)
            #expect(!companionManager.canSubmitCurrentPromptDraft)
            companionManager.sendCurrentPromptDraft()
            #expect(companionManager.currentConversationTurn?.promptText == "First prompt")
            #expect(companionManager.promptDraft == "Second draft")
            #expect(companionManager.composerValidationMessage == "Wait for the current reply to finish before sending again.")
        }

        await streamGate.allowFinish()
        try await waitUntil {
            companionManager.interfaceState == .idle || companionManager.interfaceState == .composing
        }
    }

    @Test func failedTurnStaysTemporaryAndSurvivesComposerReopen() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        let screenCapture = makeTestScreenCapture()

        let companionManager = await MainActor.run {
            let settingsStore = testStorageEnvironment.makeSettingsStore()
            configureCompleteSettingsStore(settingsStore)

            return CompanionManager(
                settingsStore: settingsStore,
                sessionArchiveStore: testStorageEnvironment.makeSessionArchiveStore(),
                overlayWindowManager: OverlayWindowManager(),
                hasScreenRecordingPermission: true,
                screenCaptureProvider: { screenCapture },
                streamingResponseAnalyzer: { _, _, _, _, _ in
                    struct TestFailure: LocalizedError {
                        var errorDescription: String? { "network unavailable" }
                    }

                    throw TestFailure()
                }
            )
        }

        await MainActor.run {
            companionManager.openPromptComposer()
            companionManager.promptDraft = "Why did this fail?"
            companionManager.sendCurrentPromptDraft()
        }

        try await waitUntil {
            companionManager.currentConversationTurn?.phase == .failed
        }

        await MainActor.run {
            #expect(companionManager.completedConversationTurns.isEmpty)
            #expect(companionManager.currentConversationTurn?.promptText == "Why did this fail?")
            #expect(companionManager.currentConversationTurn?.phase == .failed)
            #expect(companionManager.isPromptComposerPresented)

            companionManager.dismissPromptComposer()
            #expect(!companionManager.isPromptComposerPresented)

            companionManager.openPromptComposer()
            #expect(companionManager.isPromptComposerPresented)
            #expect(companionManager.currentConversationTurn?.phase == .failed)
            #expect(companionManager.isCurrentConversationTurnSelected)
        }
    }

}
