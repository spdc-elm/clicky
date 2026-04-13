//
//  ClickySettingsStore.swift
//  leanring-buddy
//
//  Persists endpoint, model, and API key configuration for direct Anthropic-compatible requests.
//

import Combine
import Foundation
import KeyboardShortcuts

@MainActor
final class ClickySettingsStore: ObservableObject {
    private enum UserDefaultsKey {
        static let endpointURLString = "clicky.endpointURLString"
        static let modelID = "clicky.modelID"
        static let conversationContextTurnLimit = "clicky.conversationContextTurnLimit"
    }

    private enum KeychainAccount {
        static let apiKey = "clicky.apiKey"
    }

    static let defaultConversationContextTurnLimit = 4

    @Published var endpointURLString: String {
        didSet {
            userDefaults.set(endpointURLString, forKey: UserDefaultsKey.endpointURLString)
        }
    }

    @Published var modelID: String {
        didSet {
            userDefaults.set(modelID, forKey: UserDefaultsKey.modelID)
        }
    }

    @Published var apiKey: String {
        didSet {
            keychainSecretStore.saveSecret(apiKey, for: KeychainAccount.apiKey)
        }
    }

    @Published var conversationContextTurnLimit: Int {
        didSet {
            let normalizedConversationContextTurnLimit = Self.normalizedConversationContextTurnLimit(
                from: conversationContextTurnLimit
            )

            if conversationContextTurnLimit != normalizedConversationContextTurnLimit {
                conversationContextTurnLimit = normalizedConversationContextTurnLimit
                return
            }

            userDefaults.set(
                normalizedConversationContextTurnLimit,
                forKey: UserDefaultsKey.conversationContextTurnLimit
            )
        }
    }

    private let userDefaults: UserDefaults
    private let keychainSecretStore: KeychainSecretStore

    init(
        userDefaults: UserDefaults = .standard,
        keychainSecretStore: KeychainSecretStore? = nil
    ) {
        self.userDefaults = userDefaults
        self.keychainSecretStore = keychainSecretStore ?? KeychainSecretStore()
        self.endpointURLString = userDefaults.string(forKey: UserDefaultsKey.endpointURLString) ?? ""
        self.modelID = userDefaults.string(forKey: UserDefaultsKey.modelID) ?? "claude-sonnet-4-6"
        self.apiKey = self.keychainSecretStore.readSecret(for: KeychainAccount.apiKey)
        self.conversationContextTurnLimit = Self.normalizedConversationContextTurnLimit(
            from: userDefaults.object(forKey: UserDefaultsKey.conversationContextTurnLimit) as? Int
        )
    }

    var trimmedEndpointURLString: String {
        endpointURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedModelID: String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigurationComplete: Bool {
        resolvedEndpointURL() != nil && !trimmedModelID.isEmpty && !trimmedAPIKey.isEmpty
    }

    var hasConfiguredShortcut: Bool {
        KeyboardShortcuts.getShortcut(for: .openPromptComposer) != nil
    }

    func resolvedEndpointURL() -> URL? {
        Self.normalizedEndpointURL(from: trimmedEndpointURLString)
    }

    static func normalizedEndpointURL(from endpointURLString: String) -> URL? {
        let trimmedInput = endpointURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty,
              var components = URLComponents(string: trimmedInput),
              let scheme = components.scheme,
              !scheme.isEmpty,
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        let currentPath = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentPath.isEmpty || currentPath == "/" {
            components.path = "/v1/messages"
        }

        return components.url
    }

    static func normalizedConversationContextTurnLimit(from conversationContextTurnLimit: Int?) -> Int {
        guard let conversationContextTurnLimit else {
            return defaultConversationContextTurnLimit
        }

        return max(1, conversationContextTurnLimit)
    }
}
