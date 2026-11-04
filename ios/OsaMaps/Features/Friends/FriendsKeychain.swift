import Foundation
import Security

/// Le secret d'appareil (jamais montré, jamais envoyé ailleurs qu'au `friends:hello`) vit dans le trousseau.
/// Avec le deviceId, il prouve au serveur que c'est bien cet appareil : personne ne peut se faire passer pour lui.
enum FriendsKeychain {
    private static let service = "fr.osalabs.osamaps.friends"
    private static let account = "device-secret"
    private static let pattern = /^[A-Za-z0-9_-]{32,128}$/

    /// Le secret, créé au premier appel (64 caractères hexadécimaux, aléatoires).
    static func secret() -> String {
        if let s = read(), s.wholeMatch(of: pattern) != nil { return s }
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        let s = bytes.map { String(format: "%02x", $0) }.joined()
        write(s)
        return s
    }

    /// « Supprimer mes données » : on oublie le secret (un nouveau sera créé).
    static func reset() {
        SecItemDelete(base as CFDictionary)
    }

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func write(_ s: String) -> Bool {
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = Data(s.utf8)
        // lisible après le premier déverrouillage (la position peut partir écran verrouillé), jamais sauvegardé ailleurs
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess { print("OsaMaps friends: trousseau indisponible (\(status))") }
        return status == errSecSuccess
    }
}
