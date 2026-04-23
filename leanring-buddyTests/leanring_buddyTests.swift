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

    private func makeTestJPEGData(width: Int = 800, height: Int = 600) -> Data {
        let bitmapRepresentation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )

        guard let bitmapRepresentation else {
            return Data([0xFF, 0xD8, 0xFF, 0xD9])
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRepresentation)
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))).fill()
        NSGraphicsContext.restoreGraphicsState()

        return bitmapRepresentation.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.9]
        ) ?? Data([0xFF, 0xD8, 0xFF, 0xD9])
    }

    private func makeTestScreenCapture() -> CompanionScreenCapture {
        let availableScreen = NSScreen.main ?? NSScreen.screens.first!
        return CompanionScreenCapture(
            imageData: makeTestJPEGData(),
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

    private func openPromptComposerAndWaitForFrozenCapture(_ companionManager: CompanionManager) async throws {
        await MainActor.run {
            companionManager.openPromptComposer()
        }

        try await waitUntil {
            companionManager.frozenScreenCapture.map { _ in true } == true
        }
    }

    private struct TestStorageEnvironment {
        let suiteName: String
        let userDefaults: UserDefaults
        let homeDirectoryURL: URL
        let clickyHomePaths: ClickyHomePaths
        let legacySessionsDirectoryURL: URL
        let bundledPromptDefaultsDirectoryURL: URL
        let keychainSecretStore: KeychainSecretStore

        init() {
            suiteName = "clicky-tests-\(UUID().uuidString)"
            userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
            userDefaults.removePersistentDomain(forName: suiteName)
            homeDirectoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            clickyHomePaths = ClickyHomePaths(homeDirectoryURL: homeDirectoryURL)
            legacySessionsDirectoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            bundledPromptDefaultsDirectoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            keychainSecretStore = KeychainSecretStore(serviceName: "clicky-tests.\(UUID().uuidString)")

            try? FileManager.default.createDirectory(
                at: bundledPromptDefaultsDirectoryURL,
                withIntermediateDirectories: true
            )
            try? """
            bundled system prompt
            """.write(
                to: bundledPromptDefaultsDirectoryURL.appendingPathComponent("text-response-system.md"),
                atomically: true,
                encoding: .utf8
            )
            try? """
            The question is: {{user_question}}
            """.write(
                to: bundledPromptDefaultsDirectoryURL.appendingPathComponent("element-location-user.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        func makeSessionArchiveStore() -> SessionArchiveStore {
            SessionArchiveStore(
                userDefaults: userDefaults,
                clickyHomePaths: clickyHomePaths,
                legacySessionsDirectoryURL: legacySessionsDirectoryURL
            )
        }

        @MainActor
        func makeSettingsStore() -> ClickySettingsStore {
            ClickySettingsStore(
                userDefaults: userDefaults,
                keychainSecretStore: keychainSecretStore
            )
        }

        func makePromptStore() -> ClickyPromptStore {
            ClickyPromptStore(
                clickyHomePaths: clickyHomePaths,
                bundledPromptDefaultsDirectoryURL: bundledPromptDefaultsDirectoryURL
            )
        }

        func cleanup() {
            for provider in AIProvider.allCases {
                keychainSecretStore.deleteSecret(for: "clicky.\(provider.rawValue).apiKey")
            }
            userDefaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: homeDirectoryURL)
            try? FileManager.default.removeItem(at: legacySessionsDirectoryURL)
            try? FileManager.default.removeItem(at: bundledPromptDefaultsDirectoryURL)
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

    @Test func promptStoreUsesExternalOverrideBeforeBundledDefault() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        try FileManager.default.createDirectory(
            at: testStorageEnvironment.clickyHomePaths.promptsDirectoryURL,
            withIntermediateDirectories: true
        )
        let externalPromptFileURL = testStorageEnvironment.clickyHomePaths.promptsDirectoryURL
            .appendingPathComponent("text-response-system.md")
        try """
        external system prompt
        """.write(to: externalPromptFileURL, atomically: true, encoding: .utf8)

        let resolvedPrompt = try testStorageEnvironment.makePromptStore().resolvedPrompt(for: .textResponseSystem)

        #expect(resolvedPrompt.text == "external system prompt")
        #expect(resolvedPrompt.source == .externalOverride(externalPromptFileURL))
    }

    @Test func promptStoreFallsBackToBundledDefaultWhenExternalPromptIsMissing() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        let resolvedPrompt = try testStorageEnvironment.makePromptStore().resolvedPrompt(for: .textResponseSystem)
        let exportedPromptFileURL = testStorageEnvironment.clickyHomePaths.promptsDirectoryURL
            .appendingPathComponent("text-response-system.md")
        let exportedPromptText = try String(contentsOf: exportedPromptFileURL, encoding: .utf8)

        #expect(resolvedPrompt.text == "bundled system prompt")
        #expect(exportedPromptText == "bundled system prompt")
    }

    @Test func promptStoreFallsBackToBundledDefaultWhenExternalPromptIsInvalid() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        try FileManager.default.createDirectory(
            at: testStorageEnvironment.clickyHomePaths.promptsDirectoryURL,
            withIntermediateDirectories: true
        )
        let invalidExternalPromptFileURL = testStorageEnvironment.clickyHomePaths.promptsDirectoryURL
            .appendingPathComponent("element-location-user.md")
        try """
        no placeholder here
        """.write(to: invalidExternalPromptFileURL, atomically: true, encoding: .utf8)

        let resolvedPrompt = try testStorageEnvironment.makePromptStore().resolvedPrompt(for: .elementLocationUser)
        let repairedPromptText = try String(contentsOf: invalidExternalPromptFileURL, encoding: .utf8)

        #expect(resolvedPrompt.text == "The question is: {{user_question}}")
        #expect(repairedPromptText == "The question is: {{user_question}}")
        if case .bundledDefault = resolvedPrompt.source {
            #expect(Bool(true))
        } else {
            Issue.record("Expected the invalid external element-location prompt to fall back to the bundled default.")
        }
    }

    @Test func promptStoreCreatesPromptOverridesDirectoryForOpening() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        let promptsDirectoryURL = try testStorageEnvironment.makePromptStore().promptsDirectoryURLForOpening()
        let exportedSystemPromptFileURL = promptsDirectoryURL.appendingPathComponent("text-response-system.md")
        let exportedElementPromptFileURL = promptsDirectoryURL.appendingPathComponent("element-location-user.md")

        var isDirectory: ObjCBool = false
        let promptDirectoryExists = FileManager.default.fileExists(
            atPath: promptsDirectoryURL.path,
            isDirectory: &isDirectory
        )

        #expect(promptDirectoryExists)
        #expect(isDirectory.boolValue)
        #expect(promptsDirectoryURL == testStorageEnvironment.clickyHomePaths.promptsDirectoryURL)
        #expect(FileManager.default.fileExists(atPath: exportedSystemPromptFileURL.path))
        #expect(FileManager.default.fileExists(atPath: exportedElementPromptFileURL.path))
    }

    @Test func elementLocationPromptTemplateRendersUserQuestion() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        let elementLocationDetector = ElementLocationDetector(
            apiKey: "anthropic-key",
            promptStore: testStorageEnvironment.makePromptStore()
        )

        let renderedPrompt = try elementLocationDetector.renderedElementLocationUserPrompt(
            for: "Where should I click?"
        )

        #expect(renderedPrompt == "The question is: Where should I click?")
    }

    @Test func sessionArchiveStoreDefaultsToClickyHomeSessionsDirectory() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        let sessionArchiveStore = testStorageEnvironment.makeSessionArchiveStore()
        let createdSessionArchive = try sessionArchiveStore.createNewConversationSession()
        let expectedArchiveFileURL = testStorageEnvironment.clickyHomePaths.sessionsDirectoryURL
            .appendingPathComponent("\(createdSessionArchive.sessionID.uuidString).json")

        #expect(FileManager.default.fileExists(atPath: expectedArchiveFileURL.path))
    }

    @Test func sessionArchiveStoreMigratesLegacyArchivesIntoClickyHomeSessionsDirectory() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        try FileManager.default.createDirectory(
            at: testStorageEnvironment.legacySessionsDirectoryURL,
            withIntermediateDirectories: true
        )

        let legacySessionArchive = ClickySessionArchive.emptyConversationSession(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ).appendingConversationTurn(
            userPromptText: "Legacy question",
            assistantResponseText: "Legacy answer",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        jsonEncoder.dateEncodingStrategy = .iso8601
        let legacyArchiveData = try jsonEncoder.encode(legacySessionArchive)
        let legacyArchiveFileURL = testStorageEnvironment.legacySessionsDirectoryURL
            .appendingPathComponent("\(legacySessionArchive.sessionID.uuidString).json")
        try legacyArchiveData.write(to: legacyArchiveFileURL, options: .atomic)
        testStorageEnvironment.userDefaults.set(
            legacySessionArchive.sessionID.uuidString,
            forKey: "clicky.activeSessionID"
        )

        let sessionArchiveStore = testStorageEnvironment.makeSessionArchiveStore()
        sessionArchiveStore.prepareSessionRestoreDecisionForCurrentLaunch()
        let migratedArchive = try sessionArchiveStore.loadRecoverableActiveSessionArchive()
        let migratedArchiveFileURL = testStorageEnvironment.clickyHomePaths.sessionsDirectoryURL
            .appendingPathComponent("\(legacySessionArchive.sessionID.uuidString).json")

        #expect(migratedArchive == legacySessionArchive)
        #expect(FileManager.default.fileExists(atPath: migratedArchiveFileURL.path))
        #expect(FileManager.default.fileExists(atPath: legacyArchiveFileURL.path))
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

    @Test func openingComposerCapturesFrozenScreenOnceAndSendReusesIt() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        let screenCapture = makeTestScreenCapture()
        var captureRequestCount = 0
        var sentImages: [(data: Data, label: String)] = []

        let companionManager = await MainActor.run {
            let settingsStore = testStorageEnvironment.makeSettingsStore()
            configureCompleteSettingsStore(settingsStore)

            return CompanionManager(
                settingsStore: settingsStore,
                sessionArchiveStore: testStorageEnvironment.makeSessionArchiveStore(),
                promptStore: testStorageEnvironment.makePromptStore(),
                overlayWindowManager: OverlayWindowManager(),
                hasScreenRecordingPermission: true,
                screenCaptureProvider: {
                    captureRequestCount += 1
                    return screenCapture
                },
                streamingResponseAnalyzer: { _, _, images, _, _, _ in
                    sentImages = images
                    return "Frozen capture reused [POINT:none]"
                }
            )
        }

        try await openPromptComposerAndWaitForFrozenCapture(companionManager)

        await MainActor.run {
            #expect(captureRequestCount == 1)
            #expect(!companionManager.isFrozenScreenAnnotationEditorPresented)
            companionManager.showFrozenScreenAnnotationEditor()
            #expect(companionManager.isFrozenScreenAnnotationEditorPresented)
            companionManager.hideFrozenScreenAnnotationEditor()
            #expect(!companionManager.isFrozenScreenAnnotationEditorPresented)
            companionManager.promptDraft = "Use the frozen screen."
            companionManager.sendCurrentPromptDraft()
        }

        try await waitUntil {
            companionManager.completedConversationTurns.count == 1
        }

        await MainActor.run {
            #expect(captureRequestCount == 1)
            #expect(sentImages.count == 1)
            #expect(sentImages.first?.data == screenCapture.imageData)
            #expect(companionManager.hasFrozenScreenCapture)
        }
    }

    @Test func sendWithoutFrozenScreenCaptureShowsValidationAndDoesNotStream() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        var didStartStreaming = false

        let companionManager = await MainActor.run {
            let settingsStore = testStorageEnvironment.makeSettingsStore()
            configureCompleteSettingsStore(settingsStore)

            return CompanionManager(
                settingsStore: settingsStore,
                sessionArchiveStore: testStorageEnvironment.makeSessionArchiveStore(),
                promptStore: testStorageEnvironment.makePromptStore(),
                overlayWindowManager: OverlayWindowManager(),
                hasScreenRecordingPermission: true,
                screenCaptureProvider: { makeTestScreenCapture() },
                streamingResponseAnalyzer: { _, _, _, _, _, _ in
                    didStartStreaming = true
                    return "Should not run [POINT:none]"
                }
            )
        }

        await MainActor.run {
            companionManager.promptDraft = "This should not send."
            companionManager.sendCurrentPromptDraft()

            #expect(!didStartStreaming)
            #expect(companionManager.completedConversationTurns.isEmpty)
            #expect(companionManager.composerValidationMessage == "Open Clicky with Screen Recording enabled so it can freeze your current screen.")
        }
    }

    @Test func annotatedFrozenScreenCapturePreservesImageDimensionsWhenSent() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        let screenCapture = makeTestScreenCapture()
        var sentImageData: Data?
        var sentImageLabel: String?

        let companionManager = await MainActor.run {
            let settingsStore = testStorageEnvironment.makeSettingsStore()
            configureCompleteSettingsStore(settingsStore)

            return CompanionManager(
                settingsStore: settingsStore,
                sessionArchiveStore: testStorageEnvironment.makeSessionArchiveStore(),
                promptStore: testStorageEnvironment.makePromptStore(),
                overlayWindowManager: OverlayWindowManager(),
                hasScreenRecordingPermission: true,
                screenCaptureProvider: { screenCapture },
                streamingResponseAnalyzer: { _, _, images, _, _, _ in
                    sentImageData = images.first?.data
                    sentImageLabel = images.first?.label
                    return "Annotated capture sent [POINT:none]"
                }
            )
        }

        try await openPromptComposerAndWaitForFrozenCapture(companionManager)

        await MainActor.run {
            companionManager.appendFrozenScreenAnnotation(
                FrozenScreenAnnotation(
                    tool: .rectangle,
                    points: [
                        CGPoint(x: 100, y: 100),
                        CGPoint(x: 300, y: 260)
                    ]
                )
            )
            companionManager.promptDraft = "What did I mark?"
            companionManager.sendCurrentPromptDraft()
        }

        try await waitUntil {
            companionManager.completedConversationTurns.count == 1
        }

        guard let sentImageData,
              let sentBitmapRepresentation = NSBitmapImageRep(data: sentImageData) else {
            Issue.record("Expected an annotated screenshot image.")
            return
        }

        #expect(sentBitmapRepresentation.pixelsWide == screenCapture.screenshotWidthInPixels)
        #expect(sentBitmapRepresentation.pixelsHigh == screenCapture.screenshotHeightInPixels)
        #expect(sentImageLabel?.contains("with annotations") == true)
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
                promptStore: testStorageEnvironment.makePromptStore(),
                overlayWindowManager: OverlayWindowManager(),
                hasScreenRecordingPermission: true,
                screenCaptureProvider: { screenCapture },
                streamingResponseAnalyzer: { _, _, _, _, _, onTextChunk in
                    await onTextChunk("First streamed sentence")
                    await streamGate.markStarted()
                    await streamGate.waitUntilAllowedToFinish()
                    return "First streamed sentence [POINT:none]"
                }
            )
        }

        try await openPromptComposerAndWaitForFrozenCapture(companionManager)

        await MainActor.run {
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
                promptStore: testStorageEnvironment.makePromptStore(),
                overlayWindowManager: OverlayWindowManager(),
                hasScreenRecordingPermission: true,
                screenCaptureProvider: { screenCapture },
                streamingResponseAnalyzer: { _, _, _, _, _, onTextChunk in
                    await onTextChunk("Streaming now")
                    await streamGate.markStarted()
                    await streamGate.waitUntilAllowedToFinish()
                    return "Streaming now [POINT:none]"
                }
            )
        }

        try await openPromptComposerAndWaitForFrozenCapture(companionManager)

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
                promptStore: testStorageEnvironment.makePromptStore(),
                overlayWindowManager: OverlayWindowManager(),
                hasScreenRecordingPermission: true,
                screenCaptureProvider: { screenCapture },
                streamingResponseAnalyzer: { _, _, _, _, _, _ in
                    struct TestFailure: LocalizedError {
                        var errorDescription: String? { "network unavailable" }
                    }

                    throw TestFailure()
                }
            )
        }

        try await openPromptComposerAndWaitForFrozenCapture(companionManager)

        await MainActor.run {
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

        }

        try await openPromptComposerAndWaitForFrozenCapture(companionManager)

        await MainActor.run {
            #expect(companionManager.isPromptComposerPresented)
            #expect(companionManager.currentConversationTurn?.phase == .failed)
            #expect(companionManager.isCurrentConversationTurnSelected)
        }
    }

    @Test func sendPassesResolvedSystemPromptIntoStreamingAnalyzer() async throws {
        let testStorageEnvironment = TestStorageEnvironment()
        defer { testStorageEnvironment.cleanup() }

        try FileManager.default.createDirectory(
            at: testStorageEnvironment.clickyHomePaths.promptsDirectoryURL,
            withIntermediateDirectories: true
        )
        try """
        external analyzer system prompt
        """.write(
            to: testStorageEnvironment.clickyHomePaths.promptsDirectoryURL
                .appendingPathComponent("text-response-system.md"),
            atomically: true,
            encoding: .utf8
        )

        let screenCapture = makeTestScreenCapture()
        var capturedSystemPrompt: String?

        let companionManager = await MainActor.run {
            let settingsStore = testStorageEnvironment.makeSettingsStore()
            configureCompleteSettingsStore(settingsStore)

            return CompanionManager(
                settingsStore: settingsStore,
                sessionArchiveStore: testStorageEnvironment.makeSessionArchiveStore(),
                promptStore: testStorageEnvironment.makePromptStore(),
                overlayWindowManager: OverlayWindowManager(),
                hasScreenRecordingPermission: true,
                screenCaptureProvider: { screenCapture },
                streamingResponseAnalyzer: { _, systemPrompt, _, _, _, _ in
                    capturedSystemPrompt = systemPrompt
                    return "Prompt received [POINT:none]"
                }
            )
        }

        try await openPromptComposerAndWaitForFrozenCapture(companionManager)

        await MainActor.run {
            companionManager.promptDraft = "Capture the prompt wiring."
            companionManager.sendCurrentPromptDraft()
        }

        try await waitUntil {
            companionManager.completedConversationTurns.count == 1
        }

        #expect(capturedSystemPrompt == "external analyzer system prompt")
    }

}
