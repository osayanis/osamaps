import Foundation
import Security

/// Le secret d'appareil (jamais montré, jamais envoyé ailleurs qu'au `friends:hello`) vit dans le trousseau.
/// Avec le deviceId, il prouve au serveur que c'est bien cet appareil : personne ne peut se faire passer pour lui.
enum FriendsKeychain {
    private static let service = "fr.osalabs.osamaps.friends"
    private static let account = "device-secret"
    /// Format accepté par le serveur : 32 à 128 caractères [A-Za-z0-9_-].
    private static func valid(_ s: String) -> Bool {
        (32...128).contains(s.count) && s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
    }

    /// Le secret, créé au premier appel (64 caractères hexadécimaux, aléatoires).
    /// nil si le trousseau est momentanément illisible (appareil pas encore déverrouillé…) : surtout ne PAS
    /// en recréer un dans ce cas, l'ancien serait écrasé et l'identité perdue. On réessaiera à la reconnexion.
    static func secret() -> String? {
        #if targetEnvironment(simulator)
        // build Simulateur non signée : pas d'entitlement trousseau (-34018). Repli de test, Simulateur seulement.
        if lastStatus == errSecMissingEntitlement || probeMissingEntitlement() { return simulatorSecret() }
        #endif
        switch read() {
        case .found(let s) where valid(s): return s
        case .failed: return nil
        case .found, .missing:
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
            let s = bytes.map { String(format: "%02x", $0) }.joined()
            return write(s) ? s : nil
        }
    }

    /// « Supprimer mes données » : on oublie le secret (un nouveau sera créé).
    static func reset() {
        SecItemDelete(base as CFDictionary)
        #if targetEnvironment(simulator)
        UserDefaults.standard.removeObject(forKey: "osamaps.friends.simulatorSecret")
        #endif
    }

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    #if targetEnvironment(simulator)
    private static var lastStatus: OSStatus = errSecSuccess
    private static func probeMissingEntitlement() -> Bool {
        var q = base
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        lastStatus = SecItemCopyMatching(q as CFDictionary, nil)
        return lastStatus == errSecMissingEntitlement
    }
    private static func simulatorSecret() -> String {
        let key = "osamaps.friends.simulatorSecret"
        if let s = UserDefaults.standard.string(forKey: key), valid(s) { return s }
        let s = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(s, forKey: key)
        return s
    }
    #endif

    private enum ReadResult { case found(String), missing, failed }

    private static func read() -> ReadResult {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = out as? Data else {
            print("OsaMaps friends: trousseau illisible (\(status))")
            return .failed
        }
        return .found(String(decoding: data, as: UTF8.self))
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
