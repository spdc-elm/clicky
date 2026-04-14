//
//  ClickySettingsStore.swift
//  leanring-buddy
//
//  Persists provider-specific endpoint, model, and API key configuration for direct AI requests.
//

import Combine
import Foundation
import KeyboardShortcuts

enum AIProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openAI = "openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic:
            return "Anthropic"
        case .openAI:
            return "OpenAI"
        }
    }

    var defaultEndpointURLString: String {
        switch self {
        case .anthropic:
            return "https://api.anthropic.com"
        case .openAI:
            return "https://api.openai.com"
        }
    }

    var defaultModelID: String {
        switch self {
        case .anthropic:
            return "claude-sonnet-4-6"
        case .openAI:
            return "gpt-5.2-2025-12-11"
        }
    }

    var endpointPathWhenOnlyRootURLIsProvided: String {
        switch self {
        case .anthropic:
            return "/v1/messages"
        case .openAI:
            return "/v1/chat/completions"
        }
    }

    var endpointFieldPlaceholder: String {
        switch self {
        case .anthropic:
            return "https://api.anthropic.com or a full /v1/messages URL"
        case .openAI:
            return "https://api.openai.com or a full /v1/chat/completions URL"
        }
    }

    var apiKeyFieldPlaceholder: String {
        switch self {
        case .anthropic:
            return "sk-ant-..."
        case .openAI:
            return "sk-..."
        }
    }

    var footerEndpointDescription: String {
        switch self {
        case .anthropic:
            return "Anthropic Messages endpoint"
        case .openAI:
            return "OpenAI Chat Completions endpoint"
        }
    }
}

@MainActor
final class ClickySettingsStore: ObservableObject {
    private enum UserDefaultsKey {
        static let selectedProvider = "clicky.selectedProvider"
        static let conversationContextTurnLimit = "clicky.conversationContextTurnLimit"

        static func endpointURLString(for provider: AIProvider) -> String {
            "clicky.\(provider.rawValue).endpointURLString"
        }

        static func modelID(for provider: AIProvider) -> String {
            "clicky.\(provider.rawValue).modelID"
        }
    }

    private enum KeychainAccount {
        static func apiKey(for provider: AIProvider) -> String {
            "clicky.\(provider.rawValue).apiKey"
        }
    }

    static let defaultConversationContextTurnLimit = 4

    @Published var selectedProvider: AIProvider {
        didSet {
            userDefaults.set(selectedProvider.rawValue, forKey: UserDefaultsKey.selectedProvider)
            loadSelectedProviderConfigurationIntoPublishedProperties()
        }
    }

    @Published var endpointURLString: String {
        didSet {
            endpointURLStringByProvider[selectedProvider] = endpointURLString
            userDefaults.set(endpointURLString, forKey: UserDefaultsKey.endpointURLString(for: selectedProvider))
        }
    }

    @Published var modelID: String {
        didSet {
            modelIDByProvider[selectedProvider] = modelID
            userDefaults.set(modelID, forKey: UserDefaultsKey.modelID(for: selectedProvider))
        }
    }

    @Published var apiKey: String {
        didSet {
            apiKeyByProvider[selectedProvider] = apiKey
            keychainSecretStore.saveSecret(apiKey, for: KeychainAccount.apiKey(for: selectedProvider))
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

    private var endpointURLStringByProvider: [AIProvider: String]
    private var modelIDByProvider: [AIProvider: String]
    private var apiKeyByProvider: [AIProvider: String]

    init(
        userDefaults: UserDefaults = .standard,
        keychainSecretStore: KeychainSecretStore? = nil
    ) {
        let resolvedKeychainSecretStore = keychainSecretStore ?? KeychainSecretStore()
        let initialEndpointURLStringByProvider = Dictionary(
            uniqueKeysWithValues: AIProvider.allCases.map { provider in
                let savedEndpointURLString = userDefaults.string(
                    forKey: UserDefaultsKey.endpointURLString(for: provider)
                )
                return (provider, savedEndpointURLString ?? provider.defaultEndpointURLString)
            }
        )
        let initialModelIDByProvider = Dictionary(
            uniqueKeysWithValues: AIProvider.allCases.map { provider in
                let savedModelID = userDefaults.string(forKey: UserDefaultsKey.modelID(for: provider))
                return (provider, savedModelID ?? provider.defaultModelID)
            }
        )
        let initialAPIKeyByProvider = Dictionary(
            uniqueKeysWithValues: AIProvider.allCases.map { provider in
                (provider, resolvedKeychainSecretStore.readSecret(for: KeychainAccount.apiKey(for: provider)))
            }
        )
        let savedSelectedProviderRawValue = userDefaults.string(forKey: UserDefaultsKey.selectedProvider)
        let initialSelectedProvider = AIProvider(rawValue: savedSelectedProviderRawValue ?? "") ?? .anthropic

        self.userDefaults = userDefaults
        self.keychainSecretStore = resolvedKeychainSecretStore
        self.endpointURLStringByProvider = initialEndpointURLStringByProvider
        self.modelIDByProvider = initialModelIDByProvider
        self.apiKeyByProvider = initialAPIKeyByProvider
        self.selectedProvider = initialSelectedProvider
        self.endpointURLString = initialEndpointURLStringByProvider[initialSelectedProvider]
            ?? initialSelectedProvider.defaultEndpointURLString
        self.modelID = initialModelIDByProvider[initialSelectedProvider]
            ?? initialSelectedProvider.defaultModelID
        self.apiKey = initialAPIKeyByProvider[initialSelectedProvider] ?? ""
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
        Self.normalizedEndpointURL(from: trimmedEndpointURLString, provider: selectedProvider)
    }

    static func normalizedEndpointURL(from endpointURLString: String, provider: AIProvider) -> URL? {
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
            components.path = provider.endpointPathWhenOnlyRootURLIsProvided
        }

        return components.url
    }

    static func normalizedConversationContextTurnLimit(from conversationContextTurnLimit: Int?) -> Int {
        guard let conversationContextTurnLimit else {
            return defaultConversationContextTurnLimit
        }

        return max(1, conversationContextTurnLimit)
    }

    private func loadSelectedProviderConfigurationIntoPublishedProperties() {
        endpointURLString = endpointURLStringByProvider[selectedProvider] ?? selectedProvider.defaultEndpointURLString
        modelID = modelIDByProvider[selectedProvider] ?? selectedProvider.defaultModelID
        apiKey = apiKeyByProvider[selectedProvider] ?? ""
    }
}
