import Foundation
import CoreLocation

/// Modèles du module Amis (mêmes champs que `server/features/friends.js`).
/// Le serveur parle JSON brut via socket.io : on décode à la main depuis `[String: Any]`.

/// Position partagée d'un ami (mémoire seulement côté serveur, expire après 5 min).
struct FriendsLoc: Equatable {
    var lat: Double
    var lng: Double
    var heading: Double?
    /// m/s.
    var speed: Double?
    /// Présent s'il conduit ; `to` / `eta` seulement s'il accepte de montrer sa destination.
    var drive: Drive?
    /// Horodatage serveur (ms).
    var t: Double

    struct Drive: Equatable {
        var to: String?
        /// Horodatage d'arrivée (ms).
        var eta: Double?
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    var age: TimeInterval { Date().timeIntervalSince1970 - t / 1000 }

    init?(json: Any?) {
        guard let j = json as? [String: Any], let lat = FriendsJSON.num(j["lat"]), let lng = FriendsJSON.num(j["lng"]) else { return nil }
        self.lat = lat; self.lng = lng
        heading = FriendsJSON.num(j["heading"])
        speed = FriendsJSON.num(j["speed"])
        t = FriendsJSON.num(j["t"]) ?? Date().timeIntervalSince1970 * 1000
        if let d = j["drive"] as? [String: Any] {
            drive = Drive(to: d["to"] as? String, eta: FriendsJSON.num(d["eta"]))
        }
    }
}

struct FriendsFriend: Identifiable, Equatable {
    var pid: String
    var name: String
    var code: String
    var online: Bool
    var loc: FriendsLoc?
    var id: String { pid }

    init?(json: Any?) {
        guard let j = json as? [String: Any], let pid = j["pid"] as? String else { return nil }
        self.pid = pid
        name = (j["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Sans pseudo"
        code = j["code"] as? String ?? ""
        online = j["online"] as? Bool ?? false
        loc = FriendsLoc(json: j["loc"])
    }
}

/// Demande reçue (avec pseudo) ou envoyée (code seulement).
struct FriendsRequest: Identifiable, Equatable {
    var pid: String
    var name: String?
    var code: String
    var id: String { pid }

    init?(json: Any?) {
        guard let j = json as? [String: Any], let pid = j["pid"] as? String else { return nil }
        self.pid = pid
        name = j["name"] as? String
        code = j["code"] as? String ?? ""
    }
}

struct FriendsMe: Equatable {
    var pid: String
    var code: String
    var name: String
}

/// Mon trajet partagé (lien `?suivre=JETON`).
struct FriendsSharedTrip: Equatable {
    var token: String
    var url: URL
    /// ms.
    var expiresAt: Double
    var watchers: Int
}

/// Trajet suivi (vue « suivre »), tel que renvoyé par `tripOut` côté serveur.
struct FriendsTripView: Equatable {
    var token: String
    var name: String
    var destName: String
    var dest: CLLocationCoordinate2D
    var coords: [CLLocationCoordinate2D]
    var pos: CLLocationCoordinate2D?
    var heading: Double?
    var eta: Double?
    var remaining: Double?
    var arrivedAt: Double?
    var expiresAt: Double?
    var updated: Double

    static func == (a: Self, b: Self) -> Bool {
        a.token == b.token && a.updated == b.updated && a.arrivedAt == b.arrivedAt && a.coords.count == b.coords.count
            && a.pos?.latitude == b.pos?.latitude && a.pos?.longitude == b.pos?.longitude
    }

    /// Fusionne un message (complet ou partiel : `coords` absent dans les mises à jour).
    static func merge(_ cur: FriendsTripView?, _ json: Any?) -> FriendsTripView? {
        guard let j = json as? [String: Any] else { return cur }
        let destJ = j["dest"] as? [String: Any]
        let destLat = FriendsJSON.num(destJ?["lat"]), destLng = FriendsJSON.num(destJ?["lng"])
        guard let token = j["token"] as? String ?? cur?.token,
              let dest = (destLat != nil && destLng != nil) ? CLLocationCoordinate2D(latitude: destLat!, longitude: destLng!) : cur?.dest
        else { return cur }
        var t = cur ?? FriendsTripView(token: token, name: "Ton ami", destName: "sa destination", dest: dest, coords: [],
                                       pos: nil, heading: nil, eta: nil, remaining: nil, arrivedAt: nil, expiresAt: nil, updated: 0)
        t.dest = dest
        if let n = j["name"] as? String { t.name = n }
        if let n = destJ?["name"] as? String { t.destName = n }
        if let c = j["coords"] as? [[Any]] {
            let pts = c.compactMap { p -> CLLocationCoordinate2D? in
                guard p.count == 2, let lng = FriendsJSON.num(p[0]), let lat = FriendsJSON.num(p[1]) else { return nil }
                return .init(latitude: lat, longitude: lng)
            }
            if pts.count >= 2 { t.coords = pts }
        }
        if let p = j["pos"] as? [String: Any], let lat = FriendsJSON.num(p["lat"]), let lng = FriendsJSON.num(p["lng"]) {
            t.pos = .init(latitude: lat, longitude: lng)
            t.heading = FriendsJSON.num(p["heading"])
        }
        if j.keys.contains("eta") { t.eta = FriendsJSON.num(j["eta"]) }
        if j.keys.contains("remaining") { t.remaining = FriendsJSON.num(j["remaining"]) }
        if j.keys.contains("arrivedAt") { t.arrivedAt = FriendsJSON.num(j["arrivedAt"]) }
        if let e = FriendsJSON.num(j["expiresAt"]) { t.expiresAt = e }
        t.updated = FriendsJSON.num(j["updated"]) ?? Date().timeIntervalSince1970 * 1000
        return t
    }
}

/// Réponse (ack) d'un évènement socket : `{ ok, error?, … }`.
final class FriendsReply: @unchecked Sendable {
    let json: [String: Any]
    init(_ json: [String: Any]) { self.json = json }
    var ok: Bool { json["ok"] as? Bool ?? false }
    var error: String? { json["error"] as? String }
    subscript(_ k: String) -> Any? { json[k] }
}

enum FriendsJSON {
    /// Nombre JSON (NSNumber) → Double ; nil pour null / absent / booléen.
    static func num(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }
}
