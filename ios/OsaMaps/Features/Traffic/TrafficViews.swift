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
    private var core: Core { Core.shared }

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
        let kind = e.eventKind
        let subtitle = [e.road, e.direction].compactMap { $0 }.joined(separator: " · ")
        return card {
            header(icon: Image(systemName: Self.symbol(kind)).font(.system(size: 19, weight: .bold)),
                   tone: kind.tone, title: e.title, subtitle: subtitle.isEmpty ? kind.label : subtitle)
            if let d = e.description { Text(d).font(.osa(14, .medium)).foregroundStyle(Osa.text).fixedSize(horizontal: false, vertical: true) }
            // faits clés en pilules sobres : voies, retard, vitesse, fin
            let facts = Self.facts(e)
            if !facts.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(facts, id: \.self) { f in
                        Text(f).font(.osa(12, .semibold)).foregroundStyle(Osa.text)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Osa.surfaceHi, in: Capsule())
                    }
                }
            }
            if let o = e.original, !o.isEmpty {
                DisclosureGroup {
                    Text(o).font(.osa(13, .regular)).foregroundStyle(Osa.dim).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                } label: {
                    Text(Self.originalLabel(e.lang)).font(.osa(13, .semibold)).foregroundStyle(Osa.dim)
                }
                .tint(Osa.dim)
            }
            sourcesRow(e)
        }
        .accessibilityElement(children: .contain)
    }

    /// « Sources : Bison Futé, Autobahn · confiance élevée » + jauge 3 crans.
    private func sourcesRow(_ e: TrafficEventProps) -> some View {
        let names = (e.sources ?? []).map(\.name)
        let c = e.confidence ?? 0.5
        let steps = c >= 0.85 ? 3 : c >= 0.6 ? 2 : 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule().fill(i < steps ? Osa.text : Osa.surfaceHi).frame(width: 14, height: 5)
                    }
                }
                Text("Confiance \(e.confidenceLabel)" + (names.count > 1 ? " · \(names.count) sources concordantes" : ""))
                    .font(.osa(12, .semibold)).foregroundStyle(Osa.dim)
            }
            .accessibilityElement(children: .combine)
            Text(names.isEmpty ? "Source inconnue" : names.joined(separator: " · "))
                .font(.osa(12, .semibold)).foregroundStyle(Osa.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func facts(_ e: TrafficEventProps) -> [String] {
        var out: [String] = []
        if let l = e.lanes, l != e.title { out.append(l) }
        if let d = e.delay ?? e.relatedJam?.delay, d >= 60 { out.append("~\(Int((d / 60).rounded())) min de retard") }
        if let v = e.speed, e.eventKind == .jam { out.append("\(Int(v)) km/h") }
        if e.relatedJam != nil, e.eventKind != .jam { out.append("Bouchon lié") }
        if let u = until(e.end) { out.append(u) } else if let s = since(e.start), [.accident, .danger, .jam].contains(e.eventKind) { out.append(s) }
        return out
    }

    static func originalLabel(_ lang: String?) -> String {
        switch lang {
        case "de": "Message d'origine (allemand)"
        case "nl": "Message d'origine (néerlandais)"
        case "es": "Message d'origine (espagnol)"
        case "ca": "Message d'origine (catalan)"
        default: "Détails de la source"
        }
    }

    /// « Depuis 14:32 » / « Depuis le 3 novembre ».
    static func since(_ iso: String?) -> String? {
        guard let d = parseDate(iso) else { return nil }
        let fr = Locale(identifier: "fr_FR")
        if Calendar.current.isDateInToday(d) {
            return "Depuis \(d.formatted(Date.FormatStyle(locale: fr).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))"
        }
        return "Depuis le \(d.formatted(Date.FormatStyle(locale: fr).day().month(.wide)))"
    }

    static func parseDate(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
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
        guard let d = parseDate(iso) else { return nil }
        let fr = Locale(identifier: "fr_FR")
        let time = d.formatted(Date.FormatStyle(locale: fr).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if Calendar.current.isDateInToday(d) { return "Jusqu'à \(time)" }
        let day = d.formatted(Date.FormatStyle(locale: fr).day().month(.wide))
        return "Jusqu'au \(day) à \(time)"
    }
}

// MARK: - Rangée qui passe à la ligne (pilules)

struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, w: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); w = max(w, x - spacing)
        }
        return CGSize(width: min(w, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
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
    @State private var prefs = Prefs.shared
    @State private var store = TrafficStore.shared
    @State private var detailsOpen = false

    var body: some View {
        @Bindable var prefs = prefs
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 14) {
            Text("Trafic en direct").font(.osa(17, .bold)).foregroundStyle(Osa.text)

            Toggle(isOn: $store.visible) {
                row("Afficher le trafic",
                    "Vert fluide, orange ralenti, rouge bouchon. Plus les accidents, fermetures, travaux, vigilances météo et ruptures de carburant, recoupés entre plusieurs sources.")
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

            Text("Sources : contributions OsaMaps ; Bison Futé / DIR ; DiaLog ; open data des villes et départements (Paris, Lyon, Rennes, Bordeaux, Toulouse, Lille, Tours, Angers, Loire-Atlantique, Côtes-d'Armor, Mayenne, Sarthe) ; Météo-France via MeteoAlarm ; prix-carburants ; ONISR (accidents 3 dernières années) ; Autobahn GmbH, NDW, DGT, Servei Català de Trànsit, CITA. Données ouvertes, citées dans chaque fiche. Rien n'est inventé : sans source, rien ne s'affiche.")
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
