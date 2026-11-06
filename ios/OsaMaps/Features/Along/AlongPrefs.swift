import Foundation
import Observation

/// Réglages propres au module (Store « along.prefs »).
@MainActor
@Observable
final class AlongPrefs {
    static let shared = AlongPrefs()

    private struct Saved: Codable {
        var energy: AlongEnergy?
        var consumption: Double?
        var evConsumption: Double?
        var showStations: Bool?
        var pauseReminder: Bool?
        var weatherAlerts: Bool?
        /// Mode camion : carburant et consommation à part (par catégorie), pour ne pas écraser ceux de la voiture.
        var truckEnergy: AlongEnergy?
        var truckConsumption: [String: Double]?
    }

    /// Voiture : mon carburant (ou électrique) et ma consommation thermique (L/100 km).
    private var carEnergy: AlongEnergy = .gazole { didSet { save() } }
    private var carConsumption: Double = 6.5 { didSet { save() } }
    /// Camion : gazole par défaut, consommation propre à chaque catégorie (Prefs.shared.vehicle).
    private var truckEnergy: AlongEnergy = .gazole { didSet { save() } }
    private var truckConsumption: [String: Double] = [:] { didSet { save() } }

    private var vehicle: Vehicle { Prefs.shared.vehicle }

    /// Consommation habituelle d'un poids lourd (L/100 km) : porteur ~25, semi ~32, convoi exceptionnel ~45.
    static func truckDefault(_ k: Vehicle.Kind) -> Double {
        switch k {
        case .car: 6.5
        case .truck: 25
        case .heavy: 32
        case .superheavy: 45
        }
    }

    /// Mon carburant, ou véhicule électrique (selon le véhicule actif).
    var energy: AlongEnergy {
        get { vehicle.isTruck ? truckEnergy : carEnergy }
        set { if vehicle.isTruck { truckEnergy = newValue } else { carEnergy = newValue } }
    }
    /// Consommation thermique, L/100 km (selon le véhicule actif).
    var consumption: Double {
        get { vehicle.isTruck ? truckConsumption[vehicle.kind.rawValue] ?? Self.truckDefault(vehicle.kind) : carConsumption }
        set { if vehicle.isTruck { truckConsumption[vehicle.kind.rawValue] = newValue } else { carConsumption = newValue } }
    }
    /// Bornes du réglage de consommation thermique.
    var consumptionRange: ClosedRange<Double> { vehicle.isTruck ? 10...90 : 2...25 }
    /// Consommation électrique, kWh/100 km.
    var evConsumption: Double = 17 { didSet { save() } }
    /// Afficher les stations sur la carte.
    var showStations = true { didSet { save() } }
    /// Rappel de pause après ~2 h de conduite.
    var pauseReminder = true { didSet { save() } }
    /// Alertes météo sur le trajet.
    var weatherAlerts = true { didSet { save() } }

    @ObservationIgnored private var loading = true

    private init() {
        let s = Store.load("along.prefs", default: Saved())
        carEnergy = s.energy ?? .gazole
        carConsumption = s.consumption ?? 6.5
        truckEnergy = s.truckEnergy ?? .gazole
        truckConsumption = s.truckConsumption ?? [:]
        evConsumption = s.evConsumption ?? 17
        showStations = s.showStations ?? true
        pauseReminder = s.pauseReminder ?? true
        weatherAlerts = s.weatherAlerts ?? true
        // argument de lancement pour les tests : « -alongEnergy ev »
        if let e = UserDefaults.standard.string(forKey: "alongEnergy").flatMap(AlongEnergy.init(rawValue:)) { carEnergy = e }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        Store.save("along.prefs", Saved(energy: carEnergy, consumption: carConsumption, evConsumption: evConsumption,
                                        showStations: showStations, pauseReminder: pauseReminder, weatherAlerts: weatherAlerts,
                                        truckEnergy: truckEnergy, truckConsumption: truckConsumption))
    }
}
