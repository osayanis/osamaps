import Foundation
import Network

/// Surveille le réseau (NWPathMonitor) : bannière « Pas de réseau », toast au retour,
/// et `.custom(name: "shell:online", payload: ["online": "1" | "0"])` pour les autres modules.
@MainActor
final class ShellNetwork {
    static let shared = ShellNetwork()
    private let monitor = NWPathMonitor()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            let ok = path.status == .satisfied
            Task { @MainActor in ShellNetwork.shared.update(ok) }
        }
        monitor.start(queue: DispatchQueue(label: "fr.osalabs.osamaps.network"))
    }

    private func update(_ ok: Bool) {
        let state = ShellState.shared
        guard state.online != ok else { return }
        state.online = ok
        Bus.shared.emit(.custom(name: "shell:online", payload: ["online": ok ? "1" : "0"]))
        if ok {
            ShellToasts.shared.show(Toast(id: "shell-online", text: "De retour en ligne", icon: "wifi", tone: .good, duration: 2.5))
        } else if ShellPrefs.haptics {
            Haptic.play("error")
        }
    }
}
