import Foundation
import CoreLocation

// Contrat serveur : server/features/safety.js
//   GET  safety/segments?tiles=8/x/y,…  zones de danger par tuiles (tronçons de route ; JAMAIS l'emplacement d'un radar)
//   GET  safety/zfe                  périmètres ZFE en vigueur (GeoJSON MultiPolygon)
//   POST safety/pois {tiles:[z/x/y]} passages à niveau (lc) et écoles (sc), tuiles zoom 12
//   GET  safety/status               état des jeux de données

/// Une zone de danger telle qu'envoyée par le serveur (format compact).
struct SafetyZoneDTO: Codable, Sendable {
    /// Identifiant opaque (pas le numéro du radar).
    var i: String
    /// "city" (300 m), "road" (2 km), "motorway" (4 km).
    var k: String
    /// Milieu du tronçon [lng, lat] (emplacement de l'icône), ou centre du disque de repli.
    var m: [Double]
    /// Tronçon : une polyline encodée (précision 5) par chaussée.
    var p: [String]?
    /// 1 : polylines dans le sens de circulation ; 0 : route à double sens.
    var o: Int?
    /// Repli (aucune route trouvée, ou tronçon pas encore calculé) : disque de rayon r (m).
    var r: Double?
}

/// Une zone de danger décodée : un TRONÇON de route (une ligne par chaussée) ou, en repli, un disque.
/// L'appareil est quelque part entre 15 et 85 % du tronçon : le serveur ne dit jamais où.
struct SafetyZone: Hashable, Sendable {
    var id: String
    var kind: String
    /// Milieu du tronçon (l'icône) ou centre du disque.
    var mid: CLLocationCoordinate2D
    var lines: [[CLLocationCoordinate2D]]
    var oneway: Bool
    /// Disque de repli (m), nil pour un tronçon.
    var radius: Double?
    /// Longueur (m) : celle du tronçon, ou le diamètre du disque.
    var length: Double

    init(_ d: SafetyZoneDTO) {
        id = d.i
        kind = d.k
        mid = .init(latitude: d.m.count > 1 ? d.m[1] : 0, longitude: d.m.first ?? 0)
        lines = (d.p ?? []).map { Geo.decodePolyline($0, precision: 1e5) }.filter { $0.count >= 2 }
        oneway = d.o == 1
        radius = lines.isEmpty ? (d.r ?? 150) : nil
        if let first = lines.first { length = Geo.cumulative(first).last ?? 0 } else { length = 2 * (radius ?? 150) }
    }

    static func == (a: SafetyZone, b: SafetyZone) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct SafetySegmentsResponse: Codable, Sendable {
    var available: Bool
    var error: String?
    var complete: Bool?
    var zoom: Int
    var tiles: [String: [SafetyZoneDTO]]
}

struct SafetySource: Codable, Sendable {
    var name: String
    var page: String
    var updated: String?
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

    // MARK: Zones de danger (tuiles zoom 8, gardées sur le téléphone)

    private struct SavedTile: Codable { var at: Date; var complete: Bool; var zones: [SafetyZoneDTO] }
    private static var savedTiles: [String: SavedTile]?
    private static var decoded: [String: [SafetyZone]] = [:]
    private static var tileTasks: [String: Task<Void, Never>] = [:]
    private static var saveScheduled = false
    /// Dernier état connu des données serveur (nil = jamais joint).
    private(set) static var zonesAvailable: Bool?
    private(set) static var zonesError: String?

    private static var tiles: [String: SavedTile] {
        get {
            if let t = savedTiles { return t }
            let t = Store.load("safety.segTiles", default: [String: SavedTile]())
            savedTiles = t
            return t
        }
        set { savedTiles = newValue }
    }

    /// Zones déjà connues d'une tuile (sans réseau).
    static func cachedZones(_ key: String) -> [SafetyZone]? {
        if let z = decoded[key] { return z }
        guard let t = tiles[key] else { return nil }
        let z = t.zones.map(SafetyZone.init)
        decoded[key] = z
        return z
    }

    /// Zones des tuiles demandées (cache local, puis serveur pour les tuiles manquantes ou périmées :
    /// une journée, 10 min tant que le serveur n'a pas fini de calculer les tronçons). Hors ligne : la
    /// dernière version connue.
    static func zoneTiles(_ keys: [String]) async -> [String: [SafetyZone]] {
        let now = Date()
        let stale = keys.filter { k in
            guard let t = tiles[k] else { return true }
            return now.timeIntervalSince(t.at) > (t.complete ? 86_400 : 600)
        }
        let todo = stale.filter { tileTasks[$0] == nil }
        var waits = stale.compactMap { tileTasks[$0] }
        var start = 0
        while start < todo.count {
            let chunk = Array(todo[start..<min(todo.count, start + 32)])
            start += 32
            let task = Task<Void, Never> { await fetchTiles(chunk) }
            for k in chunk { tileTasks[k] = task }
            waits.append(task)
        }
        for w in waits { await w.value }
        var out: [String: [SafetyZone]] = [:]
        for k in keys { if let z = cachedZones(k) { out[k] = z } }
        return out
    }

    private static func fetchTiles(_ keys: [String]) async {
        defer { for k in keys { tileTasks[k] = nil } }
        do {
            let r = try await API.get("safety/segments?tiles=\(keys.joined(separator: ","))", as: SafetySegmentsResponse.self, timeout: 30)
            zonesAvailable = r.available
            zonesError = r.available ? nil : (r.error ?? "indisponible")
            guard r.available else { return }
            let complete = r.complete ?? true
            for k in keys {
                tiles[k] = SavedTile(at: Date(), complete: complete, zones: r.tiles[k] ?? [])
                decoded[k] = nil
            }
            scheduleSave()
        } catch {
            if zonesAvailable == nil { zonesError = error.localizedDescription }
        }
    }

    private static func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(5))
            saveScheduled = false
            if let t = savedTiles { Store.save("safety.segTiles", t) }
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

    static let zoneZoom = 8

    /// Tuiles (zoom 8) qui couvrent un rectangle (ouest, sud, est, nord), au plus `limit`.
    static func zoneTiles(w: Double, s: Double, e: Double, n: Double, limit: Int = 64) -> [String] {
        let z = zoneZoom, k = Double(1 << z)
        func tx(_ lng: Double) -> Int { max(0, min(Int(k) - 1, Int(floor((lng + 180) / 360 * k)))) }
        func ty(_ lat: Double) -> Int {
            let r = max(-85, min(85, lat)) * .pi / 180
            return max(0, min(Int(k) - 1, Int(floor((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * k))))
        }
        var out: [String] = []
        for x in tx(w)...tx(e) { for y in ty(n)...ty(s) { out.append("\(z)/\(x)/\(y)"); if out.count >= limit { return out } } }
        return out
    }

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
