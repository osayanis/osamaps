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
    }

    /// Mon carburant, ou véhicule électrique.
    var energy: AlongEnergy = .gazole { didSet { save() } }
    /// Consommation thermique, L/100 km.
    var consumption: Double = 6.5 { didSet { save() } }
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
        energy = s.energy ?? .gazole
        consumption = s.consumption ?? 6.5
        evConsumption = s.evConsumption ?? 17
        showStations = s.showStations ?? true
        pauseReminder = s.pauseReminder ?? true
        weatherAlerts = s.weatherAlerts ?? true
        // argument de lancement pour les tests : « -alongEnergy ev »
        if let e = UserDefaults.standard.string(forKey: "alongEnergy").flatMap(AlongEnergy.init(rawValue:)) { energy = e }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        Store.save("along.prefs", Saved(energy: energy, consumption: consumption, evConsumption: evConsumption,
                                        showStations: showStations, pauseReminder: pauseReminder, weatherAlerts: weatherAlerts))
    }
}
