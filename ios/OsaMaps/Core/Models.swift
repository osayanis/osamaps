import Foundation
import CoreLocation

/// Un lieu (adresse, POI, favori, ami…). Mêmes champs que le `Place` de l'app web.
struct Place: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    /// Ligne secondaire (adresse, ville).
    var detail: String?
    var lat: Double
    var lng: Double
    /// Catégorie libre : "address", "poi", "fuel", "friend", "favorite"…
    var kind: String?

    init(id: String = UUID().uuidString, name: String, detail: String? = nil, coordinate: CLLocationCoordinate2D, kind: String? = nil) {
        self.id = id; self.name = name; self.detail = detail
        self.lat = coordinate.latitude; self.lng = coordinate.longitude; self.kind = kind
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

/// Une manœuvre de guidage (format proche de Valhalla, comme dans l'app web).
struct Maneuver: Hashable, Codable, Sendable {
    /// Texte à afficher (« Tournez à droite sur la rue de Paris »).
    var instruction: String
    /// Phrase à dire avant la manœuvre.
    var verbal: String?
    /// Type Valhalla (1…37) ; "waypoint" = étape intermédiaire atteinte → `typeName`.
    var type: Int
    var typeName: String?
    /// Index dans `Route.coords` où la manœuvre commence.
    var shapeIndex: Int
    /// Mètres jusqu'à la manœuvre suivante.
    var length: Double
    /// Secondes jusqu'à la manœuvre suivante.
    var time: Double
    var street: String?
    /// Rond-point : numéro de la sortie.
    var roundaboutExit: Int?
    var lanes: [Lane]?

    struct Lane: Hashable, Codable, Sendable {
        var directions: [String]
        var valid: Bool
    }
}

/// Un itinéraire calculé.
struct Route: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var coords: [Coord]
    /// Mètres.
    var distance: Double
    /// Secondes.
    var duration: Double
    var maneuvers: [Maneuver]
    /// Limites de vitesse : à partir de l'index `from` du tracé, `kmh` (nil = inconnue).
    var speedLimits: [SpeedLimit]?
    var summary: String?
    var hasToll = false
    var hasHighway = false
    var hasFerry = false

    struct SpeedLimit: Hashable, Codable, Sendable { var from: Int; var kmh: Int? }

    var coordinates: [CLLocationCoordinate2D] { coords.map(\.coordinate) }
}

/// Coordonnée codable (CLLocationCoordinate2D ne l'est pas).
struct Coord: Hashable, Codable, Sendable {
    var lat: Double
    var lng: Double
    init(_ c: CLLocationCoordinate2D) { lat = c.latitude; lng = c.longitude }
    init(lat: Double, lng: Double) { self.lat = lat; self.lng = lng }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

enum Mode: String, Sendable { case browse, preview, drive }

/// Position courante (GPS ou simulateur).
struct Position: Equatable, Sendable {
    var coordinate: CLLocationCoordinate2D
    /// Degrés, 0 = nord ; nil si inconnu.
    var heading: Double?
    /// m/s ; nil si inconnu.
    var speed: Double?
    var accuracy: Double?
    var time: Date
    var simulated: Bool

    static func == (a: Position, b: Position) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
            && a.heading == b.heading && a.speed == b.speed && a.time == b.time
    }

    var speedKmh: Double? { speed.map { max(0, $0 * 3.6) } }
}

/// Progression sur l'itinéraire actif (calculée par le module guidance).
struct Progress: Equatable, Sendable {
    var shapeIndex: Int
    var maneuverIndex: Int
    /// Mètres.
    var remainingDistance: Double
    /// Secondes.
    var remainingTime: Double
}

/// Alerte de conduite (signalement devant, zone de danger, bouchon…) — affichée/annoncée par guidance.
struct DriveAlert: Identifiable, Equatable, Sendable {
    enum Tone: String, Sendable { case info, warn, danger, police }
    var id: String
    var kind: String
    var text: String
    /// Mètres jusqu'à l'alerte.
    var distance: Double
    var tone: Tone = .warn
}

/// Message court affiché par le module shell.
struct Toast: Identifiable, Equatable, Sendable {
    enum Tone: String, Sendable { case info, good, warn }
    var id: String = UUID().uuidString
    var text: String
    /// Nom de symbole SF ou "mascot".
    var icon: String?
    var tone: Tone = .info
    var duration: TimeInterval = 3.5
}
