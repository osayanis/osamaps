import SwiftUI
import Observation

/// File des toasts (au plus 3 visibles ; un toast de même `id` remplace le précédent).
@MainActor
@Observable
final class ShellToasts {
    static let shared = ShellToasts()
    private(set) var items: [Toast] = []
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var paused: Set<String> = []

    func show(_ t: Toast) {
        if let i = items.firstIndex(where: { $0.id == t.id }) {
            items[i] = t
        } else {
            items.append(t)
            if items.count > 3 { dismiss(items[0].id) }
            if ShellPrefs.haptics {
                Haptic.play(t.tone == .warn ? "warning" : t.tone == .good ? "success" : "light")
            }
        }
        schedule(t)
    }

    func dismiss(_ id: String) {
        timers[id]?.cancel(); timers[id] = nil
        paused.remove(id)
        items.removeAll { $0.id == id }
    }

    /// Pause pendant que le doigt est posé sur le toast.
    func pause(_ id: String, _ on: Bool) {
        if on { paused.insert(id); timers[id]?.cancel(); timers[id] = nil }
        else if paused.remove(id) != nil, let t = items.first(where: { $0.id == id }) { schedule(t, minimum: 1.5) }
    }

    private func schedule(_ t: Toast, minimum: TimeInterval = 0) {
        timers[t.id]?.cancel()
        guard t.duration > 0 else { return }
        let delay = minimum > 0 ? minimum : t.duration
        let id = t.id
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            withAnimation(Osa.anim) { self?.dismiss(id) }
        }
    }
}

/// Pile de toasts en haut (sous la recherche, ou sous le guidage en conduite) + bannière hors ligne.
struct ShellToastStack: View {
    @Environment(Core.self) private var core
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var toasts: ShellToasts { .shared }
    private var state: ShellState { .shared }

    var body: some View {
        GeometryReader { geo in
            let originY = geo.frame(in: .global).minY
            let marker: CGFloat = switch core.mode {
            case .browse: state.topMarkerY
            case .drive: state.hudMarkerY
            case .preview: 0
            }
            VStack(spacing: 8) {
                if !state.online {
                    ShellOfflineBanner(driving: core.mode == .drive)
                        .transition(edgeTransition)
                }
                ForEach(toasts.items) { t in
                    ShellToastView(toast: t)
                        .transition(edgeTransition)
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 12)
            .padding(.top, max(4, marker - originY))
            .frame(maxWidth: .infinity, alignment: .top)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : Osa.anim, value: toasts.items.map(\.id))
            .animation(Osa.anim, value: state.online)
        }
    }

    private var edgeTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }
}

struct ShellOfflineBanner: View {
    var driving: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Osa.slow)
                .frame(width: 24)
            (Text("Pas de réseau").bold().foregroundColor(Osa.text)
             + Text(driving ? " — le guidage continue avec l’itinéraire déjà chargé."
                            : " — la carte déjà affichée reste utilisable, le reste revient avec le réseau.")
                .foregroundColor(Osa.dim))
                .font(.osa(14, .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .osaGlass(18)
        .accessibilityElement(children: .combine)
    }
}

struct ShellToastView: View {
    let toast: Toast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGSize = .zero

    var body: some View {
        HStack(spacing: 12) {
            icon
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
            Text(toast.text)
                .font(.osa(15, .semibold))
                .foregroundStyle(Osa.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if toast.duration <= 0 {
                Button { withAnimation(Osa.anim) { ShellToasts.shared.dismiss(toast.id) } } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Osa.dim)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .accessibilityLabel("Fermer")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .osaGlass(18)
        .offset(x: drag.width, y: drag.height)
        .opacity(1 - min(0.6, abs(drag.width) / 300))
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { v in
                    ShellToasts.shared.pause(toast.id, true)
                    let dx = v.translation.width, dy = v.translation.height
                    // vers le bas : résistance (on ne tire pas un toast vers le bas)
                    drag = abs(dx) > abs(dy) ? CGSize(width: dx, height: 0) : CGSize(width: 0, height: dy < 0 ? dy : dy * 0.15)
                }
                .onEnded { v in
                    let fastUp = v.predictedEndTranslation.height < -60
                    let fastSide = abs(v.predictedEndTranslation.width) > 160
                    if drag.height < -28 || fastUp || abs(drag.width) > 90 || fastSide {
                        if ShellPrefs.haptics { Haptic.play("light") }
                        withAnimation(Osa.anim) { ShellToasts.shared.dismiss(toast.id) }
                    } else {
                        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.85)) { drag = .zero }
                        ShellToasts.shared.pause(toast.id, false)
                    }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityAction(named: "Fermer") { ShellToasts.shared.dismiss(toast.id) }
    }

    @ViewBuilder private var icon: some View {
        if let name = toast.icon, name == "mascot" {
            ShellMarkArrow().frame(width: 18, height: 18)
        } else if let name = toast.icon, UIImage(systemName: name) != nil {
            Image(systemName: name)
        } else {
            Image(systemName: toast.tone == .good ? "checkmark.circle.fill" : toast.tone == .warn ? "exclamationmark.triangle.fill" : "info.circle.fill")
        }
    }

    private var tint: Color {
        switch toast.tone {
        case .good: Osa.ok
        case .warn: Osa.danger
        case .info: Osa.text
        }
    }
}
