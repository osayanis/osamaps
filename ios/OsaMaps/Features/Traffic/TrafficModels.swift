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

/// Type d'un évènement multi-sources (`server/features/events.js`).
enum TrafficEventKind: String, CaseIterable, Sendable {
    case closure, accident, jam, danger, flood, weather, lanes, works, fuel, hotspot

    /// Symbole SF (glyphe blanc dans la pastille) ; repli si absent du système.
    var symbol: String {
        switch self {
        case .closure: "minus"
        case .accident: "car.side.rear.and.collision.and.car.side.front"
        case .jam: "car.2.fill"
        case .danger: "exclamationmark"
        case .flood: "water.waves"
        case .weather: "cloud.bolt.rain.fill"
        case .lanes: "arrow.triangle.merge"
        case .works: "cone.fill"
        case .fuel: "fuelpump.slash.fill"
        case .hotspot: "exclamationmark.triangle.fill"
        }
    }

    /// La couleur ne dit que l'état : fermeture / bouchon = rouge, danger = jaune, gêne = orange.
    var tone: Color {
        switch self {
        case .closure, .jam: Osa.jam
        case .accident, .danger, .weather, .flood, .hotspot: Osa.danger
        case .works, .lanes, .fuel: Osa.slow
        }
    }

    var uiTone: UIColor { UIColor(tone) }

    var label: String {
        switch self {
        case .closure: "Route fermée"
        case .accident: "Accident"
        case .jam: "Bouchon"
        case .danger: "Danger"
        case .flood: "Vigilance crues"
        case .weather: "Vigilance météo"
        case .lanes: "Voies réduites"
        case .works: "Travaux"
        case .fuel: "Rupture de carburant"
        case .hotspot: "Section accidentogène"
        }
    }

    /// Rang d'importance (petit = plus important) : priorité d'affichage sur la carte.
    var rank: Int {
        switch self {
        case .closure: 0
        case .accident: 1
        case .jam: 2
        case .danger: 3
        case .flood: 4
        case .weather: 5
        case .lanes: 6
        case .works: 7
        case .fuel: 8
        case .hotspot: 9
        }
    }
}

struct TrafficEventSource: Codable, Hashable, Sendable {
    var id: String
    var name: String
}

struct TrafficRelatedJam: Codable, Hashable, Sendable {
    var id: String
    var delay: Double?
    var speed: Double?
    var distance: Double?
}

/// Propriétés d'un évènement fusionné (GET /events, POST /events/route).
struct TrafficEventProps: Codable, Hashable, Sendable {
    var id: String
    var type: String
    var severity: Int
    var title: String
    var description: String?
    var original: String?
    var lang: String?
    var road: String?
    var direction: String?
    var lanes: String?
    var start: String?
    var end: String?
    var delay: Double?
    var speed: Double?
    var blocking: Bool?
    var confidence: Double?
    var sources: [TrafficEventSource]?
    var merged: Int?
    var relatedJam: TrafficRelatedJam?
    var line: [[Double]]?

    var eventKind: TrafficEventKind { TrafficEventKind(rawValue: type) ?? .danger }

    /// « élevée » / « moyenne » / « faible » (confiance calculée par le serveur).
    var confidenceLabel: String {
        let c = confidence ?? 0.5
        return c >= 0.85 ? "élevée" : c >= 0.6 ? "moyenne" : "faible"
    }

    var lineCoordinates: [CLLocationCoordinate2D] {
        (line ?? []).compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
    }
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

/// Réponse de `POST /events/route` : évènements touchant le tracé envoyé (mètres depuis son début).
struct TrafficEventsRouteResult: Codable, Sendable {
    struct Hit: Codable, Sendable {
        var id: String
        var type: String
        var severity: Int
        var title: String
        var description: String?
        var road: String?
        var lanes: String?
        var blocking: Bool?
        var confidence: Double?
        var sources: [TrafficEventSource]?
        var point: [Double]
        var at: Double
        var length: Double
        var routeDelay: Double
        var alreadyMeasured: Bool?

        var eventKind: TrafficEventKind { TrafficEventKind(rawValue: type) ?? .danger }
    }
    var events: [Hit]
    var totalDelay: Double
}

/// Un évènement sur l'itinéraire actif, en mètres depuis le début du tracé de la route.
struct TrafficRouteEvent: Equatable, Sendable {
    var id: String
    var kind: TrafficEventKind
    var severity: Int
    var title: String
    var road: String?
    var lanes: String?
    var blocking: Bool
    var confidence: Double
    var from: Double
    var to: Double
    /// Retard estimé (s), 0 si déjà compté par le trafic mesuré.
    var delay: Double
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
