import Foundation
import CoreLocation

/// Carburants du flux officiel (mêmes clés que le serveur `server/features/along.js`), ou électrique.
enum AlongEnergy: String, Codable, CaseIterable, Sendable {
    case gazole, sp95, e10, sp98, gplc, e85, ev

    static let fuels: [AlongEnergy] = [.gazole, .sp95, .e10, .sp98, .gplc, .e85]

    var label: String {
        switch self {
        case .gazole: "Gazole"
        case .sp95: "SP95"
        case .e10: "SP95-E10"
        case .sp98: "SP98"
        case .gplc: "GPL"
        case .e85: "E85"
        case .ev: "Électrique"
        }
    }

    var isEV: Bool { self == .ev }
}

struct AlongFuelPrice: Codable, Hashable, Sendable {
    var p: Double
    var maj: String?
}

/// Station-service (flux instantané prix-carburants.gouv.fr, via le serveur).
struct AlongFuelStation: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var lng: Double
    var lat: Double
    var address: String
    var city: String
    var cp: String
    /// Station d'autoroute.
    var highway: Bool
    /// Automate carte bancaire 24 h/24.
    var h24: Bool
    /// 7 jours (lundi → dimanche) : créneaux [ouverture, fermeture] ; [] = fermé ; nil = inconnu.
    var hours: [[[String]]?]?
    /// Carburants en rupture temporaire.
    var shortage: [String]
    var prices: [String: AlongFuelPrice]
    /// Le long d'un tracé : mètres depuis le début / écart au tracé.
    var along: Double?
    var offset: Double?

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    func price(_ e: AlongEnergy) -> AlongFuelPrice? { prices[e.rawValue] }
    func isShort(_ e: AlongEnergy) -> Bool { shortage.contains(e.rawValue) }
    var name: String { city.isEmpty ? "Station-service" : "Station \(city)" }
}

/// Lieu de recharge (base nationale IRVE, regroupée par lieu côté serveur).
struct AlongEvStation: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var lng: Double
    var lat: Double
    var operator_: String
    var name: String
    var address: String
    var hours: String
    var free: Bool
    /// Puissance max (kW, 0 = inconnue).
    var kw: Double
    var points: Int
    var plugs: [String]
    var along: Double?
    var offset: Double?

    enum CodingKeys: String, CodingKey {
        case id, lng, lat, name, address, hours, free, kw, points, plugs, along, offset
        case operator_ = "operator"
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

/// Aire de repos / de services devant le conducteur.
struct AlongRestArea: Codable, Hashable, Sendable {
    var id: String
    var lng: Double
    var lat: Double
    var kind: String
    var name: String?
    var city: String?
    var fuel: Bool?
    var toilets: Bool?
    var along: Double
    var offset: Double
}

/// Données du panneau « along.station » (`core.panelData`).
enum AlongStationRef: Hashable, Sendable {
    case fuel(AlongFuelStation)
    case ev(AlongEvStation)
}

/// Stations le long de l'itinéraire actif.
struct AlongRouteStations: Sendable {
    enum Status: Sendable { case loading, ready, error }
    var routeId: String
    var energy: AlongEnergy
    var status: Status
    var fuel: [AlongFuelStation] = []
    var ev: [AlongEvStation] = []
}
