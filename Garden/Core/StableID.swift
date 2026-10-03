import CryptoKit
import Foundation

/// Deterministic identifiers so two devices that create the same record
/// produce the same id, letting CloudKit collapse duplicates (DESIGN §4.2).
enum StableID {
    /// RFC 4122 UUIDv5 namespace for Garden provenance keys.
    private static let namespace = UUID(uuidString: "6F1C2A4E-3B7D-4E8A-9C21-5D0B7E4F9A13")!

    static func uuid(for key: String) -> UUID {
        var bytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        bytes.append(contentsOf: Array(key.utf8))
        var hash = Array(Insecure.SHA1.hash(data: bytes)).prefix(16).map { $0 }
        hash[6] = (hash[6] & 0x0F) | 0x50  // version 5
        hash[8] = (hash[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension String {
    /// Uppercased, accent-free, single-spaced — the form used for matching merchants and building keys.
    var normalizedForMatching: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .uppercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
