import Foundation

/// Profil du véhicule (partagé : accueil, itinéraires, guidage, sécurité, mascotte…).
/// Lu et écrit via `Prefs.shared.vehicle`. Les dimensions servent au calcul d'itinéraire
/// (Valhalla, costing "truck" : hauteur, largeur, longueur, poids, charge à l'essieu, matières dangereuses).
struct Vehicle: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// Voiture (costing "auto").
        case car
        /// Camion porteur (≤ 19 t).
        case truck
        /// Poids lourd : semi-remorque (44 t).
        case heavy
        /// Super lourd : convoi exceptionnel (> 44 t, gabarit hors norme).
        case superheavy

        var label: String {
            switch self {
            case .car: "Voiture"
            case .truck: "Camion"
            case .heavy: "Poids lourd"
            case .superheavy: "Super lourd"
            }
        }

        var detail: String {
            switch self {
            case .car: "Voiture, moto, utilitaire léger"
            case .truck: "Porteur jusqu'à 19 t"
            case .heavy: "Semi-remorque jusqu'à 44 t"
            case .superheavy: "Convoi exceptionnel, plus de 44 t"
            }
        }

        var symbol: String {
            switch self {
            case .car: "car.fill"
            case .truck: "box.truck.fill"
            case .heavy: "truck.box.fill"
            case .superheavy: "truck.box.badge.clock.fill"
            }
        }
    }

    var kind: Kind = .car
    /// Mètres.
    var height: Double = 1.6
    var width: Double = 1.9
    var length: Double = 4.5
    /// Tonnes (poids total en charge).
    var weight: Double = 1.8
    /// Tonnes par essieu.
    var axleLoad: Double = 1
    /// Matières dangereuses (ADR).
    var hazmat: Bool = false

    var isTruck: Bool { kind != .car }

    /// Valeurs par défaut de chaque catégorie (modifiables ensuite dans les Réglages).
    static func preset(_ kind: Kind) -> Vehicle {
        switch kind {
        case .car: Vehicle()
        case .truck: Vehicle(kind: .truck, height: 3.6, width: 2.55, length: 10, weight: 19, axleLoad: 11.5)
        case .heavy: Vehicle(kind: .heavy, height: 4, width: 2.55, length: 16.5, weight: 44, axleLoad: 11.5)
        case .superheavy: Vehicle(kind: .superheavy, height: 4.5, width: 3.5, length: 25, weight: 72, axleLoad: 13)
        }
    }

    /// Costing Valhalla et ses options (à passer tels quels dans la requête d'itinéraire).
    var valhallaCosting: String { isTruck ? "truck" : "auto" }
    var valhallaOptions: [String: Any] {
        guard isTruck else { return [:] }
        return ["height": height, "width": width, "length": length, "weight": weight,
                "axle_load": axleLoad, "hazmat": hazmat]
    }
}
