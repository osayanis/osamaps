import SwiftUI
import MapKit

/// Slot `.overlay` : la recherche plein écran (ouverte en touchant la barre). Au-dessus de la carte et du rail,
/// la barre est à la même place que celle du slot `.top` : l'ouverture ne « saute » pas.
struct SearchOverlay: View {
    @Environment(Core.self) private var core
    @State private var search = SearchState.shared

    var body: some View {
        ZStack {
            if search.focused && core.mode == .browse {
                SearchOverlayContent()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: search.focused)
    }
}

/// Une ligne de la liste (résultat distant, lieu enregistré ou action).
private struct SearchOverlayRow: Identifiable {
    var id: String
    var symbol: String
    var title: String
    var subtitle: String?
    var meta: String?
    var accent = false
    /// Section affichée au-dessus de la ligne.
    var section: String?
    var removable = false
    var run: @MainActor () -> Void
}

private struct SearchOverlayContent: View {
    @Environment(Core.self) private var core
    @State private var search = SearchState.shared
    @FocusState private var fieldFocused: Bool
    @State private var resolving: String?

    var body: some View {
        @Bindable var search = search
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        search.closeSearch()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Osa.text)
                            .frame(width: 36, height: 44)
                    }
                    .accessibilityLabel("Fermer la recherche")
                    TextField("", text: $search.query,
                              prompt: Text(search.picking?.placeholder ?? "Où allez-vous ?").foregroundStyle(Osa.dim))
                        .font(.osa(17, .semibold))
                        .foregroundStyle(Osa.text)
                        .focused($fieldFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { if !query.isEmpty { rows.first?.run() } }
                        .accessibilityLabel("Rechercher un lieu ou une adresse")
                    if search.status == .loading {
                        ProgressView().controlSize(.small).tint(Osa.dim)
                    }
                    if !search.query.isEmpty {
                        Button {
                            search.clearQuery()
                            fieldFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Osa.faint)
                                .frame(width: 36, height: 44)
                        }
                        .accessibilityLabel("Effacer")
                    }
                }
                .padding(.leading, 6).padding(.trailing, 8)
                .frame(height: 52)
                .background(Osa.surfaceHi, in: Capsule())
                .overlay(Capsule().strokeBorder(Osa.lineHi))
                if search.query.isEmpty {
                    Button("Annuler") { search.closeSearch() }
                        .font(.osa(16, .semibold))
                        .foregroundStyle(Osa.text)
                        .padding(.horizontal, 6)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Osa.anim, value: search.query.isEmpty)
            .padding(.horizontal, 12)
            .padding(.top, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let pick = search.picking {
                        HStack(spacing: 10) {
                            Image(systemName: pick.symbol).font(.system(size: 14, weight: .semibold))
                            Text("Cherchez une adresse, ou choisissez l'endroit sur la carte.")
                                .font(.osa(14, .medium))
                        }
                        .foregroundStyle(Osa.dim)
                        .padding(.vertical, 12)
                    }
                    ForEach(rows) { r in
                        if let s = r.section { SearchSection(title: s) }
                        SearchRow(symbol: r.symbol, title: r.title, subtitle: r.subtitle, meta: resolving == r.id ? "…" : r.meta,
                                  accent: r.accent,
                                  onRemove: r.removable ? { search.removeRecent(String(r.id.dropFirst(4))) } : nil,
                                  action: r.run)
                    }
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Osa.bg.opacity(0.9)
            }
            .ignoresSafeArea()
        }
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                fieldFocused = true
            }
        }
        .onChange(of: search.query) { _, _ in search.queryChanged() }
    }

    private var query: String { search.query.trimmingCharacters(in: .whitespaces) }
    private var here: CLLocationCoordinate2D? { core.position?.coordinate }

    @ViewBuilder private var footer: some View {
        let q = query
        if q.isEmpty && rows.isEmpty && search.picking == nil {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .semibold)).foregroundStyle(Osa.faint)
                Text("Cherchez une adresse, un commerce, une ville… ou des coordonnées GPS.")
                    .font(.osa(14, .medium)).foregroundStyle(Osa.dim)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
        if !q.isEmpty && q.count < 3 && SearchText.parseCoords(q) == nil && rows.isEmpty {
            SearchHint(text: "Encore une lettre ou deux…")
        }
        if search.status == .loading && q.count >= 3 && search.results.isEmpty {
            SearchSkeleton()
        }
        if search.status == .done && search.results.isEmpty && search.completions.isEmpty && rows.isEmpty {
            SearchHint(text: "Aucun résultat pour « \(q) ». Vérifiez l'orthographe ou ajoutez la ville.")
        }
        if search.status == .error {
            SearchHint(text: "Recherche indisponible pour le moment. Vérifiez la connexion.", warn: true)
        }
    }

    // MARK: - Lignes

    private var rows: [SearchOverlayRow] {
        let q = query
        let pos = here
        var out: [SearchOverlayRow] = []
        let picking = search.picking

        func saved(_ p: SearchSaved, _ symbol: String, title: String? = nil, sub: String? = nil, direct: Bool = false,
                   section: String? = nil, removable: Bool = false, prefix: String) -> SearchOverlayRow {
            SearchOverlayRow(id: "\(prefix):\(p.id)", symbol: symbol, title: title ?? p.name, subtitle: sub ?? p.detail,
                             meta: SearchFormat.distanceLabel(pos, p.coordinate), section: section, removable: removable) {
                choose(p, direct: direct, recent: removable)
            }
        }

        if q.isEmpty {
            if let picking {
                if let pos {
                    let name = picking == .favorite ? "Position enregistrée" : "Ma position"
                    out.append(SearchOverlayRow(id: "here", symbol: "location.fill", title: "Ma position actuelle",
                                                subtitle: "Utiliser l'endroit où je suis", accent: true) {
                        choose(SearchSaved(id: "here", name: name, coordinate: pos, kind: "address"), direct: false, recent: false)
                    })
                }
                out.append(SearchOverlayRow(id: "map", symbol: "hand.tap.fill", title: "Choisir sur la carte",
                                            subtitle: "Appui long à l'endroit voulu") { search.pickFromMap() })
            } else {
                if let h = search.home { out.append(saved(h, "house.fill", title: "Maison", sub: h.detail ?? h.name, direct: true, prefix: "hom")) }
                if let w = search.work { out.append(saved(w, "briefcase.fill", title: "Travail", sub: w.detail ?? w.name, direct: true, prefix: "wrk")) }
                for (i, f) in search.favorites.prefix(4).enumerated() {
                    out.append(saved(f, "star.fill", section: i == 0 ? "Favoris" : nil, prefix: "fav"))
                }
            }
            for (i, r) in search.recents.prefix(8).enumerated() {
                out.append(saved(r, "clock", section: i == 0 ? "Récents" : nil, removable: true, prefix: "rec"))
            }
            return out
        }

        if let c = SearchText.parseCoords(q) {
            out.append(SearchOverlayRow(id: "coords", symbol: "location.fill.viewfinder", title: SearchFormat.coord(c),
                                        subtitle: "Coordonnées GPS", meta: SearchFormat.distanceLabel(pos, c)) {
                choose(SearchSaved(id: SearchFormat.pointId(c.latitude, c.longitude), name: "Point GPS", coordinate: c, kind: "coords"),
                       direct: false, recent: false)
            })
            return out
        }

        // catégorie évoquée (« boul » → Boulangerie autour de moi)
        if picking == nil, let cat = SearchCategory.matching(q) {
            out.append(SearchOverlayRow(id: "cat:\(cat.id)", symbol: cat.symbol, title: "\(cat.label) autour de moi",
                                        subtitle: "Les plus proches sur la carte", accent: true) {
                search.runCategory(cat.id)
            })
        }

        // lieux enregistrés qui correspondent (en tête, comme « Maison » quand on tape « mai »)
        var local: [SearchOverlayRow] = []
        if let h = search.home, SearchText.loose(q, "maison") || SearchText.loose(q, h.name) {
            local.append(saved(h, "house.fill", title: "Maison", sub: h.detail ?? h.name, direct: picking == nil, prefix: "hom"))
        }
        if let w = search.work, SearchText.loose(q, "travail") || SearchText.loose(q, w.name) {
            local.append(saved(w, "briefcase.fill", title: "Travail", sub: w.detail ?? w.name, direct: picking == nil, prefix: "wrk"))
        }
        for f in search.favorites where SearchText.loose(q, f.name) || SearchText.loose(q, f.detail ?? "") {
            local.append(saved(f, "star.fill", prefix: "fav"))
        }
        for r in search.recents where SearchText.loose(q, r.name) { local.append(saved(r, "clock", prefix: "rcm")) }
        let localTop = Array(local.prefix(3))
        out += localTop
        let localNames = Set(localTop.map { SearchText.norm($0.title) })

        for r in search.results where !localNames.contains(SearchText.norm(r.name)) {
            out.append(SearchOverlayRow(id: r.id, symbol: SearchFormat.symbol(r.kind), title: r.name,
                                        subtitle: [r.typeLabel, r.detail.isEmpty ? nil : r.detail].compactMap { $0 }.joined(separator: " · "),
                                        meta: SearchFormat.distanceLabel(pos, r.coordinate)) {
                chooseResult(r)
            })
        }
        for c in search.completions {
            out.append(SearchOverlayRow(id: c.id, symbol: SearchFormat.symbol(c.kind), title: c.name,
                                        subtitle: c.detail.isEmpty ? nil : c.detail, meta: nil) {
                resolve(c)
            })
        }
        return out
    }

    // MARK: - Choix

    private func choose(_ p: SearchSaved, direct: Bool, recent: Bool) {
        if search.picking != nil { search.completePick(p); return }
        if direct { search.goTo(p); return }
        if !recent { search.addRecent(p) }
        if search.query.isEmpty, !recent { search.query = p.name }
        search.openPlace(SearchPlaceData(saved: p, from: .search, needsAddress: p.detail == nil))
    }

    private func chooseResult(_ r: SearchResult) {
        let s = r.saved
        if search.picking != nil { search.completePick(s); return }
        search.addRecent(s)
        search.openPlace(SearchPlaceData(saved: s, from: .search, needsAddress: r.detail.isEmpty && r.kind != "city"))
    }

    /// Suggestion Apple : on récupère ses coordonnées avant d'ouvrir la fiche.
    private func resolve(_ c: SearchResult) {
        guard let completion = c.completion, resolving == nil else { return }
        resolving = c.id
        Task { @MainActor in
            defer { resolving = nil }
            do {
                if let r = try await SearchEngine.shared.resolve(completion) {
                    chooseResult(r)
                } else {
                    search.toast("Lieu introuvable", icon: "mappin.slash", tone: .warn)
                }
            } catch {
                search.toast("Recherche indisponible pour le moment", icon: "wifi.slash", tone: .warn)
            }
        }
    }
}
