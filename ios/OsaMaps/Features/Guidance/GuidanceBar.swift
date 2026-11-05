import SwiftUI

/// Barre du bas en conduite (slot .sheet, mode drive, aucun panneau ouvert) :
/// vitesse, heure d'arrivée, temps et distance restants, progression, Arrêter, voix, vue d'ensemble.
struct GuidanceSheet: View {
    @Environment(Core.self) private var core
    @Environment(Prefs.self) private var prefs
    private let g = GuidanceState.shared
    @State private var confirm = false

    var body: some View {
        if core.mode == .drive, core.panel == nil, g.arrived == nil, let route = core.route {
            VStack(alignment: .leading, spacing: 10) {
                GuidanceSpeed().padding(.leading, 4)
                bar(route)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func bar(_ route: Route) -> some View {
        let remainingTime = core.progress?.remainingTime ?? route.duration
        let remainingDistance = core.progress?.remainingDistance ?? route.distance
        let done = route.distance > 0 ? min(1, max(0, 1 - remainingDistance / route.distance)) : 0

        return ZStack {
            if confirm {
                HStack(spacing: 10) {
                    Text("Arrêter le guidage ?")
                        .font(.osa(16, .bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 6)
                    Button("Continuer") { withAnimation(Osa.anim) { confirm = false } }
                        .buttonStyle(GuidanceSmallPill(secondary: true))
                    Button("Arrêter") {
                        confirm = false
                        Haptic.play("medium")
                        GuidanceEngine.shared.stopGuidance()
                    }
                    .buttonStyle(GuidanceSmallPill(color: Osa.jam))
                }
                .transition(.opacity)
            } else {
                HStack(spacing: 10) {
                    GuidanceBarButton(symbol: "xmark", label: "Arrêter le guidage") { withAnimation(Osa.anim) { confirm = true } }
                    VStack(spacing: 2) {
                        Text(Geo.formatETA(remainingTime))
                            .font(.osa(27, .heavy))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("\(Geo.formatDuration(remainingTime)) · \(Geo.formatDistance(remainingDistance))")
                            .font(.osa(14, .semibold))
                            .foregroundStyle(Osa.dim)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Arrivée à \(Geo.formatETA(remainingTime)), dans \(Geo.formatDuration(remainingTime)), \(Geo.formatDistance(remainingDistance)) restants")
                    GuidanceBarButton(symbol: prefs.voice ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                      label: prefs.voice ? "Couper la voix" : "Remettre la voix", dimmed: !prefs.voice) {
                        GuidanceEngine.shared.toggleVoice()
                    }
                    GuidanceBarButton(symbol: g.overview ? "location.north.line.fill" : "map",
                                      label: g.overview ? "Reprendre le suivi" : "Vue d'ensemble", on: g.overview) {
                        if g.overview { GuidanceEngine.shared.resumeFollow() } else { GuidanceEngine.shared.showOverview() }
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(minHeight: 56)
        .foregroundStyle(Osa.text)
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 12)
        .overlay(alignment: .top) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Osa.line)
                    Rectangle().fill(Osa.text.opacity(0.7)).frame(width: geo.size.width * done)
                        .animation(.easeOut(duration: 0.3), value: done)
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: Osa.radiusL, style: .continuous))
        .osaGlass()
        .task(id: confirm) {
            // la confirmation d'arrêt se replie toute seule
            guard confirm else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { withAnimation(Osa.anim) { confirm = false } }
        }
    }
}

/// Bouton rond 56 pt de la barre de conduite.
struct GuidanceBarButton: View {
    var symbol: String
    var label: String
    var dimmed = false
    var on = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(on ? .black : dimmed ? Osa.faint : Osa.text)
                .frame(width: 56, height: 56)
                .background(on ? AnyShapeStyle(Color.white) : dimmed ? AnyShapeStyle(Osa.surface) : AnyShapeStyle(Osa.surfaceHi), in: Circle())
                .overlay(Circle().strokeBorder(on ? .clear : Osa.line))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(GuidancePress())
        .accessibilityLabel(label)
    }
}

struct GuidancePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct GuidanceSmallPill: ButtonStyle {
    var secondary = false
    var color: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.osa(16, .bold))
            .padding(.horizontal, 18)
            .frame(minHeight: 56)
            .foregroundStyle(secondary ? Osa.text : .white)
            .background(secondary ? AnyShapeStyle(Osa.surfaceHi) : AnyShapeStyle(color), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
