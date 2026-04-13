//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Foundation
import Testing
@testable import Clicky

@MainActor
struct leanring_buddyTests {

    private struct TestStorageEnvironment {
        let suiteName: String
        let userDefaults: UserDefaults
        let sessionsDirectoryURL: URL

        init() {
            suiteName = "clicky-tests-\(UUID().uuidString)"
            userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
            userDefaults.removePersistentDomain(forName: suiteName)
            sessionsDirectoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        }

        func makeSessionArchiveStore() -> SessionArchiveStore {
            SessionArchiveStore(
                userDefaults: userDefaults,
                sessionsDirectoryURL: sessionsDirectoryURL
            )
        }

        func cleanup() {
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

    @Test func endpointRootURLGetsNormalizedToMessagesPath() async throws {
        let normalizedEndpointURL = ClickySettingsStore.normalizedEndpointURL(from: "https://api.anthropic.com")

        #expect(normalizedEndpointURL?.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test func fullMessagesEndpointURLIsPreserved() async throws {
        let normalizedEndpointURL = ClickySettingsStore.normalizedEndpointURL(
            from: "https://proxy.example.com/custom/v1/messages"
        )

        #expect(normalizedEndpointURL?.absoluteString == "https://proxy.example.com/custom/v1/messages")
    }

    @Test func invalidEndpointURLReturnsNil() async throws {
        let normalizedEndpointURL = ClickySettingsStore.normalizedEndpointURL(from: "localhost:8787")

        #expect(normalizedEndpointURL == nil)
    }

    @Test func contextTurnLimitDefaultsToFourAndClampsInvalidValues() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        await MainActor.run {
            let settingsStore = ClickySettingsStore(
                userDefaults: testStorageEnvironment.userDefaults,
                keychainSecretStore: KeychainSecretStore()
            )

            #expect(settingsStore.conversationContextTurnLimit == 4)

            settingsStore.conversationContextTurnLimit = 0
            #expect(settingsStore.conversationContextTurnLimit == 1)

            settingsStore.conversationContextTurnLimit = 7
            #expect(settingsStore.conversationContextTurnLimit == 7)
        }

        let reloadedSettingsStore = await MainActor.run {
            ClickySettingsStore(
                userDefaults: testStorageEnvironment.userDefaults,
                keychainSecretStore: KeychainSecretStore()
            )
        }
        #expect(await MainActor.run { reloadedSettingsStore.conversationContextTurnLimit } == 7)
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
            let settingsStore = ClickySettingsStore(
                userDefaults: testStorageEnvironment.userDefaults,
                keychainSecretStore: KeychainSecretStore()
            )
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
            let settingsStore = ClickySettingsStore(
                userDefaults: testStorageEnvironment.userDefaults,
                keychainSecretStore: KeychainSecretStore()
            )
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
            let settingsStore = ClickySettingsStore(
                userDefaults: testStorageEnvironment.userDefaults,
                keychainSecretStore: KeychainSecretStore()
            )
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
            let settingsStore = ClickySettingsStore(
                userDefaults: testStorageEnvironment.userDefaults,
                keychainSecretStore: KeychainSecretStore()
            )
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

}
