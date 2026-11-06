import Foundation
import CoreLocation

/// Calcul d'itinéraire avec Valhalla (port de `web/src/features/routing/engine.ts`).
/// D'abord le proxy du serveur OsaMaps (`POST routing/route`, cache + file d'attente) ;
/// s'il est absent ou en panne, Valhalla public en direct pour que l'app reste utilisable.

struct RoutingWaypoint: Sendable {
    var coordinate: CLLocationCoordinate2D
    var name: String?
}

/// Heure choisie : type 1 = partir à, type 2 = arriver à ; heure locale « 2026-11-05T08:00 ».
struct RoutingDepart: Equatable, Codable, Sendable {
    var type: Int
    var value: String
}

struct RoutingOptions: Sendable {
    var avoidTolls = false
    var avoidHighways = false
    var avoidFerries = false
    /// 0 à 2 ; ignoré par Valhalla avec des étapes ou une heure imposée.
    var alternates = 2
    /// Cap au départ (évite les demi-tours absurdes pendant un recalcul).
    var heading: Double?
    var depart: RoutingDepart?
    /// Véhicule (costing Valhalla « truck » avec ses dimensions pour les camions).
    var vehicle = Vehicle()
}

/// Ce que le module garde en plus de la `Route` du Core, par id d'itinéraire.
struct RoutingMeta: Equatable, Sendable {
    /// Index dans `route.coords` de chaque étape intermédiaire (même ordre que les étapes).
    var stopShapeIndex: [Int] = []
    /// Heures locales renvoyées par Valhalla quand une heure a été demandée.
    var departAt: String?
    var arriveAt: String?
}

struct RoutingComputed: Sendable {
    var route: Route
    var meta: RoutingMeta
}

/// Erreur « pas d'itinéraire » (inutile de réessayer) vs panne réseau (réessayer).
struct RoutingError: LocalizedError, Sendable {
    var message: String
    var retryable: Bool
    var errorDescription: String? { message }
}

// MARK: - Requête (Encodable, même forme que la version web)

struct RoutingRequest: Encodable, Sendable {
    struct Location: Encodable, Sendable {
        var lat: Double
        var lon: Double
        var type = "break"
        var heading: Int?
        var heading_tolerance: Int?
    }
    /// Options d'un costing (auto ou truck) : seuls les champs renseignés sont envoyés.
    struct Opts: Encodable, Sendable {
        var use_tolls: Double?
        var use_highways: Double?
        var use_ferry: Double?
        var height: Double?
        var width: Double?
        var length: Double?
        var weight: Double?
        var axle_load: Double?
        var hazmat: Bool?
        var top_speed: Int?
    }
    struct Costing: Encodable, Sendable { var auto: Opts?; var truck: Opts? }
    struct Directions: Encodable, Sendable { var units = "kilometers" }

    var locations: [Location]
    var costing = "auto"
    var costing_options: Costing
    var language = "fr-FR"
    var directions_options = Directions()
    var alternates: Int
    var date_time: RoutingDepart?

    init(points: [RoutingWaypoint], options o: RoutingOptions) {
        locations = points.enumerated().map { i, p in
            var l = Location(lat: p.coordinate.latitude, lon: p.coordinate.longitude)
            if i == 0, let h = o.heading, h.isFinite {
                l.heading = Int(((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360).rounded()) % 360
                l.heading_tolerance = 45
            }
            return l
        }
        var opts = Opts(use_tolls: o.avoidTolls ? 0 : nil, use_highways: o.avoidHighways ? 0 : nil,
                        use_ferry: o.avoidFerries ? 0 : nil)
        let v = o.vehicle
        if v.isTruck {
            costing = "truck"
            opts.height = v.height; opts.width = v.width; opts.length = v.length
            opts.weight = v.weight; opts.axle_load = v.axleLoad
            opts.hazmat = v.hazmat ? true : nil
            opts.top_speed = RoutingTruck.topSpeed(v)
            costing_options = Costing(truck: opts)
        } else {
            costing_options = Costing(auto: opts)
        }
        let multi = points.count > 2
        alternates = multi || o.depart != nil ? 0 : max(0, min(2, o.alternates))
        date_time = o.depart
    }
}

// MARK: - Réponse Valhalla (décodage tolérant)

struct RoutingValhallaResponse: Decodable, Sendable {
    struct Alternate: Decodable, Sendable { var trip: Trip }
    var trip: Trip
    var alternates: [Alternate]?

    struct Trip: Decodable, Sendable {
        var legs: [Leg]
        var summary: Summary
        var locations: [Loc]?
        var units: String?
    }
    struct Leg: Decodable, Sendable {
        var shape: String
        var maneuvers: [ValhallaManeuver]
    }
    struct Summary: Decodable, Sendable {
        var length: Double
        var time: Double
        var has_toll: Bool?
        var has_highway: Bool?
        var has_ferry: Bool?
    }
    struct Loc: Decodable, Sendable { var date_time: String? }

    struct ValhallaManeuver: Decodable, Sendable {
        var type: Int
        var instruction: String
        var verbal_pre_transition_instruction: String?
        var street_names: [String]?
        var begin_street_names: [String]?
        var begin_shape_index: Int
        var length: Double
        var time: Double
        var roundabout_exit_count: Int?
        var lanes: [ValhallaLane]?

        private enum K: String, CodingKey {
            case type, instruction, verbal_pre_transition_instruction, street_names, begin_street_names
            case begin_shape_index, length, time, roundabout_exit_count, lanes
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            type = try c.decode(Int.self, forKey: .type)
            instruction = (try? c.decode(String.self, forKey: .instruction)) ?? ""
            verbal_pre_transition_instruction = try? c.decode(String.self, forKey: .verbal_pre_transition_instruction)
            street_names = try? c.decode([String].self, forKey: .street_names)
            begin_street_names = try? c.decode([String].self, forKey: .begin_street_names)
            begin_shape_index = (try? c.decode(Int.self, forKey: .begin_shape_index)) ?? 0
            length = (try? c.decode(Double.self, forKey: .length)) ?? 0
            time = (try? c.decode(Double.self, forKey: .time)) ?? 0
            roundabout_exit_count = try? c.decode(Int.self, forKey: .roundabout_exit_count)
            // les voies ne doivent jamais faire échouer le décodage
            lanes = try? c.decode([ValhallaLane].self, forKey: .lanes)
        }
    }

    /// Voie : `directions` = masque de bits (Valhalla) ou liste de noms ; `valid`/`active` booléen ou nombre.
    struct ValhallaLane: Decodable, Sendable {
        var directions: [String]
        var valid: Bool

        private enum K: String, CodingKey { case directions, valid, active }
        private static let bits: [(Int, String)] = [
            (1, "straight"), (2, "slight_right"), (4, "right"), (8, "sharp_right"),
            (16, "uturn"), (32, "sharp_left"), (64, "left"), (128, "slight_left"),
        ]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            if let list = try? c.decode([String].self, forKey: .directions) {
                directions = list
            } else if let mask = try? c.decode(Int.self, forKey: .directions) {
                directions = Self.bits.filter { mask & $0.0 != 0 }.map(\.1)
            } else {
                directions = []
            }
            if directions.isEmpty { directions = ["straight"] }
            func flag(_ k: K) -> Bool? {
                if let b = try? c.decode(Bool.self, forKey: k) { return b }
                if let n = try? c.decode(Int.self, forKey: k) { return n != 0 }
                if let s = try? c.decode(String.self, forKey: k) { return !s.isEmpty }
                return nil
            }
            valid = flag(.valid) ?? flag(.active) ?? false
        }
    }
}

/// Réponse du proxy `routing/trace` (compacte) ou de Valhalla direct (complète).
private struct RoutingTraceResponse: Decodable {
    struct Edge: Decodable {
        var b: Int
        var e: Int
        var kmh: Int?
        /// Classe de route Valhalla (motorway, trunk, primary…) et limite poids lourds explicite (maxspeed:hgv).
        var rc: String?
        var hgv: Int?
        private enum K: String, CodingKey { case b, e, kmh, rc, hgv, begin_shape_index, end_shape_index, speed_limit, road_class, truck_speed }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            func speed(_ k: K) -> Int? {
                let v = (try? c.decode(Double.self, forKey: k)) ?? 0
                return v > 0 && v < 200 ? Int(v.rounded()) : nil
            }
            if let b = try? c.decode(Int.self, forKey: .b) {
                self.b = b
                e = (try? c.decode(Int.self, forKey: .e)) ?? b
                kmh = try? c.decode(Int.self, forKey: .kmh)
                rc = try? c.decode(String.self, forKey: .rc)
                hgv = speed(.hgv)
            } else {
                b = (try? c.decode(Int.self, forKey: .begin_shape_index)) ?? 0
                e = (try? c.decode(Int.self, forKey: .end_shape_index)) ?? b
                kmh = speed(.speed_limit)
                rc = try? c.decode(String.self, forKey: .road_class)
                hgv = speed(.truck_speed)
            }
        }
    }
    var edges: [Edge]?
}

private struct RoutingTraceProxyBody: Encodable { var encoded_polyline: String }
private struct RoutingTraceDirectBody: Encodable {
    struct Filters: Encodable {
        var attributes = ["edge.speed_limit", "edge.truck_speed", "edge.road_class", "edge.begin_shape_index", "edge.end_shape_index"]
        var action = "include"
    }
    var encoded_polyline: String
    var shape_match = "edge_walk"
    var costing = "auto"
    var filters = Filters()
}

// MARK: - Moteur

@MainActor
enum RoutingEngine {
    private static var memo: [String: (at: Date, data: RoutingValhallaResponse)] = [:]
    private static var memoOrder: [String] = []
    private static let memoTTL: TimeInterval = 90
    /// Clés triées : la même requête donne le même texte (mémo).
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    /// Calcule l'itinéraire (et ses alternatives) entre `points` (départ, étapes…, arrivée).
    static func compute(_ points: [RoutingWaypoint], options: RoutingOptions) async throws -> [RoutingComputed] {
        let req = RoutingRequest(points: points, options: options)
        let body = try encoder.encode(req)
        let key = String(decoding: body, as: UTF8.self)
        let data: RoutingValhallaResponse
        if let hit = memo[key], Date().timeIntervalSince(hit.at) < memoTTL {
            data = hit.data
        } else {
            data = try await post("route", proxyBody: body, directPath: "route", directBody: body, as: RoutingValhallaResponse.self)
            guard !data.trip.legs.isEmpty else { throw RoutingError(message: "Aucun itinéraire trouvé.", retryable: false) }
            memo[key] = (Date(), data)
            memoOrder.removeAll { $0 == key }
            memoOrder.append(key)
            if memoOrder.count > 30 { memo[memoOrder.removeFirst()] = nil }
        }
        let names = points.dropFirst().dropLast().map { $0.name ?? "votre étape" }
        let trips = [data.trip] + (data.alternates ?? []).map(\.trip)
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        return trips.enumerated().map { i, t in convert(t, id: "route-\(stamp)-\(i)", stopNames: Array(names)) }
    }

    /// 1) le proxy OsaMaps ; 2) Valhalla en direct.
    private static func post<T: Decodable>(_ endpoint: String, proxyBody: Data, directPath: String, directBody: Data, as: T.Type) async throws -> T {
        do {
            var r = URLRequest(url: URL(string: "routing/\(endpoint)", relativeTo: API.base)!.absoluteURL)
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = proxyBody
            let (data, resp) = try await API.session.data(for: r)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return try API.decoder.decode(T.self, from: data) }
            // 422 = Valhalla a répondu « aucun itinéraire » : inutile d'insister ailleurs
            if status == 422 { throw RoutingError(message: cleanMessage(String(decoding: data, as: UTF8.self)), retryable: false) }
        } catch let e as RoutingError {
            throw e
        } catch {
            if Task.isCancelled { throw CancellationError() }
        }
        try Task.checkCancellation()
        var r = URLRequest(url: External.valhalla.appendingPathComponent(directPath))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = directBody
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await API.session.data(for: r)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw RoutingError(message: "Pas de connexion au service d'itinéraire.", retryable: true)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status), let v = try? API.decoder.decode(T.self, from: data) { return v }
        if status == 400 { throw RoutingError(message: cleanMessage(String(decoding: data, as: UTF8.self)), retryable: false) }
        throw RoutingError(message: "Le service d'itinéraire ne répond pas.", retryable: true)
    }

    static func cleanMessage(_ raw: String) -> String {
        let s = raw.lowercased()
        if ["no suitable edges", "no path", "no route", "cannot reach", "no data"].contains(where: s.contains) {
            return "Aucun itinéraire routier trouvé vers ce lieu."
        }
        if s.contains("exceeds the max") || s.contains("distance") { return "Ce trajet est trop long pour être calculé." }
        return "Aucun itinéraire trouvé."
    }

    // MARK: Conversion Valhalla → Route

    static func convert(_ trip: RoutingValhallaResponse.Trip, id: String, stopNames: [String]) -> RoutingComputed {
        var coords: [Coord] = []
        var maneuvers: [Maneuver] = []
        var stopShapeIndex: [Int] = []
        let kmFactor = trip.units == "miles" ? 1609.344 : 1000
        let last = trip.legs.count - 1

        for (li, leg) in trip.legs.enumerated() {
            let shape = Geo.decodePolyline(leg.shape, precision: 1e6).map(Coord.init)
            // chaque étape recommence au point où la précédente s'arrête : on fusionne sans doublon
            let offset = li == 0 ? 0 : max(0, coords.count - 1)
            coords.append(contentsOf: li == 0 ? shape : Array(shape.dropFirst()))
            for (mi, m) in leg.maneuvers.enumerated() {
                let street = (m.street_names ?? m.begin_street_names ?? []).first
                var man = Maneuver(
                    instruction: m.instruction,
                    verbal: m.verbal_pre_transition_instruction?.isEmpty == false ? m.verbal_pre_transition_instruction : m.instruction,
                    type: m.type,
                    typeName: nil,
                    shapeIndex: m.begin_shape_index + offset,
                    length: (m.length * kmFactor).rounded(),
                    time: m.time.rounded(),
                    street: street?.isEmpty == false ? street : nil,
                    roundaboutExit: (m.roundabout_exit_count ?? 0) > 0 ? m.roundabout_exit_count : nil,
                    lanes: m.lanes.flatMap { $0.isEmpty ? nil : $0.map { Maneuver.Lane(directions: $0.directions, valid: $0.valid) } }
                )
                if mi == leg.maneuvers.count - 1 && li < last {
                    // arrivée à une étape (pas à la destination finale) : type à part pour le guidage
                    let name = li < stopNames.count ? stopNames[li] : "votre étape"
                    man.typeName = "waypoint"
                    man.instruction = "Étape atteinte : \(name)"
                    man.verbal = "Vous êtes arrivé à votre étape, \(name)."
                    stopShapeIndex.append(man.shapeIndex)
                }
                maneuvers.append(man)
            }
        }

        let s = trip.summary
        let locs = trip.locations ?? []
        let route = Route(id: id, coords: coords, distance: (s.length * kmFactor).rounded(), duration: s.time.rounded(),
                          maneuvers: maneuvers, speedLimits: nil, summary: summarize(maneuvers),
                          hasToll: s.has_toll ?? false, hasHighway: s.has_highway ?? false, hasFerry: s.has_ferry ?? false)
        return RoutingComputed(route: route, meta: RoutingMeta(stopShapeIndex: stopShapeIndex,
                                                               departAt: locs.first?.date_time, arriveAt: locs.last?.date_time))
    }

    /// « par D 2009 et N 7 » : les deux routes les plus empruntées (numéros de route préférés).
    static func summarize(_ maneuvers: [Maneuver]) -> String? {
        var byName: [String: Double] = [:]
        var order: [String] = []
        for m in maneuvers {
            guard let s = m.street else { continue }
            if byName[s] == nil { order.append(s) }
            byName[s, default: 0] += m.length
        }
        let ref = try? NSRegularExpression(pattern: "^(A|N|D|E|M|RN|RD)\\s?\\d+")
        let ranked = order
            .map { n -> (String, Double) in
                let l = byName[n] ?? 0
                let isRef = ref?.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil
                return (n, isRef ? l * 1.5 : l)
            }
            .sorted { $0.1 > $1.1 }
            .filter { $0.1 > 800 }
            .prefix(2)
            .map(\.0)
        return ranked.isEmpty ? nil : "par " + ranked.joined(separator: " et ")
    }

    // MARK: Limites de vitesse (tâche de fond)

    /// Encode une polyligne (précision 6) — l'inverse de `Geo.decodePolyline`.
    static func encodePolyline(_ coords: [Coord], precision: Double = 1e6) -> String {
        var out = ""
        var pLat = 0, pLng = 0
        func enc(_ v: Int) {
            var s = v < 0 ? ~(v << 1) : v << 1
            while s >= 0x20 {
                out.unicodeScalars.append(Unicode.Scalar(UInt8((0x20 | (s & 0x1f)) + 63)))
                s >>= 5
            }
            out.unicodeScalars.append(Unicode.Scalar(UInt8(s + 63)))
        }
        for c in coords {
            let la = Int((c.lat * precision).rounded()), ln = Int((c.lng * precision).rounded())
            enc(la - pLat); enc(ln - pLng)
            pLat = la; pLng = ln
        }
        return out
    }

    /// Limites de vitesse le long du tracé (/trace_attributes, edge_walk), par morceaux d'environ 90 km.
    /// Renvoie des plages compactes triées par index. Camions : limite poids lourds (voir `RoutingTruck`).
    static func speedLimits(_ coords: [Coord], vehicle: Vehicle = Vehicle()) async throws -> [Route.SpeedLimit] {
        let cum = Geo.cumulative(coords.map(\.coordinate))
        let chunkM = 90_000.0, chunkPts = 6000, maxChunks = 12
        var chunks: [(Int, Int)] = []
        var start = 0
        while start < coords.count - 1 && chunks.count < maxChunks {
            var end = start + 1
            while end < coords.count - 1 && cum[end] - cum[start] < chunkM && end - start < chunkPts { end += 1 }
            chunks.append((start, end))
            start = end
        }
        var ranges: [Route.SpeedLimit] = []
        var failed = 0
        for (a, b) in chunks {
            try Task.checkCancellation()
            let slice = Array(coords[a...b])
            guard slice.count >= 2, cum[b] - cum[a] >= 1 else { continue }
            let poly = encodePolyline(slice)
            let res: RoutingTraceResponse
            do {
                res = try await post("trace",
                                     proxyBody: try encoder.encode(RoutingTraceProxyBody(encoded_polyline: poly)),
                                     directPath: "trace_attributes",
                                     directBody: try encoder.encode(RoutingTraceDirectBody(encoded_polyline: poly)),
                                     as: RoutingTraceResponse.self)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // un morceau raté : vitesse inconnue sur ce morceau, on continue
                failed += 1
                ranges.append(.init(from: a, kmh: nil))
                continue
            }
            for e in res.edges ?? [] {
                let from = a + e.b
                let kmh = vehicle.isTruck ? RoutingTruck.limit(car: e.kmh, hgv: e.hgv, roadClass: e.rc, vehicle: vehicle) : e.kmh
                if let lastR = ranges.last, lastR.kmh == kmh { continue }
                if let lastR = ranges.last, lastR.from == from { ranges[ranges.count - 1].kmh = kmh } else { ranges.append(.init(from: from, kmh: kmh)) }
            }
        }
        // tout a échoué (hors ligne) : on n'invente pas de « limites inconnues », on laisse réessayer
        if !chunks.isEmpty && failed == chunks.count { throw RoutingError(message: "Limites de vitesse indisponibles.", retryable: true) }
        ranges.sort { $0.from < $1.from }
        if ranges.first.map({ $0.from > 0 }) ?? true { ranges.insert(.init(from: 0, kmh: nil), at: 0) }
        var out: [Route.SpeedLimit] = []
        for r in ranges where out.last?.kmh != r.kmh || out.isEmpty { out.append(r) }
        return out
    }

    /// Position d'insertion d'une étape qui allonge le moins le trajet.
    static func bestInsertIndex(origin: CLLocationCoordinate2D, stops: [CLLocationCoordinate2D], destination: CLLocationCoordinate2D, point p: CLLocationCoordinate2D) -> Int {
        let seq = [origin] + stops + [destination]
        var best = 0, bestCost = Double.infinity
        for i in 0..<(seq.count - 1) {
            let cost = Geo.distance(seq[i], p) + Geo.distance(p, seq[i + 1]) - Geo.distance(seq[i], seq[i + 1])
            if cost < bestCost { bestCost = cost; best = i }
        }
        return best
    }
}
