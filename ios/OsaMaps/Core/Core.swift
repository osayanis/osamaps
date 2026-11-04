import Foundation
import MapKit
import Observation

/// État partagé de l'app (équivalent du store `useCore` de la version web).
/// Lu par toutes les vues (`@Environment(Core.self)` ou `Core.shared`), écrit sur le MainActor.
@MainActor
@Observable
final class Core {
    static let shared = Core()

    /// La carte (MKMapView) une fois créée — les modules y posent leurs calques via `MapHub`.
    @ObservationIgnored weak var map: MKMapView?
    var mapReady = false

    var position: Position?
    /// La carte suit la position (bouton « recentrer »).
    var follow = true
    var mode: Mode = .browse
    var destination: Place?
    var routes: [Route] = []
    var activeRoute = 0
    var progress: Progress?

    /// Panneau du bas ouvert (id libre décidé par les modules) ; nil = panneau par défaut du mode.
    var panel: String?
    /// Données associées au panneau ouvert.
    @ObservationIgnored var panelData: Any?
    /// Compteur pour que les vues voient un changement de `panelData`.
    var panelVersion = 0

    var settingsOpen = false

    /// Hauteur actuelle du panneau du bas (mesurée par RootView) : pour les marges de caméra.
    var sheetHeight: CGFloat = 0

    var route: Route? { routes.indices.contains(activeRoute) ? routes[activeRoute] : nil }

    func openPanel(_ id: String?, data: Any? = nil) {
        panelData = data
        panelVersion += 1
        panel = id
    }

    private init() {}
}
