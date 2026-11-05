import SwiftUI

/// HUD de conduite (slot .hud) : prochaine manœuvre, « puis », voies, alertes ; recalcul ; arrivée.
struct GuidanceHUD: View {
    @Environment(Core.self) private var core
    private let g = GuidanceState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let a = g.arrived {
                GuidanceArrivalCard(arrival: a)
            } else if g.recalculating {
                GuidanceRecalcCard()
            } else if let route = core.route, !route.maneuvers.isEmpty {
                GuidanceManeuverCard(route: route)
            }
            if g.arrived == nil {
                ForEach(Array(g.alerts.prefix(2))) { GuidanceAlertBanner(alert: $0) }
            }
        }
        .frame(maxWidth: 560)
        .animation(Osa.anim, value: g.alerts.map(\.id))
        .animation(Osa.anim, value: g.recalculating)
        .animation(Osa.anim, value: g.arrived)
    }
}

struct GuidanceManeuverCard: View {
    let route: Route
    @Environment(Core.self) private var core
    private let g = GuidanceState.shared

    var body: some View {
        let ms = route.maneuvers
        let idx = min(g.nextIndex, ms.count - 1)
        let m = ms[idx]
        let kind = GuidancePhrases.kind(m)
        let exit = kind == .roundabout ? GuidancePhrases.roundaboutExit(m) : nil
        // avant la première position accrochée : la distance depuis le départ
        let dist = g.along == 0 && g.distToNext == 0 ? (m.shapeIndex > 0 ? ms[0].length : 0) : g.distToNext
        let street = kind == .roundabout ? (GuidancePhrases.roundaboutExitTarget(m)?.name ?? GuidancePhrases.mainStreet(m))
            : kind == .waypoint ? GuidancePhrases.waypointName(m) : GuidancePhrases.mainStreet(m)
        let label = kind.isArrive ? (core.destination?.name ?? GuidancePhrases.shortLabel(m)) : (street.isEmpty ? GuidancePhrases.shortLabel(m) : street)
        let sub: String? = kind == .roundabout && exit != nil ? "\(GuidancePhrases.ordinalShort(exit!)) sortie"
            : kind.isArrive && kind != .arrive ? GuidancePhrases.shortLabel(m) : nil
        let imminent = dist <= g.nowThreshold && !kind.isArrive
        let thenIdx = GuidanceEngine.shared.thenIndex(route, idx, dist)
        let lanes = (m.lanes ?? []).isEmpty ? nil : m.lanes

        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    GuidanceArrow(kind: kind.rawValue, exit: exit, size: 68)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Geo.formatDistance(dist))
                            .font(.osa(40, .heavy))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Group {
                            if let sub { Text(sub).foregroundStyle(imminent ? .black : Osa.text).fontWeight(.heavy) + Text(" · \(label)") }
                            else { Text(label) }
                        }
                        .font(.osa(19, .semibold))
                        .foregroundStyle(imminent ? Color.black.opacity(0.62) : Osa.dim)
                        .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                if let lanes {
                    HStack(spacing: 4) {
                        ForEach(Array(lanes.enumerated()), id: \.offset) { _, l in GuidanceLane(directions: l.directions, valid: l.valid) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .overlay(alignment: .top) { Rectangle().fill(imminent ? Color.black.opacity(0.12) : Osa.line).frame(height: 1) }
                    .padding(.top, 12)
                    .accessibilityLabel("Voies conseillées")
                }
            }
            .padding(.vertical, 14).padding(.leading, 14).padding(.trailing, 18)
            .foregroundStyle(imminent ? .black : Osa.text)
            .background {
                if imminent { RoundedRectangle(cornerRadius: Osa.radiusL, style: .continuous).fill(Color.white.opacity(0.95)) }
            }
            .modifier(GuidanceGlass(enabled: !imminent))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(Geo.formatDistance(dist)), \(GuidancePhrases.action(m))")
            .animation(.easeOut(duration: 0.2), value: imminent)
            .id("\(route.id)-\(idx)")
            .transition(.opacity.combined(with: .move(edge: .top)))

            if let thenIdx {
                let then = ms[thenIdx]
                HStack(spacing: 8) {
                    Text("Puis").foregroundStyle(Osa.dim)
                    GuidanceArrow(kind: GuidancePhrases.kind(then).rawValue, exit: nil, size: 26)
                    let st = GuidancePhrases.mainStreet(then)
                    if !st.isEmpty { Text(st).lineLimit(1) }
                }
                .font(.osa(15, .bold))
                .foregroundStyle(Osa.text)
                .padding(.leading, 14).padding(.trailing, 16).padding(.vertical, 6)
                .modifier(GuidanceGlass(radius: 999))
                .transition(.opacity)
            }
        }
    }
}

/// Verre sombre optionnel (la carte imminente est blanche).
struct GuidanceGlass: ViewModifier {
    var enabled = true
    var radius: CGFloat = Osa.radiusL
    func body(content: Content) -> some View {
        if enabled { content.osaGlass(radius) } else { content.shadow(color: .black.opacity(0.45), radius: 20, y: 10) }
    }
}

struct GuidanceRecalcCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Osa.dim)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .frame(width: 68, height: 68)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text("Nouvel itinéraire…").font(.osa(21, .heavy))
                Text("Recalcul depuis votre position").font(.osa(17, .semibold)).foregroundStyle(Osa.dim)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Osa.text)
        .padding(14)
        .osaGlass()
        .accessibilityElement(children: .combine)
    }
}

struct GuidanceArrivalCard: View {
    let arrival: GuidanceArrival

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Osa.ok)
                    .frame(width: 68, height: 68)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vous voilà à destination").font(.osa(21, .heavy))
                    Text(arrival.name + (arrival.side.map { " · sur votre \($0 == "right" ? "droite" : "gauche")" } ?? ""))
                        .font(.osa(17, .semibold)).foregroundStyle(Osa.dim).lineLimit(2)
                    Text("\(Geo.formatDuration(arrival.tripTime)) · \(Geo.formatDistance(arrival.tripDistance)) parcourus")
                        .font(.osa(14, .semibold)).foregroundStyle(Osa.faint).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            Button("Terminer") { GuidanceEngine.shared.finishArrival() }
                .buttonStyle(GuidanceWidePill())
        }
        .foregroundStyle(Osa.text)
        .padding(14)
        .osaGlass()
    }
}

/// Pilule blanche pleine largeur, 56 pt (conduite).
struct GuidanceWidePill: ButtonStyle {
    var color: Color = .white
    var textColor: Color = .black
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.osa(17, .bold))
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 18)
            .foregroundStyle(textColor)
            .background(color, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct GuidanceAlertBanner: View {
    let alert: GuidanceAlert

    private var color: Color {
        switch alert.displayTone {
        case .danger: Osa.jam
        case .warn: Osa.danger
        case .police: Osa.police
        case .info: Osa.surfaceHi
        }
    }

    private var icon: String {
        let k = alert.kind.lowercased()
        func has(_ p: String) -> Bool { GuidancePhrases.match(p, k) != nil }
        if has("police|gendarm|control") { return "light.beacon.max.fill" }
        if has("jam|traffic|bouchon|trafic|slow") { return "car.2.fill" }
        if has("camera|radar|speed") { return "camera.fill" }
        if has("closure|closed|ferm|block") { return "minus.circle.fill" }
        if has("work|travaux|construction") { return "cone.fill" }
        if has("fog|brouillard") { return "cloud.fog.fill" }
        if has("ice|verglas|snow|neige") { return "snowflake" }
        if has("weather|meteo|météo|rain|pluie") { return "cloud.rain.fill" }
        if has("accident|crash") { return "car.side.rear.and.collision.and.car.side.front" }
        return "exclamationmark.triangle.fill"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(alert.displayTone == .danger || alert.displayTone == .info ? .white : .black)
                .frame(width: 42, height: 42)
                .background(color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(alert.text)
                .font(.osa(17, .bold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if alert.baseDistance > 0 {
                Text(alert.remaining <= 20 ? "ici" : Geo.formatDistance(alert.remaining))
                    .font(.osa(19, .heavy))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(Osa.text)
        .padding(.vertical, 8).padding(.leading, 8).padding(.trailing, 16)
        .frame(minHeight: 58)
        .osaGlass(Osa.radiusM)
        .overlay {
            if alert.displayTone != .info {
                RoundedRectangle(cornerRadius: Osa.radiusM, style: .continuous).strokeBorder(color.opacity(0.55))
            }
        }
        .accessibilityElement(children: .combine)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// Compteur de vitesse + panneau de limitation (au-dessus de la barre du bas).
struct GuidanceSpeed: View {
    private let g = GuidanceState.shared

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(spacing: 1) {
                Text(g.speedKmh.map(String.init) ?? "–")
                    .font(.osa(25, .heavy))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("km/h").font(.osa(10, .bold)).foregroundStyle(g.speeding ? .white.opacity(0.85) : Osa.dim)
            }
            .foregroundStyle(Osa.text)
            .frame(width: 66, height: 66)
            .background {
                if g.speeding { Circle().fill(Osa.jam) } else { Circle().fill(.ultraThinMaterial).overlay(Circle().fill(Osa.bg.opacity(0.72))) }
            }
            .overlay(Circle().strokeBorder(g.speeding ? .clear : Osa.line))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            .animation(.easeOut(duration: 0.2), value: g.speeding)

            if let limit = g.limitKmh {
                Text("\(limit)")
                    .font(.osa(limit >= 100 ? 16 : 20, .heavy))
                    .monospacedDigit()
                    .foregroundStyle(.black)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(.white))
                    .overlay(Circle().strokeBorder(Osa.jam, lineWidth: 5))
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                    .accessibilityLabel("Limitation \(limit) km/h")
            }
        }
        .animation(Osa.anim, value: g.limitKmh)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Vitesse \(g.speedKmh ?? 0) km/h")
    }
}
