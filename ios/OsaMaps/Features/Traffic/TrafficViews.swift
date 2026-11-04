import SwiftUI

// MARK: - Icône feu tricolore

/// Feu tricolore au trait (le SDK n'a pas de symbole équivalent) : boîtier arrondi + 3 feux.
struct TrafficLightIcon: View {
    var size: CGFloat = 22
    var body: some View {
        Canvas { ctx, s in
            let k = s.width / 24
            let box = Path(roundedRect: CGRect(x: 7 * k, y: 2.5 * k, width: 10 * k, height: 19 * k), cornerRadius: 3 * k)
            ctx.stroke(box, with: .foreground, style: StrokeStyle(lineWidth: 2 * k, lineCap: .round, lineJoin: .round))
            for y in [7.5, 12.0, 16.5] {
                let r = 1.6 * k
                ctx.fill(Path(ellipseIn: CGRect(x: 12 * k - r, y: y * k - r, width: 2 * r, height: 2 * r)), with: .foreground)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Rail : afficher / masquer

struct TrafficRailButton: View {
    @State private var store = TrafficStore.shared
    var body: some View {
        Button {
            Haptic.play("light")
            store.visible.toggle()
        } label: {
            TrafficLightIcon()
        }
        .buttonStyle(OsaRoundStyle(prominent: store.visible))
        .accessibilityLabel(store.visible ? "Masquer le trafic" : "Afficher le trafic")
        .accessibilityAddTraits(store.visible ? .isSelected : [])
    }
}

// MARK: - HUD de conduite : « +8 min de trafic »

/// Seulement s'il y a un vrai retard (≥ 1 min). Complète l'ETA des autres modules, ne la remplace pas.
struct TrafficDelayHUD: View {
    @State private var store = TrafficStore.shared
    var body: some View {
        if let ahead = store.ahead, ahead.delay >= 60 {
            let min = Int((ahead.delay / 60).rounded())
            let level: TrafficLevel = ahead.next?.level == .jam ? .jam : .slow
            HStack(spacing: 10) {
                Circle().fill(level.color).frame(width: 10, height: 10)
                Text("+\(min) min de trafic")
                    .font(.osa(15, .bold))
                    .foregroundStyle(Osa.text)
                if let next = ahead.next, let d = ahead.nextDistance, d > 50 {
                    Text("\(next.level == .jam ? "bouchon" : "ralenti") dans \(Geo.formatDistance(d))")
                        .font(.osa(14, .semibold))
                        .foregroundStyle(Osa.dim)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .osaGlass(999)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

// MARK: - Fiche : évènement officiel ou tronçon touché

struct TrafficSheet: View {
    @Environment(Core.self) private var core

    var body: some View {
        let _ = core.panelVersion
        Group {
            if core.panel == "traffic-event", let e = core.panelData as? TrafficEventProps {
                eventCard(e)
            } else if core.panel == "traffic-segment", let s = core.panelData as? TrafficSegmentProps {
                segmentCard(s)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func close() { core.openPanel(nil) }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .osaGlass()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
    }

    private func header(icon: some View, tone: Color, title: String, subtitle: String?) -> some View {
        HStack(spacing: 12) {
            icon
                .foregroundStyle(tone)
                .frame(width: 44, height: 44)
                .background(Osa.surfaceHi, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.osa(17, .bold)).foregroundStyle(Osa.text)
                if let subtitle { Text(subtitle).font(.osa(14, .semibold)).foregroundStyle(Osa.dim) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Fermer", action: close)
                .font(.osa(15, .semibold))
                .foregroundStyle(Osa.dim)
                .frame(minHeight: 44)
        }
    }

    private func eventCard(_ e: TrafficEventProps) -> some View {
        card {
            header(icon: Image(systemName: Self.symbol(e.eventKind)).font(.system(size: 19, weight: .bold)),
                   tone: e.eventKind.tone, title: e.title, subtitle: e.road)
            if let w = e.where { Text(w).font(.osa(14, .medium)).foregroundStyle(Osa.text) }
            if let d = e.description { Text(d).font(.osa(14, .medium)).foregroundStyle(Osa.dim) }
            HStack(spacing: 14) {
                if let u = Self.until(e.end) { Text(u) }
                Text("Bison Futé" + (e.source.map { " · \($0)" } ?? ""))
            }
            .font(.osa(12, .semibold))
            .foregroundStyle(Osa.faint)
        }
        .accessibilityElement(children: .contain)
    }

    private func segmentCard(_ s: TrafficSegmentProps) -> some View {
        let level = s.trafficLevel
        var sub = s.usual.map { "Habituellement \(Int($0)) km/h" } ?? "Vitesse habituelle encore inconnue"
        if let r = s.road { sub += " · \(r)" }
        let n = s.n ?? 0
        let source = s.src == "dir"
            ? "Mesure d'une station Bison Futé / DIR"
            : "Contributions anonymes OsaMaps" + (n > 0 ? " (\(n) véhicule\(n > 1 ? "s" : ""))" : "")
        return card {
            header(icon: Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 19, weight: .bold)),
                   tone: level.color, title: "\(level.label) · \(Int(s.speed)) km/h", subtitle: sub)
            Text(source).font(.osa(12, .semibold)).foregroundStyle(Osa.faint)
        }
    }

    static func symbol(_ k: TrafficEventKind) -> String {
        UIImage(systemName: k.symbol) != nil ? k.symbol : "exclamationmark"
    }

    /// « Jusqu'à 18:30 » / « Jusqu'au 12 novembre à 18:30 ».
    static func until(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        let fr = Locale(identifier: "fr_FR")
        let time = d.formatted(Date.FormatStyle(locale: fr).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if Calendar.current.isDateInToday(d) { return "Jusqu'à \(time)" }
        let day = d.formatted(Date.FormatStyle(locale: fr).day().month(.wide))
        return "Jusqu'au \(day) à \(time)"
    }
}

// MARK: - Réglages

/// Interrupteur sobre : piste blanche + pastille noire quand c'est activé (comme la version web).
struct TrafficSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .center, spacing: 16) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                Capsule()
                    .fill(configuration.isOn ? Osa.text : Osa.surfaceHi)
                    .overlay(Capsule().strokeBorder(configuration.isOn ? .clear : Osa.lineHi))
                    .frame(width: 52, height: 32)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(configuration.isOn ? Color.black : Osa.dim).frame(width: 24, height: 24).padding(4)
                    }
                    .animation(Osa.anim, value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

struct TrafficSettingsSection: View {
    @Environment(Prefs.self) private var prefs
    @State private var store = TrafficStore.shared
    @State private var detailsOpen = false

    var body: some View {
        @Bindable var prefs = prefs
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 14) {
            Text("Trafic en direct").font(.osa(17, .bold)).foregroundStyle(Osa.text)

            Toggle(isOn: $store.visible) {
                row("Afficher le trafic",
                    "Vert fluide, orange ralenti, rouge bouchon. Plus les travaux, accidents et fermetures du réseau national.")
            }
            .toggleStyle(TrafficSwitchStyle())

            Toggle(isOn: $prefs.contributeTraffic) {
                row("Contribuer au trafic", "Votre vitesse aide les autres à éviter les bouchons, et inversement.")
            }
            .toggleStyle(TrafficSwitchStyle())

            DisclosureGroup(isExpanded: $detailsOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    bullet("Pendant un trajet, toutes les 5 secondes : un petit bout de trajet (point précédent → point actuel), la vitesse et la direction.")
                    bullet("Aucun compte, aucun identifiant de votre téléphone : juste un code au hasard, changé à chaque trajet.")
                    bullet("Les 300 premiers et les 300 derniers mètres ne partent jamais : votre domicile et vos arrivées restent chez vous.")
                    bullet("Le serveur ne garde que des moyennes par tronçon de route (≈ 60 m), jamais vos trajets. Les détails s'effacent au bout de 15 minutes.")
                    bullet("À pied ou à vélo, rien ne part : il faut avoir dépassé 30 km/h, ou être en navigation.")
                    if prefs.contributeTraffic && store.tripActive {
                        Text("Trajet en cours : \(store.sent) segment\(store.sent > 1 ? "s" : "") envoyé\(store.sent > 1 ? "s" : "").")
                            .font(.osa(13, .semibold)).foregroundStyle(Osa.text)
                    }
                }
                .padding(.top, 10)
            } label: {
                Text("Ce qui est envoyé, exactement").font(.osa(14, .semibold)).foregroundStyle(Osa.dim)
            }
            .tint(Osa.dim)

            Text("Sources : contributions OsaMaps et Bison Futé / Directions interdépartementales des routes (mesures et évènements, Licence Ouverte). Tant qu'il y a peu d'utilisateurs, la carte reste souvent vide hors grands axes : c'est normal, rien n'est inventé.")
                .font(.osa(12, .medium)).foregroundStyle(Osa.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .osaCard()
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.osa(15, .semibold)).foregroundStyle(Osa.text)
            Text(detail).font(.osa(13, .regular)).foregroundStyle(Osa.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(Osa.faint)
            Text(s).fixedSize(horizontal: false, vertical: true)
        }
        .font(.osa(13, .regular))
        .foregroundStyle(Osa.dim)
    }
}
