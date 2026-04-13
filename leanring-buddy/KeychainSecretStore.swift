//
//  KeychainSecretStore.swift
//  leanring-buddy
//
//  Minimal Keychain wrapper used for storing the user's API key locally.
//

import Foundation
import Security

struct KeychainSecretStore {
    private let serviceName: String

    init(serviceName: String = Bundle.main.bundleIdentifier ?? "com.clicky.app") {
        self.serviceName = serviceName
    }

    func readSecret(for accountName: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            return ""
        }

        return secret
    }

    func saveSecret(_ secret: String, for accountName: String) {
        if secret.isEmpty {
            deleteSecret(for: accountName)
            return
        }

        let encodedSecret = Data(secret.utf8)
        let existingItemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]

        let updatedAttributes: [String: Any] = [
            kSecValueData as String: encodedSecret
        ]

        let updateStatus = SecItemUpdate(existingItemQuery as CFDictionary, updatedAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        let newItemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecValueData as String: encodedSecret
        ]

        SecItemAdd(newItemQuery as CFDictionary, nil)
    }

    func deleteSecret(for accountName: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]

        SecItemDelete(query as CFDictionary)
    }
}
