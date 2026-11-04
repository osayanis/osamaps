import Foundation
import Observation

/// Vignette Crit'Air du véhicule ("EL" = Crit'Air 0, électrique/hydrogène).
/// Ordre défini par le schéma national des ZFE : EL, V1, V2, V3, V4, V5, NC.
enum SafetyCritAir: String, Codable, CaseIterable, Sendable {
    case unset, EL, V1, V2, V3, V4, V5, NC

    static let order: [SafetyCritAir] = [.EL, .V1, .V2, .V3, .V4, .V5, .NC]

    var label: String {
        switch self {
        case .unset: "Non réglée"
        case .EL: "Crit'Air 0 (électrique)"
        case .V1: "Crit'Air 1"
        case .V2: "Crit'Air 2"
        case .V3: "Crit'Air 3"
        case .V4: "Crit'Air 4"
        case .V5: "Crit'Air 5"
        case .NC: "Non classé"
        }
    }

    /// Libellé court des pastilles des Réglages.
    var short: String {
        switch self {
        case .unset: "—"
        case .EL: "0"
        case .NC: "NC"
        default: String(rawValue.dropFirst())
        }
    }

    /// Dans les données ZFE, `vp` = première vignette INTERDITE (« V4 » : Crit'Air 4, 5 et non classés
    /// interdits). nil si on ne sait pas (vignette non réglée ou pas de règle voiture).
    func forbidden(firstForbidden: String?) -> Bool? {
        guard self != .unset, let f = firstForbidden, let b = SafetyCritAir(rawValue: f),
              let ib = Self.order.firstIndex(of: b), let ia = Self.order.firstIndex(of: self) else { return nil }
        return ia >= ib
    }
}

/// Réglages du module sécurité (clé locale « safety.settings », pas dans `Prefs` pour éviter les
/// conflits entre modules). Mêmes champs et mêmes valeurs par défaut que la version web.
@MainActor
@Observable
final class SafetySettings {
    static let shared = SafetySettings()

    private struct Saved: Codable {
        var critair: SafetyCritAir = .unset
        var dangerZones = true
        var zfe = true
        var curves = true
        var levelCrossings = true
        var schools = true
        var night = true
        var passenger = true
    }

    var critair: SafetyCritAir { didSet { save() } }
    var dangerZones: Bool { didSet { save() } }
    var zfe: Bool { didSet { save() } }
    var curves: Bool { didSet { save() } }
    var levelCrossings: Bool { didSet { save() } }
    var schools: Bool { didSet { save() } }
    var night: Bool { didSet { save() } }
    var passenger: Bool { didSet { save() } }

    private init() {
        let s = Store.load("safety.settings", default: Saved())
        critair = s.critair; dangerZones = s.dangerZones; zfe = s.zfe; curves = s.curves
        levelCrossings = s.levelCrossings; schools = s.schools; night = s.night; passenger = s.passenger
    }

    private func save() {
        Store.save("safety.settings", Saved(critair: critair, dangerZones: dangerZones, zfe: zfe, curves: curves,
                                            levelCrossings: levelCrossings, schools: schools, night: night, passenger: passenger))
    }
}
