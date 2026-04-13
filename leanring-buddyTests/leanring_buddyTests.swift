//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

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
