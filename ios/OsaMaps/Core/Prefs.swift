import Foundation
import Observation

/// Préférences partagées entre modules (persistées dans UserDefaults, clés « prefs.* »).
/// Une préférence propre à un module : utilise `Store` (Identity.swift) avec une clé préfixée par ton id.
@MainActor
@Observable
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    var avoidTolls: Bool { didSet { d.set(avoidTolls, forKey: "prefs.avoidTolls") } }
    var avoidHighways: Bool { didSet { d.set(avoidHighways, forKey: "prefs.avoidHighways") } }
    var avoidFerries: Bool { didSet { d.set(avoidFerries, forKey: "prefs.avoidFerries") } }
    /// "auto" (clair le jour, sombre la nuit), "dark", "light".
    var mapStyle: String { didSet { d.set(mapStyle, forKey: "prefs.mapStyle") } }
    var voice: Bool { didSet { d.set(voice, forKey: "prefs.voice") } }
    /// Tolérance de dépassement de vitesse (km/h).
    var speedTolerance: Int { didSet { d.set(speedTolerance, forKey: "prefs.speedTolerance") } }
    /// Partage de position avec les amis (opt-in).
    var shareLocation: Bool { didSet { d.set(shareLocation, forKey: "prefs.shareLocation") } }
    /// Envoi anonyme de la vitesse pour le trafic (opt-in, proposé à l'accueil).
    var contributeTraffic: Bool { didSet { d.set(contributeTraffic, forKey: "prefs.contributeTraffic") } }
    /// L'écran d'accueil a été vu.
    var onboarded: Bool { didSet { d.set(onboarded, forKey: "prefs.onboarded") } }

    private init() {
        d.register(defaults: [
            "prefs.mapStyle": "dark", "prefs.voice": true, "prefs.speedTolerance": 5, "prefs.contributeTraffic": true,
        ])
        avoidTolls = d.bool(forKey: "prefs.avoidTolls")
        avoidHighways = d.bool(forKey: "prefs.avoidHighways")
        avoidFerries = d.bool(forKey: "prefs.avoidFerries")
        mapStyle = d.string(forKey: "prefs.mapStyle") ?? "dark"
        voice = d.bool(forKey: "prefs.voice")
        speedTolerance = d.integer(forKey: "prefs.speedTolerance")
        shareLocation = d.bool(forKey: "prefs.shareLocation")
        contributeTraffic = d.bool(forKey: "prefs.contributeTraffic")
        // argument de lancement « -onboarded YES » pour les tests (sauter l'accueil)
        onboarded = d.bool(forKey: "prefs.onboarded") || d.bool(forKey: "onboarded")
    }
}
