import CryptoKit
import Foundation
import Security

/// A push certificate (with its private key) already in the user's keychain.
public struct PushIdentity: Sendable, Hashable, Identifiable {
    public var name: String
    public var sha256: String
    public var bundleId: String?
    public var environments: [PushEnvironment]
    public var id: String { sha256 }
}

/// Only the app process calls this. Items use the login keychain, whose default ACL trusts just the
/// app that created them, so other processes (an agent's shell included) get a system prompt.
public enum Keychain {
    static let service = "Pushwright APNs key"

    public static func savePrivateKey(_ pem: String, profileId: UUID, label: String) throws {
        deletePrivateKey(profileId: profileId)
        var query = baseQuery(profileId)
        query[kSecAttrLabel as String] = label
        query[kSecValueData as String] = Data(pem.utf8)
        try check(SecItemAdd(query as CFDictionary, nil))
    }

    public static func privateKey(profileId: UUID) throws -> String? {
        var query = baseQuery(profileId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return (result as? Data).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Reads attributes only, so it never triggers an access prompt.
    public static func hasPrivateKey(profileId: UUID) -> Bool {
        var query = baseQuery(profileId)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public static func deletePrivateKey(profileId: UUID) {
        SecItemDelete(baseQuery(profileId) as CFDictionary)
    }

    public static func pushIdentities() -> [PushIdentity] {
        allPushIdentities().map(\.info)
    }

    static func identity(sha256: String) -> SecIdentity? {
        allPushIdentities().first { $0.info.sha256 == sha256 }?.identity
    }

    static func allPushIdentities() -> [(identity: SecIdentity, info: PushIdentity)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [AnyObject] else {
            return []
        }
        return items.compactMap { item in
            let identity = item as! SecIdentity  // kSecClassIdentity only returns identities
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                  let name = SecCertificateCopySubjectSummary(certificate) as String?, name.contains("Push Services")
            else { return nil }
            let der = SecCertificateCopyData(certificate) as Data
            let sha = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            // "Apple Development IOS Push Services: com.x" is sandbox only, "Apple Push Services: com.x" covers both.
            let environments: [PushEnvironment] = name.contains("Development") ? [.sandbox]
                : name.contains("Production") ? [.production] : [.sandbox, .production]
            let bundleId = name.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
            return (identity, PushIdentity(name: name, sha256: sha, bundleId: bundleId, environments: environments))
        }
    }

    static func baseQuery(_ profileId: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileId.uuidString,
        ]
    }

    static func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        throw ErrorInfo.config("KEYCHAIN_ERROR", "Keychain: \(message)")
    }
}
