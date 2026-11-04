import SwiftUI
import CoreLocation

/// Slot `.sheet` du module : un seul occupant qui affiche l'accueil, la fiche lieu ou la liste par catégorie.
struct SearchSheet: View {
    @Environment(Core.self) private var core
    @State private var search = SearchState.shared

    var body: some View {
        Group {
            if core.mode == .browse {
                switch core.panel {
                case nil:
                    if !search.focused && !search.pickOnMap { SearchHomeSheet() }
                case "place":
                    SearchPlaceSheet()
                case "search-results":
                    SearchCategorySheet()
                default:
                    EmptyView()
                }
            }
        }
        .animation(Osa.anim, value: core.panel)
        .animation(Osa.anim, value: search.focused)
    }
}

/// Accueil : suggestion selon l'heure, raccourcis (Maison, Travail, Ma voiture, favoris), récents.
struct SearchHomeSheet: View {
    @Environment(Core.self) private var core
    @State private var search = SearchState.shared
    @State private var now = Date()

    private var pos: CLLocationCoordinate2D? { core.position?.coordinate }

    var body: some View {
        SearchCard(onExpand: { up in
            withAnimation(Osa.anim) { search.expanded = up ?? !search.expanded }
        }) {
            VStack(spacing: 12) {
                if let s = search.suggestion(now: now) { suggestion(s) }
                tiles
                if search.expanded { recents.transition(.opacity.combined(with: .move(edge: .bottom))) }
            }
        }
        .task {
            // l'heure compte pour la suggestion : rafraîchie chaque minute
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = .now
            }
        }
    }

    private func suggestion(_ s: SearchState.Suggestion) -> some View {
        HStack(spacing: 12) {
            Button {
                search.openPlace(SearchPlaceData(saved: s.place, from: .home))
            } label: {
                HStack(spacing: 12) {
                    SearchBadge(symbol: s.symbol, size: 42, prominent: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.osa(16, .bold)).foregroundStyle(Osa.text)
                        Text([SearchFormat.distanceLabel(pos, s.place.coordinate), s.place.detail ?? s.place.name]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.osa(13, .medium)).foregroundStyle(Osa.dim).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SearchToolPress())
            Button("Y aller") { search.goTo(s.place) }
                .buttonStyle(.osaPill)
        }
        .padding(12)
        .osaCard()
    }

    private var tiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let h = search.home {
                    tile("house.fill", "Maison", SearchFormat.distanceLabel(pos, h.coordinate)) { search.goTo(h) }
                        .contextMenu { tileMenu(h, shortcut: .home) }
                } else {
                    tile("house.fill", "Maison", "Définir", empty: true) { search.startPicking(.home) }
                }
                if let w = search.work {
                    tile("briefcase.fill", "Travail", SearchFormat.distanceLabel(pos, w.coordinate)) { search.goTo(w) }
                        .contextMenu { tileMenu(w, shortcut: .work) }
                } else {
                    tile("briefcase.fill", "Travail", "Définir", empty: true) { search.startPicking(.work) }
                }
                if let car = search.car {
                    tile("car.fill", "Ma voiture", car.time.map { SearchFormat.ago($0, now: now) } ?? SearchFormat.distanceLabel(pos, car.coordinate)) {
                        search.openPlace(SearchPlaceData(saved: car, from: .home))
                    }
                } else {
                    tile("car.fill", "Garer ici", "Ma voiture", empty: true) { parkHere() }
                }
                ForEach(search.favorites) { f in
                    tile("star.fill", f.name, SearchFormat.distanceLabel(pos, f.coordinate)) {
                        search.openPlace(SearchPlaceData(saved: f, from: .home))
                    }
                    .contextMenu {
                        Button { search.goTo(f) } label: { Label("Y aller", systemImage: "arrow.triangle.turn.up.right.diamond.fill") }
                        Button(role: .destructive) { search.removeFavorite(f.id) } label: { Label("Retirer des favoris", systemImage: "star.slash") }
                    }
                }
                tile("plus", "Ajouter", "un favori", empty: true) { search.startPicking(.favorite) }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
    }

    @ViewBuilder private func tileMenu(_ p: SearchSaved, shortcut: SearchPick) -> some View {
        Button { search.openPlace(SearchPlaceData(saved: p, from: .home)) } label: { Label("Voir la fiche", systemImage: "info.circle") }
        Button { search.startPicking(shortcut) } label: { Label("Modifier l'adresse", systemImage: "pencil") }
        Button(role: .destructive) { search.setShortcut(shortcut, nil) } label: { Label("Retirer", systemImage: "trash") }
    }

    private func tile(_ symbol: String, _ label: String, _ sub: String?, empty: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(empty ? Osa.dim : Osa.text)
                    .frame(width: 34, height: 34)
                    .background(empty ? Color.clear : Osa.surfaceHi, in: Circle())
                    .overlay(Circle().strokeBorder(empty ? Osa.lineHi : Color.clear, style: StrokeStyle(lineWidth: 1, dash: empty ? [3, 3] : [])))
                Spacer(minLength: 8)
                Text(label)
                    .font(.osa(14, .bold))
                    .foregroundStyle(empty ? Osa.dim : Osa.text)
                    .lineLimit(1)
                Text(sub ?? " ")
                    .font(.osa(12, .medium)).monospacedDigit()
                    .foregroundStyle(Osa.faint)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(width: 104, height: 104, alignment: .leading)
            .osaCard()
            .contentShape(RoundedRectangle(cornerRadius: Osa.radiusM))
        }
        .buttonStyle(SearchToolPress())
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 0) {
            SearchSection(title: "Récents")
            if search.recents.isEmpty {
                SearchHint(text: "Vos dernières destinations apparaîtront ici.")
            }
            SearchFitScroll(maxHeight: 280) {
                VStack(spacing: 0) {
                    ForEach(search.recents.prefix(8)) { r in
                        SearchRow(symbol: "clock", title: r.name, subtitle: r.detail,
                                  meta: SearchFormat.distanceLabel(pos, r.coordinate),
                                  onRemove: { withAnimation(Osa.anim) { search.removeRecent(r.id) } }) {
                            search.openPlace(SearchPlaceData(saved: r, from: .home, needsAddress: r.detail == nil))
                        }
                    }
                }
            }
            Button("Gérer mes lieux") { core.settingsOpen = true }
                .buttonStyle(.osaPillSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
    }

    private func parkHere() {
        guard let pos else {
            search.toast("Position inconnue pour le moment", icon: "location.slash", tone: .warn)
            return
        }
        search.parkCar(pos)
        Haptic.play("success")
        search.toast("Position de la voiture enregistrée", icon: "car.fill", tone: .good)
        Task { @MainActor in
            if let a = await SearchGeocoder.reverse(pos), search.car?.lat == pos.latitude {
                search.car?.detail = [a.name, a.detail].filter { !$0.isEmpty }.joined(separator: ", ")
            }
        }
    }
}
