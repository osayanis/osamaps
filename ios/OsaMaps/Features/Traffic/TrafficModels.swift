import SwiftUI
import CoreLocation

/// Contrat du serveur (`server/features/traffic.js`) : mêmes champs que la version web (`api.ts`).

enum TrafficLevel: String, Codable, Sendable {
    case ok, slow, jam

    var color: Color {
        switch self {
        case .ok: Osa.ok
        case .slow: Osa.slow
        case .jam: Osa.jam
        }
    }

    var label: String {
        switch self {
        case .ok: "Fluide"
        case .slow: "Ralenti"
        case .jam: "Bouchon"
        }
    }

    /// Niveau inconnu → fluide (le serveur n'envoie que ok | slow | jam).
    init(raw: String) { self = TrafficLevel(rawValue: raw) ?? .ok }
}

/// Propriétés d'un tronçon coloré. `src` : "osa" (contributions) ou "dir" (station Bison Futé / DIR).
struct TrafficSegmentProps: Codable, Hashable, Sendable {
    var id: String
    var src: String
    var level: String
    var speed: Double
    var usual: Double?
    var road: String?
    var delay: Double?
    var n: Int?

    var trafficLevel: TrafficLevel { TrafficLevel(raw: level) }
}

struct TrafficLineGeometry: Codable, Hashable, Sendable {
    var coordinates: [[Double]]
}

struct TrafficSegment: Codable, Hashable, Sendable {
    var geometry: TrafficLineGeometry
    var properties: TrafficSegmentProps

    /// [lng, lat] → coordonnées (points invalides ignorés).
    var coordinates: [CLLocationCoordinate2D] {
        geometry.coordinates.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
    }
}

struct TrafficSegmentsResponse: Codable, Sendable {
    var features: [TrafficSegment]
}

/// Évènement officiel (DATEX II, Evenementiel-DIR).
enum TrafficEventKind: String, CaseIterable, Sendable {
    case closure, accident, slow, obstacle, conditions, works, lanes

    /// Symbole SF (glyphe blanc dans la pastille) ; repli si absent du système.
    var symbol: String {
        switch self {
        case .closure: "minus"
        case .accident: "car.side.rear.and.collision.and.car.side.front"
        case .slow: "tortoise.fill"
        case .obstacle: "exclamationmark"
        case .conditions: "snowflake"
        case .works: "cone.fill"
        case .lanes: "arrow.triangle.merge"
        }
    }

    /// La couleur ne dit que l'état : fermeture / bouchon = rouge, danger = jaune, gêne = orange.
    var tone: Color {
        switch self {
        case .closure, .slow: Osa.jam
        case .accident, .obstacle, .conditions: Osa.danger
        case .works, .lanes: Osa.slow
        }
    }

    var uiTone: UIColor { UIColor(tone) }

    /// Rang d'importance (petit = plus important) : sert à la priorité d'affichage sur la carte.
    var rank: Int {
        switch self {
        case .closure: 0
        case .accident: 1
        case .slow: 2
        case .obstacle: 3
        case .conditions: 4
        case .works: 5
        case .lanes: 6
        }
    }
}

struct TrafficEventProps: Codable, Hashable, Sendable {
    var id: String
    var kind: String
    var title: String
    var road: String?
    var description: String?
    var `where`: String?
    var source: String?
    var severity: String?
    var end: String?

    var eventKind: TrafficEventKind { TrafficEventKind(rawValue: kind) ?? .obstacle }
}

struct TrafficPointGeometry: Codable, Hashable, Sendable {
    var coordinates: [Double]
}

struct TrafficEvent: Codable, Hashable, Sendable {
    var geometry: TrafficPointGeometry
    var properties: TrafficEventProps

    var coordinate: CLLocationCoordinate2D? {
        let c = geometry.coordinates
        guard c.count >= 2 else { return nil }
        return .init(latitude: c[1], longitude: c[0])
    }
}

struct TrafficEventsResponse: Codable, Sendable {
    var features: [TrafficEvent]
}

/// Diffusion socket `traffic:update` (seulement ce qui a changé dans la zone).
struct TrafficUpdate: Codable, Sendable {
    var features: [TrafficSegment]?
    var removed: [String]?
}

/// Réponse de `POST /traffic/along` : portions ralenties en mètres depuis le début du tracé envoyé.
struct TrafficAlongResult: Codable, Sendable {
    struct Run: Codable, Sendable {
        var from: Double
        var to: Double
        var level: String
        var delay: Double
        var speed: Double
        var sources: [String]
    }
    var runs: [Run]
    var totalDelay: Double
    var length: Double
}

/// Une portion ralentie de l'itinéraire actif, en mètres depuis le début du tracé de la route.
struct TrafficRouteRun: Equatable, Sendable {
    var from: Double
    var to: Double
    var level: TrafficLevel
    /// Retard estimé (s).
    var delay: Double
    var speed: Double
    var sources: [String]
    /// Position du début (identifiant stable pour les alertes).
    var start: CLLocationCoordinate2D

    static func == (a: Self, b: Self) -> Bool {
        a.from == b.from && a.to == b.to && a.level == b.level && a.delay == b.delay
    }
}

/// Retard restant devant et prochain ralentissement, recalculés en roulant.
struct TrafficAhead: Equatable, Sendable {
    var delay: Double
    var next: TrafficRouteRun?
    /// Mètres jusqu'au prochain ralentissement.
    var nextDistance: Double?
}

/// Décode un argument socket (objet JSON déjà désérialisé) vers un type Codable.
func trafficDecode<T: Decodable>(_ any: Any?, as: T.Type) -> T? {
    guard let any, JSONSerialization.isValidJSONObject(any),
          let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}
