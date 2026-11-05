import SwiftUI
import MapKit
import Observation

/// Le shell d'OsaMaps : tout ce qui entoure la carte.
///   overlay   accueil du premier lancement, toasts + bannière hors ligne
///   rail      Réglages + Boussole (en haut, order 0), Recentrer (en bas, order 1000)
///   settings  « Général » (en haut, order 0), « Accueil et données » + « À propos » (en bas, order 1000)
///   top / hud un repère invisible (order 10 000) qui mesure le bas de la barre du haut : les toasts
///             se posent juste en dessous, sans cacher la recherche ni le guidage
///   carte     style clair / sombre / auto (lever et coucher du soleil calculés sur place)
/// + retours haptiques, surveillance du réseau, Siri / Raccourcis.
/// (L'écran toujours allumé en conduite est géré par le module guidance : isIdleTimerDisabled.)
///
/// Contrats exposés aux autres modules (sans import) :
///   emit(.toast(Toast(text:icon:tone:duration:)))   un toast (même `id` = remplace le précédent)
///   emit(.haptic("light" | "medium" | "success" | "warning" | "error"))
///   emit(.mapRecenter)                             recentre (follow = true)
///   .custom(name: "shell:mapTheme", payload: ["theme": "light" | "dark"])  émis quand le fond change
///   .custom(name: "shell:report", payload: ["kind": "police"|"accident"|"jam"|"hazard"|"works"])  Siri (écouté par reports)
///   .custom(name: "shell:online", payload: ["online": "1" | "0"])         changement de réseau
let shellFeature = Feature(
    id: "shell",
    name: "Accueil, réglages et confort",
    slots: [
        SlotEntry(.overlay, order: 10) { ShellOverlay() },
        SlotEntry(.rail, order: 0) { ShellRailTop() },
        SlotEntry(.rail, order: 1000) { ShellRecenterButton() },
        SlotEntry(.settings, order: 0) { ShellGeneralSettings() },
        SlotEntry(.settings, order: 1000) { ShellAboutSettings() },
        SlotEntry(.top, order: 10_000) { ShellTopMarker(slot: .top) },
        SlotEntry(.hud, order: 10_000) { ShellTopMarker(slot: .hud) },
    ],
    mapLayers: [
        MapLayer(id: "shell.style", zIndex: 0, attach: { map in ShellMapStyle.shared.attach(map) }),
    ],
    start: { ShellState.shared.start() }
)

/// État du shell (toasts, réseau, repères de mise en page, boussole).
@MainActor
@Observable
final class ShellState {
    static let shared = ShellState()

    /// Tous les modules ont démarré (les intents Siri attendent ce moment pour émettre).
    private(set) var started = false
    var online = true
    /// Bas de la barre du haut (coordonnées globales), mesuré par `ShellTopMarker`.
    var topMarkerY: CGFloat = 0
    var hudMarkerY: CGFloat = 0
    /// Orientation de la carte (pour la boussole).
    var mapHeading: Double = 0
    var mapPitch: Double = 0

    @ObservationIgnored private var tokens: [BusToken] = []
    @ObservationIgnored private var cameraTimer: Timer?

    private init() {}

    func start() {
        guard !started else { return }
        tokens.append(Bus.shared.on { [weak self] e in self?.handle(e) })
        ShellNetwork.shared.start()
        cameraTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in ShellState.shared.readCamera() }
        }
        started = true
    }

    private func handle(_ e: BusEvent) {
        switch e {
        case .toast(let t): ShellToasts.shared.show(t)
        case .haptic(let kind): if ShellPrefs.haptics { Haptic.play(kind) }
        case .mapRecenter: Core.shared.follow = true
        case .driveAlert(let a): if (a.tone == .warn || a.tone == .danger || a.tone == .police) && ShellPrefs.haptics { Haptic.play("warning") }
        case .driveArrived: if ShellPrefs.haptics { Haptic.play("success") }
        case .driveStart: if ShellPrefs.haptics { Haptic.play("light") }
        default: break
        }
    }

    private func readCamera() {
        guard let cam = Core.shared.map?.camera else { return }
        var h = cam.heading.truncatingRemainder(dividingBy: 360)
        if h > 180 { h -= 360 }
        if abs(h - mapHeading) > 0.5 { mapHeading = h }
        if abs(cam.pitch - mapPitch) > 0.5 { mapPitch = cam.pitch }
    }
}

/// Réglages propres au shell (Store, clés « shell.* »).
@MainActor
enum ShellPrefs {
    static var haptics: Bool {
        get { Store.load("shell.haptics", default: true) }
        set { Store.save("shell.haptics", newValue) }
    }
}

/// Repère invisible posé en dernier dans les slots top / hud : son y global = bas de la barre du haut.
struct ShellTopMarker: View {
    let slot: Slot
    var body: some View {
        Color.clear
            .frame(height: 0)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { y in
                if slot == .top { ShellState.shared.topMarkerY = y } else { ShellState.shared.hudMarkerY = y }
            }
    }
}

/// L'overlay du shell : accueil (tant que non vu) + toasts et bannière hors ligne.
struct ShellOverlay: View {
    @Environment(Prefs.self) private var prefs
    @State private var forced = UserDefaults.standard.bool(forKey: "shellOnboarding")

    var body: some View {
        ZStack {
            ShellToastStack()
            if !prefs.onboarded || forced {
                ShellOnboarding(onDone: { forced = false })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: prefs.onboarded)
    }
}
