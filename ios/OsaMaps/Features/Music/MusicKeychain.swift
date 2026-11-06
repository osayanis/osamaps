import Foundation
import Security

/// Jetons Spotify dans le trousseau (jamais dans les préférences en clair).
enum MusicKeychain {
    private static let service = "fr.osalabs.osamaps.music"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load(_ account: String) -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        #if targetEnvironment(simulator)
        // build Simulateur non signée : pas d'entitlement trousseau (-34018) → repli de test, Simulateur seulement
        if status == errSecMissingEntitlement { return UserDefaults.standard.data(forKey: "osamaps.music.sim." + account) }
        #endif
        return status == errSecSuccess ? out as? Data : nil
    }

    @discardableResult
    static func save(_ account: String, _ data: Data) -> Bool {
        SecItemDelete(base(account) as CFDictionary)
        var q = base(account)
        q[kSecValueData as String] = data
        // lisible écran verrouillé après le premier déverrouillage (la conduite continue en arrière-plan)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        #if targetEnvironment(simulator)
        if status == errSecMissingEntitlement {
            UserDefaults.standard.set(data, forKey: "osamaps.music.sim." + account)
            return true
        }
        #endif
        return status == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
        #if targetEnvironment(simulator)
        UserDefaults.standard.removeObject(forKey: "osamaps.music.sim." + account)
        #endif
    }
}
