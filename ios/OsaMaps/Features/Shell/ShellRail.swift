import SwiftUI
import MapKit

/// Boutons du rail (bord droit, ancré en bas) :
///   order 0     Réglages (hors conduite) et Boussole (carte tournée ou inclinée, hors conduite)
///   order 100   boutons des autres modules (signaler, trafic, amis…)
///   order 1000  Recentrer — tout en bas, près du pouce, quand le suivi est coupé
struct ShellRailTop: View {
    @Environment(Core.self) private var core
    @Environment(Prefs.self) private var prefs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var state: ShellState { .shared }

    var body: some View {
        let tilted = abs(state.mapHeading) > 1.5 || state.mapPitch > 3
        VStack(spacing: 10) {
            if core.mode != .drive && prefs.onboarded {
                Button {
                    Haptic.play("light")
                    core.settingsOpen = true
                } label: { Image(systemName: "gearshape.fill") }
                .buttonStyle(.osaRound)
                .accessibilityLabel("Réglages")
                .transition(.opacity)
            }
            if core.mode != .drive && tilted && core.mapReady {
                Button(action: northUp) {
                    ShellCompassNeedle()
                        .rotationEffect(.degrees(-state.mapHeading))
                }
                .buttonStyle(.osaRound)
                .accessibilityLabel("Remettre la carte au nord")
                .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(Osa.anim, value: tilted)
        .animation(Osa.anim, value: core.mode)
    }

    private func northUp() {
        Haptic.play("light")
        guard let map = core.map else { return }
        let cam = map.camera.copy() as! MKMapCamera
        cam.heading = 0
        cam.pitch = 0
        if reduceMotion { map.setCamera(cam, animated: false) } else {
            UIView.animate(withDuration: 0.4, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
                map.setCamera(cam, animated: false)
            }
        }
    }
}

/// Aiguille de boussole : pointe nord rouge, sud blanche atténuée.
struct ShellCompassNeedle: View {
    var body: some View {
        ZStack {
            Triangle().fill(Osa.jam).frame(width: 9, height: 12).offset(y: -6)
            Triangle().fill(.white.opacity(0.7)).frame(width: 9, height: 12).rotationEffect(.degrees(180)).offset(y: 6)
            Text("N").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white).offset(y: -18)
        }
        .frame(width: 24, height: 24)
    }

    private struct Triangle: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }
}

struct ShellRecenterButton: View {
    @Environment(Core.self) private var core
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let show = !core.follow && core.position != nil
        Group {
            if show {
                if core.mode == .drive {
                    // en conduite : pilule avec libellé, plus facile à viser (≥ 56 pt)
                    Button(action: go) {
                        Label("Recentrer", systemImage: "location.fill")
                            .frame(minHeight: 56 - 26)
                    }
                    .buttonStyle(.osaPill)
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                } else {
                    Button(action: go) { Image(systemName: "location.fill") }
                        .buttonStyle(.osaRound)
                        .accessibilityLabel("Recentrer sur ma position")
                }
            }
        }
        .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
        .animation(Osa.anim, value: show)
    }

    private func go() {
        Haptic.play("light")
        core.follow = true
        Bus.shared.emit(.mapRecenter)
    }
}
