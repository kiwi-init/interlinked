import Foundation
import Security

/// The key never enters preferences, the session file, diagnostics, or control output.
enum JevCredential {
    private static var item: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "computer.interlinked.openrouter",
        kSecAttrAccount as String: "api-key"
    ] }

    private static func contains() -> Bool {
        var query = item
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    private static func value() throws -> String {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw JevError.noKey }
        return key
    }

    private static func store(_ value: String) throws {
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = item.merging(attributes) { _, new in new }
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            query[kSecAttrLabel as String] = "Interlinked OpenRouter API key"
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw JevError.unavailable }
        } else if status != errSecSuccess {
            throw JevError.unavailable
        }
    }

    /// UI checks never request protected data or open an authentication dialog.
    static func exists() -> Bool {
        contains()
    }

    static func read() throws -> String {
        try value()
    }

    static func save(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { throw JevError.noKey }
        try store(value)
    }

    static func remove() {
        SecItemDelete(item as CFDictionary)
    }
}
