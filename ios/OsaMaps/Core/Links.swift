import Foundation
import CoreLocation

/// Liens `osamaps://…` : pilotage de l'app (tests dans le Simulateur avec `xcrun simctl openurl`)
/// et liens partagés. Les liens inconnus sont relayés aux modules :
/// `Bus` → `.custom(name: "url", payload: ["url": "…"])` (ex. osamaps://suivre/JETON pour friends).
///
///   osamaps://go?name=Vichy&lat=46.1278&lng=3.4258   → place:go (le module routing calcule)
///   osamaps://drive                                  → démarre la conduite sur l'itinéraire affiché
///   osamaps://stop                                   → arrête la conduite
///   osamaps://panel/<id>                             → ouvre un panneau ; osamaps://panel (ferme)
///   osamaps://settings                               → ouvre les Réglages
///   osamaps://recenter                               → recentre
///   osamaps://toast?text=Bonjour                     → toast de test
///   osamaps://alert?text=Police%20signalée&distance=800&tone=police → drive:alert de test
@MainActor
enum Links {
    /// Au lancement à froid par un lien, les modules ne sont pas encore démarrés (pas d'abonnés au Bus) :
    /// les liens reçus avant `ready()` sont mis de côté puis rejoués.
    private static var isReady = false
    private static var pending: [URL] = []

    /// Appelé par RootView une fois tous les modules démarrés.
    static func ready() {
        isReady = true
        let queued = pending; pending = []
        queued.forEach(handle)
    }

    static func handle(_ url: URL) {
        guard url.scheme == "osamaps" else { return }
        guard isReady else { pending.append(url); return }
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let core = Core.shared
        switch url.host() {
        case "go":
            guard let lat = Double(q["lat"] ?? ""), let lng = Double(q["lng"] ?? "") else { return }
            core.openPanel(nil)
            Bus.shared.emit(.placeGo(Place(name: q["name"] ?? "Destination", coordinate: .init(latitude: lat, longitude: lng))))
        case "drive":
            guard let r = core.route else { return }
            core.routes = [r]; core.activeRoute = 0
            core.mode = .drive; core.follow = true
            Bus.shared.emit(.driveStart(routeId: r.id))
        case "stop":
            Bus.shared.emit(.driveStop(arrived: false))
            core.mode = .browse
        case "panel":
            let id = url.pathComponents.dropFirst().first
            core.openPanel(id)
        case "settings":
            core.settingsOpen = true
        case "recenter":
            core.follow = true
            Bus.shared.emit(.mapRecenter)
        case "toast":
            Bus.shared.emit(.toast(Toast(text: q["text"] ?? "Bonjour")))
        case "alert":
            Bus.shared.emit(.driveAlert(DriveAlert(id: q["id"] ?? UUID().uuidString, kind: q["kind"] ?? "test",
                                                   text: q["text"] ?? "Alerte", distance: Double(q["distance"] ?? "") ?? 500,
                                                   tone: DriveAlert.Tone(rawValue: q["tone"] ?? "") ?? .warn)))
        default:
            Bus.shared.emit(.custom(name: "url", payload: ["url": url.absoluteString]))
        }
    }
}
