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
    }

    private enum KeychainAccount {
        static let apiKey = "clicky.apiKey"
    }

    @Published var endpointURLString: String {
        didSet {
            UserDefaults.standard.set(endpointURLString, forKey: UserDefaultsKey.endpointURLString)
        }
    }

    @Published var modelID: String {
        didSet {
            UserDefaults.standard.set(modelID, forKey: UserDefaultsKey.modelID)
        }
    }

    @Published var apiKey: String {
        didSet {
            keychainSecretStore.saveSecret(apiKey, for: KeychainAccount.apiKey)
        }
    }

    private let keychainSecretStore: KeychainSecretStore

    init(keychainSecretStore: KeychainSecretStore? = nil) {
        self.keychainSecretStore = keychainSecretStore ?? KeychainSecretStore()
        self.endpointURLString = UserDefaults.standard.string(forKey: UserDefaultsKey.endpointURLString) ?? ""
        self.modelID = UserDefaults.standard.string(forKey: UserDefaultsKey.modelID) ?? "claude-sonnet-4-6"
        self.apiKey = self.keychainSecretStore.readSecret(for: KeychainAccount.apiKey)
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
}
