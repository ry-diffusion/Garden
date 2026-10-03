import CryptoKit
import Foundation
import Security

/// iCloud Keychain storage for the Worker token and the device key used to HMAC CPFs (DESIGN §8).
/// Synchronizable, so every device of the same Apple Account computes the same CPF HMACs.
enum Keychain {
    private static let service = "garden"

    static func string(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard let value else { return true }
        var attributes = baseQuery(account)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    /// 32 random bytes, created once and synced. Only ever used as an HMAC key.
    static var deviceKey: SymmetricKey {
        if let stored = string(for: "deviceKey"), let data = Data(base64Encoded: stored) {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        set(key.withUnsafeBytes { Data($0) }.base64EncodedString(), for: "deviceKey")
        return key
    }

    /// HMAC of the CPF digits a bank shows (Open Finance masks to "***.456.789-**" → "456789").
    /// A bare SHA-256 of an 11-digit CPF would be brute-forceable in seconds (REVIEW.md C9).
    static func cpfHMAC(visibleDigits: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(visibleDigits.utf8), using: deviceKey)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}

extension String {
    /// "123.456.789-00" or "***.456.789-**" → "456789": the digits banks leave visible in masked CPFs.
    var cpfVisibleDigits: String? {
        let characters = Array(filter { $0.isNumber || $0 == "*" })
        guard characters.count == 11 else { return nil }
        let middle = String(characters[3..<9])
        return middle.allSatisfy(\.isNumber) ? middle : nil
    }
}
