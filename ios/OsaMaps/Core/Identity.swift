import Foundation

/// Identité locale de l'appareil (même rôle que `identity.ts`).
@MainActor
enum Identity {
    private static let d = UserDefaults.standard

    /// Identifiant stable et anonyme de cet appareil.
    static var deviceId: String {
        if let s = d.string(forKey: "identity.deviceId") { return s }
        let s = UUID().uuidString.lowercased()
        d.set(s, forKey: "identity.deviceId")
        return s
    }

    /// Code ami à 6 chiffres proposé (le serveur peut en attribuer un autre s'il est pris).
    static var friendCode: String {
        if let s = d.string(forKey: "identity.friendCode") { return s }
        let s = String(format: "%06d", Int.random(in: 0...999_999))
        d.set(s, forKey: "identity.friendCode")
        return s
    }

    static var nickname: String {
        get { d.string(forKey: "identity.nickname") ?? "" }
        set { d.set(String(newValue.prefix(24)), forKey: "identity.nickname") }
    }
}

/// Petit stockage local JSON pour les modules : `Store.load("search.favorites", default: [Place]())`.
/// Clés préfixées par l'id du module.
enum Store {
    static func load<T: Decodable>(_ key: String, default value: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: "osamaps." + key),
              let v = try? JSONDecoder().decode(T.self, from: data) else { return value }
        return v
    }

    static func save<T: Encodable>(_ key: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: "osamaps." + key) }
    }

    static func remove(_ key: String) { UserDefaults.standard.removeObject(forKey: "osamaps." + key) }
}
