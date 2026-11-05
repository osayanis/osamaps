import Foundation
import CoreLocation

// Contrat serveur : server/features/safety.js
//   GET  safety/zones?bbox=o,s,e,n   disques de zones de danger (JAMAIS l'emplacement d'un radar : décret 2012-3)
//   GET  safety/zfe                  périmètres ZFE en vigueur (GeoJSON MultiPolygon)
//   POST safety/pois {tiles:[z/x/y]} passages à niveau (lc) et écoles (sc), tuiles zoom 12
//   GET  safety/status               état des jeux de données

/// Un disque de zone de danger tel qu'envoyé par le serveur (centre décalé : jamais la position de l'appareil).
struct SafetyZone: Codable, Hashable, Sendable {
    var id: String
    var lng: Double
    var lat: Double
    /// Rayon (m) = longueur réglementaire de la zone / 2.
    var r: Double
    /// "city" (300 m), "road" (2 km), "motorway" (4 km).
    var kind: String

    var center: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

struct SafetySource: Codable, Sendable {
    var name: String
    var page: String
    var updated: String?
}

struct SafetyZonesResponse: Codable, Sendable {
    var available: Bool
    var error: String?
    var source: SafetySource?
    var zones: [SafetyZone]
}

struct SafetyZfeProps: Codable, Hashable, Sendable {
    var id: String
    var name: String
    /// Première vignette interdite aux voitures particulières (nil = pas de règle voiture).
    var vp: String?
    var hours: String?
    var from: String?
    var to: String?
    var url: String?
}

struct SafetyZfeFeature: Codable, Sendable {
    struct Geometry: Codable, Sendable {
        var type: String
        /// MultiPolygon : polygones → anneaux (le premier = contour, les suivants = trous) → [lng, lat].
        var coordinates: [[[[Double]]]]
    }
    var geometry: Geometry
    var properties: SafetyZfeProps
}

struct SafetyZfeResponse: Codable, Sendable {
    var available: Bool
    var error: String?
    var source: SafetySource?
    var features: [SafetyZfeFeature]
}

struct SafetyPoiTile: Codable, Sendable {
    /// Passages à niveau [lng, lat].
    var lc: [[Double]]
    /// Écoles [lng, lat].
    var sc: [[Double]]
}

private struct SafetyPoisResponse: Codable, Sendable {
    var tiles: [String: SafetyPoiTile]
    var pending: [String]?
    var retryAfter: Double?
}

/// Appels serveur avec cache (comme `data.ts`) : pas de rafales, les réponses « indisponible » ne sont pas gardées.
@MainActor
enum SafetyData {
    private static var zoneCache: [String: Task<SafetyZonesResponse, Error>] = [:]
    private static var zoneOrder: [String] = []
    private static var zfeTask: Task<SafetyZfeResponse, Error>?
    private static var poiTiles: [String: SafetyPoiTile] = [:]
    private static var poiRetryAt = Date.distantPast
    private static var poiBusy = false
    private static let poiSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.httpAdditionalHeaders = ["User-Agent": "OsaMaps-iOS/0.1"]
        return URLSession(configuration: c)
    }()

    /// Toutes les zones de danger de France (≈ 3 300 disques, la liste change ~1×/an) :
    /// gardées sur le téléphone et redemandées au plus une fois par jour.
    private struct SavedZones: Codable { var at: Date = .distantPast; var zones: [SafetyZone] = [] }
    private static var allZonesTask: Task<[SafetyZone], Never>?
    static func allZones() async -> [SafetyZone] {
        if let t = allZonesTask { return await t.value }
        let t = Task<[SafetyZone], Never> {
            let saved = Store.load("safety.allZones", default: SavedZones())
            if !saved.zones.isEmpty, Date().timeIntervalSince(saved.at) < 86_400 { return saved.zones }
            if let r = try? await API.get("safety/zones/all", as: SafetyZonesResponse.self, timeout: 40), r.available, !r.zones.isEmpty {
                Store.save("safety.allZones", SavedZones(at: Date(), zones: r.zones))
                return r.zones
            }
            return saved.zones // hors ligne : la dernière liste connue
        }
        allZonesTask = t
        let zones = await t.value
        if zones.isEmpty { allZonesTask = nil } // on réessaiera
        return zones
    }

    /// bbox = (ouest, sud, est, nord), au plus 14° de côté (le serveur refuse au-delà).
    static func zones(_ b: (w: Double, s: Double, e: Double, n: Double)) async throws -> SafetyZonesResponse {
        let key = [b.w, b.s, b.e, b.n].map { String(format: "%.2f", $0) }.joined(separator: ",")
        let task: Task<SafetyZonesResponse, Error>
        if let t = zoneCache[key] { task = t } else {
            task = Task { try await API.get("safety/zones?bbox=\(key)", as: SafetyZonesResponse.self) }
            zoneCache[key] = task
            zoneOrder.append(key)
            if zoneOrder.count > 40 { zoneCache[zoneOrder.removeFirst()] = nil }
        }
        do {
            let r = try await task.value
            if !r.available { zoneCache[key] = nil }
            return r
        } catch {
            zoneCache[key] = nil
            throw error
        }
    }

    static func zfe() async throws -> SafetyZfeResponse {
        let task = zfeTask ?? Task { try await API.get("safety/zfe", as: SafetyZfeResponse.self) }
        zfeTask = task
        do {
            let r = try await task.value
            if !r.available { zfeTask = nil }
            return r
        } catch {
            zfeTask = nil
            throw error
        }
    }

    /// Demande au serveur les passages à niveau / écoles des tuiles manquantes (cache local + serveur).
    static func poiTiles(_ keys: [String]) async -> [String: SafetyPoiTile] {
        let missing = Array(keys.filter { poiTiles[$0] == nil }.prefix(40))
        if !missing.isEmpty, !poiBusy, Date() >= poiRetryAt {
            poiBusy = true
            defer { poiBusy = false }
            do {
                // le serveur peut attendre Overpass jusqu'à 45 s : délai plus long que celui d'`API` (20 s)
                var req = URLRequest(url: URL(string: "safety/pois", relativeTo: API.base)!.absoluteURL)
                req.httpMethod = "POST"
                req.timeoutInterval = 60
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONEncoder().encode(["tiles": missing])
                let (data, resp) = try await poiSession.data(for: req)
                guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                    throw API.HTTPError(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, message: "pois")
                }
                let r = try JSONDecoder().decode(SafetyPoisResponse.self, from: data)
                for (k, v) in r.tiles { poiTiles[k] = v }
                if let s = r.retryAfter, s > 0 { poiRetryAt = Date().addingTimeInterval(s) }
            } catch {
                poiRetryAt = Date().addingTimeInterval(60)
            }
        }
        var out: [String: SafetyPoiTile] = [:]
        for k in keys { if let t = poiTiles[k] { out[k] = t } }
        return out
    }
}

/// Utilitaires géographiques propres au module.
enum SafetyGeo {
    static let poiZoom = 12
    static let mPerDeg = 111_320.0

    /// Clé de tuile « z/x/y » (Web Mercator) contenant le point.
    static func tileKey(_ c: CLLocationCoordinate2D, z: Int = poiZoom) -> String {
        let n = pow(2.0, Double(z))
        let x = Int(floor((c.longitude + 180) / 360 * n))
        let r = c.latitude * .pi / 180
        let y = Int(floor((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * n))
        return "\(z)/\(x)/\(y)"
    }

    private static func inRing(_ p: CLLocationCoordinate2D, _ ring: [[Double]]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let xi = ring[i][0], yi = ring[i][1], xj = ring[j][0], yj = ring[j][1]
            if (yi > p.latitude) != (yj > p.latitude),
               p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Point dans un MultiPolygon (anneaux intérieurs = trous).
    static func inMultiPolygon(_ p: CLLocationCoordinate2D, _ mp: [[[[Double]]]]) -> Bool {
        mp.contains { poly in
            guard let outer = poly.first, inRing(p, outer) else { return false }
            return !poly.dropFirst().contains { inRing(p, $0) }
        }
    }

    /// « Mo-Fr 08:00-20:00; PH off » → « lun-ven 08:00-20:00, sauf jours fériés ».
    static func hoursFr(_ h: String?) -> String? {
        guard let h else { return nil }
        var s = h.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+:\s+"#, with: " ", options: .regularExpression)
        if s == "24/7" { return "tous les jours, 24 h/24" }
        if s.range(of: #"^Mo-Su 00:00-(00:00|24:00|23:59)(; PH off)?$"#, options: .regularExpression) != nil {
            return s.hasSuffix("PH off") ? "tous les jours, sauf jours fériés" : "tous les jours, 24 h/24"
        }
        s = s.replacingOccurrences(of: #"\bPH off\b"#, with: "sauf jours fériés", options: .regularExpression)
            .replacingOccurrences(of: #"\bMay 1 off\b"#, with: "sauf 1er mai", options: .regularExpression)
        for (en, fr) in [("Mo", "lun"), ("Tu", "mar"), ("We", "mer"), ("Th", "jeu"), ("Fr", "ven"), ("Sa", "sam"), ("Su", "dim")] {
            s = s.replacingOccurrences(of: "\\b\(en)\\b", with: fr, options: .regularExpression)
        }
        return s.replacingOccurrences(of: #";\s*"#, with: ", ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
