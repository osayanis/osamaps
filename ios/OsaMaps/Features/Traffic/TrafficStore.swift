import Foundation
import Observation

/// État du module trafic (équivalent de `state.ts` de la version web).
@MainActor
@Observable
final class TrafficStore {
    static let shared = TrafficStore()

    /// Calque de trafic affiché (préférence locale du module).
    var visible: Bool { didSet { Store.save("traffic.visible", visible) } }
    /// Ralentissements sur l'itinéraire actif (nil = rien de connu / pas d'itinéraire).
    var routeRuns: (routeId: String, runs: [TrafficRouteRun], at: Date)? = nil
    /// Retard restant devant, recalculé en roulant.
    var ahead: TrafficAhead?
    /// Segments envoyés pendant le trajet en cours (affiché dans les réglages, par transparence).
    var sent = 0
    var tripActive = false

    private init() {
        visible = Store.load("traffic.visible", default: true)
    }
}
