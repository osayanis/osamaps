import SwiftUI

/// Bouton rond « Signaler » (rail). Plus grand (64 pt) et blanc en conduite.
struct ReportsButton: View {
    @Environment(Core.self) private var core

    var body: some View {
        let drive = core.mode == .drive
        let open = core.panel == ReportsPanels.panel
        Button {
            Haptic.play("light")
            if open { ReportsPanels.closeOwn() } else { ReportsPanels.openOwn(ReportsPanels.panel) }
        } label: {
            Image(systemName: "flag.fill")
                .font(.system(size: drive ? 26 : 19, weight: .bold))
        }
        .buttonStyle(OsaRoundStyle(size: drive ? 64 : 48, prominent: drive || open))
        .accessibilityLabel("Signaler")
    }
}

/// Fond du panneau du bas : verre sombre, coins hauts arrondis, jusqu'en bas de l'écran.
private struct ReportsSheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                UnevenRoundedRectangle(topLeadingRadius: Osa.radiusL, topTrailingRadius: Osa.radiusL, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: Osa.radiusL, topTrailingRadius: Osa.radiusL, style: .continuous).fill(Osa.bg.opacity(0.78)))
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: Osa.radiusL, topTrailingRadius: Osa.radiusL, style: .continuous).strokeBorder(Osa.line))
                    .shadow(color: .black.opacity(0.45), radius: 20, y: -4)
                    .ignoresSafeArea(edges: .bottom)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct ReportsCloseButton: View {
    var body: some View {
        Button { ReportsPanels.closeOwn() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Osa.dim)
                .frame(width: 40, height: 40)
                .background(Osa.surfaceHi, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(ReportsPressStyle())
        .accessibilityLabel("Fermer")
    }
}

/// Léger enfoncement au toucher (140 ms, ease-out).
struct ReportsPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// Grosse pilule (≥ 56 pt), pour les actions en conduite.
private struct ReportsBigPill: View {
    var title: String
    var symbol: String?
    var secondary = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 17, weight: .heavy)) }
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(OsaPillStyle(secondary: secondary))
        .frame(minHeight: 56)
    }
}

/// Panneau du bas : « Signaler » (tuiles) ou fiche d'un signalement.
struct ReportsSheet: View {
    @Environment(Core.self) private var core

    var body: some View {
        Group {
            if core.panel == ReportsPanels.panel {
                ReportsPanelView().modifier(ReportsSheetBackground())
            } else if core.panel == ReportsPanels.detail {
                ReportsDetailView(id: (core.panelData as? ReportsPanels.Data)?.id ?? "")
                    .id(core.panelVersion)
                    .modifier(ReportsSheetBackground())
            }
        }
        .animation(Osa.anim, value: core.panel)
    }
}

/// Touche 1 : bouton Signaler. Touche 2 : une tuile → envoi après 5 s (annulable, précisable).
private struct ReportsPanelView: View {
    @Environment(Core.self) private var core
    private var store: ReportsStore { .shared }

    var body: some View {
        let drive = core.mode == .drive
        if let p = store.pending {
            pendingView(p)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Signaler").font(.osa(20, .heavy)).foregroundStyle(Osa.text)
                    Spacer()
                    ReportsCloseButton()
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(ReportsKind.allCases) { k in
                        Button { store.pick(k) } label: {
                            tile { ReportsDisc(kind: k, size: drive ? 50 : 46) } label: { Text(k.label) }
                        }
                        .buttonStyle(ReportsPressStyle())
                        .accessibilityLabel("Signaler : \(k.label)")
                    }
                    Button { ReportsPanels.closeOwn() } label: {
                        tile {
                            Image(systemName: "xmark").font(.system(size: 19, weight: .bold))
                                .foregroundStyle(Osa.dim)
                                .frame(width: drive ? 50 : 46, height: drive ? 50 : 46)
                                .background(Osa.surfaceHi, in: Circle())
                        } label: { Text("Fermer").foregroundStyle(Osa.dim) }
                    }
                    .buttonStyle(ReportsPressStyle())
                }
            }
        }
    }

    private func tile<I: View, L: View>(@ViewBuilder _ icon: () -> I, @ViewBuilder label: () -> L) -> some View {
        let drive = core.mode == .drive
        return VStack(spacing: 8) {
            icon()
            label()
                .font(.osa(drive ? 14 : 13, .semibold))
                .foregroundStyle(Osa.text)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: drive ? 112 : 100)
        .padding(.horizontal, 2)
        .osaCard()
        .contentShape(RoundedRectangle(cornerRadius: Osa.radiusM))
    }

    private func pendingView(_ p: ReportsStore.Pending) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ReportsDisc(kind: p.kind, sub: p.sub, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.kind.title(sub: p.sub)).font(.osa(19, .heavy)).foregroundStyle(Osa.text)
                    Text("Envoi dans quelques secondes…").font(.osa(14, .medium)).foregroundStyle(Osa.dim)
                }
                Spacer(minLength: 0)
            }
            ReportsCountdown(start: p.at, duration: ReportsStore.undoDelay)
            if !p.kind.subs.isEmpty {
                ReportsFlow(spacing: 8) {
                    ForEach(p.kind.subs) { s in
                        let on = p.sub == s.id
                        Button { store.toggleSub(s.id) } label: {
                            Text(s.label)
                                .font(.osa(15, .semibold))
                                .foregroundStyle(on ? .black : Osa.text)
                                .padding(.horizontal, 18)
                                .frame(minHeight: 48)
                                .background(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Osa.surface), in: Capsule())
                                .overlay(Capsule().strokeBorder(on ? Color.clear : Osa.lineHi))
                        }
                        .buttonStyle(ReportsPressStyle())
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .accessibilityLabel("Préciser (facultatif)")
            }
            HStack(spacing: 10) {
                ReportsBigPill(title: "Annuler", secondary: true) { store.cancelPending() }
                ReportsBigPill(title: "Envoyer") { store.sendPending() }
            }
        }
    }
}

/// Barre de compte à rebours (se vide en `duration`).
private struct ReportsCountdown: View {
    var start: Date
    var duration: TimeInterval
    var body: some View {
        TimelineView(.animation) { ctx in
            let f = max(0, min(1, 1 - ctx.date.timeIntervalSince(start) / duration))
            GeometryReader { g in
                Capsule().fill(Osa.surfaceHi)
                    .overlay(alignment: .leading) { Capsule().fill(Osa.text).frame(width: g.size.width * f) }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// Fiche d'un signalement (toucher sur un marqueur) : votes « toujours là / plus là ».
private struct ReportsDetailView: View {
    let id: String
    @Environment(Core.self) private var core
    private var store: ReportsStore { .shared }

    var body: some View {
        if let r = store.items[id] {
            content(r)
        } else {
            HStack {
                Text("Ce signalement n'existe plus").font(.osa(20, .heavy)).foregroundStyle(Osa.text)
                Spacer()
                ReportsCloseButton()
            }
        }
    }

    private func content(_ r: Report) -> some View {
        let mine = store.mine[r.id] != nil
        let voted = store.voted[r.id] != nil
        let who = mine ? "par toi" : (r.by?.isEmpty == false ? "par \(r.by!)" : "par un membre Osa")
        let agoText = Reports.ago(r.createdAt)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ReportsDisc(kind: r.type, sub: r.sub, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).font(.osa(20, .heavy)).foregroundStyle(Osa.text)
                    Text("\(agoText.prefix(1).uppercased() + agoText.dropFirst()) · \(who)")
                        .font(.osa(14, .medium)).foregroundStyle(Osa.dim)
                }
                Spacer(minLength: 0)
                ReportsCloseButton()
            }
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                HStack(spacing: 8) {
                    stat("\(r.confirmations)", r.confirmations > 1 ? "confirmations" : "confirmation")
                    if let p = core.position {
                        stat(Geo.formatDistance(Geo.distance(p.coordinate, r.coordinate)), "de toi")
                    }
                    stat(Geo.formatDuration(max(60, (r.expiresAt - Reports.nowMs) / 1000)), "encore visible")
                }
            }
            if mine {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tu l'as signalé. C'est fini ?").font(.osa(15, .medium)).foregroundStyle(Osa.dim)
                    ReportsBigPill(title: "Plus là, retirer", secondary: true) {
                        Task { await store.vote(r.id, .gone) }
                        ReportsPanels.closeOwn()
                    }
                }
            } else if voted {
                Label("Merci, c'est noté", systemImage: "checkmark")
                    .font(.osa(15, .semibold)).foregroundStyle(Osa.dim)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                HStack(spacing: 10) {
                    ReportsBigPill(title: "Toujours là", symbol: "checkmark") { Task { await store.vote(r.id, .still) } }
                    ReportsBigPill(title: "Plus là", symbol: "xmark", secondary: true) { Task { await store.vote(r.id, .gone) } }
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.osa(17, .heavy)).foregroundStyle(Osa.text).monospacedDigit()
            Text(label).font(.osa(12, .medium)).foregroundStyle(Osa.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .osaCard(Osa.radiusS + 2)
    }
}

/// « Toujours là ? » en conduite (slot hud) : gros boutons Oui / Non, disparaît tout seul (9 s).
struct ReportsAskCard: View {
    private var store: ReportsStore { .shared }

    var body: some View {
        if let ask = store.ask, let r = store.items[ask.id] {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ReportsDisc(kind: r.type, sub: r.sub, size: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).font(.osa(17, .heavy)).foregroundStyle(Osa.text)
                        Text("Toujours là ?").font(.osa(15, .medium)).foregroundStyle(Osa.dim)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    ReportsBigPill(title: "Oui", symbol: "checkmark") { Task { await store.vote(r.id, .still) } }
                    ReportsBigPill(title: "Non", symbol: "xmark", secondary: true) { Task { await store.vote(r.id, .gone) } }
                }
                ReportsCountdown(start: ask.at, duration: ReportsStore.askDuration).frame(height: 3)
            }
            .padding(14)
            .osaGlass(Osa.radiusM + 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(r.title). Toujours là ?")
        }
    }
}

/// Réglages : types d'alertes reçues en conduite + « Toujours là ? ».
struct ReportsSettingsSection: View {
    @Bindable private var store = ReportsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Signalements").font(.osa(17, .heavy)).foregroundStyle(Osa.text)
            Text("Les alertes que tu reçois en conduite, quand un signalement est devant toi.")
                .font(.osa(14, .medium)).foregroundStyle(Osa.dim)
            VStack(spacing: 0) {
                ForEach(ReportsKind.allCases) { k in
                    Toggle(isOn: Binding(
                        get: { store.settings.alert(k) },
                        set: { store.settings.alerts[k.rawValue] = $0 })) {
                        HStack(spacing: 12) {
                            ReportsDisc(kind: k, size: 30)
                            Text(k.label).font(.osa(16, .semibold)).foregroundStyle(Osa.text)
                        }
                    }
                    .frame(minHeight: 48)
                    Divider().overlay(Osa.line)
                }
                Toggle(isOn: $store.settings.ask) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Demander « Toujours là ? »").font(.osa(16, .semibold)).foregroundStyle(Osa.text)
                        Text("En passant à côté d'un signalement").font(.osa(13, .medium)).foregroundStyle(Osa.dim)
                    }
                }
                .frame(minHeight: 56)
            }
            .tint(Osa.ok)
        }
        .padding(16)
        .osaCard()
    }
}

/// Mise en ligne qui passe à la ligne (puces de précision).
struct ReportsFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let h = rows.map(\.h).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let w = rows.map(\.w).max() ?? 0
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.h + spacing
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(items: [Int], w: CGFloat, h: CGFloat)] {
        var rows: [(items: [Int], w: CGFloat, h: CGFloat)] = []
        var cur: (items: [Int], w: CGFloat, h: CGFloat) = ([], 0, 0)
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let add = cur.items.isEmpty ? s.width : cur.w + spacing + s.width
            if add > width && !cur.items.isEmpty {
                rows.append(cur)
                cur = ([i], s.width, s.height)
            } else {
                cur.items.append(i); cur.w = add; cur.h = max(cur.h, s.height)
            }
        }
        if !cur.items.isEmpty { rows.append(cur) }
        return rows
    }
}
