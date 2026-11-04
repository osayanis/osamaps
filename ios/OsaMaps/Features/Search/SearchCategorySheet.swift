import SwiftUI
import CoreLocation

/// Panneau "search-results" : les lieux d'une catégorie autour de soi (ou de la zone regardée).
struct SearchCategorySheet: View {
    @Environment(Core.self) private var core
    @State private var search = SearchState.shared

    var body: some View {
        if let state = search.category, let cat = state.category {
            SearchCard(onClose: { search.closeCategory() }) {
                VStack(alignment: .leading, spacing: 10) {
                    header(cat, state)
                    if moved(state), !state.loading {
                        Button {
                            search.runCategory(cat.id, center: search.mapCenter ?? state.center)
                        } label: {
                            Label("Rechercher dans cette zone", systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.osaPillSecondary)
                        .transition(.opacity)
                    }
                    content(cat, state)
                }
                .animation(Osa.anim, value: state.loading)
            }
        }
    }

    private func header(_ cat: SearchCategory, _ s: SearchCategoryState) -> some View {
        HStack(spacing: 12) {
            SearchBadge(symbol: cat.symbol, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(cat.label).font(.osa(21, .bold)).foregroundStyle(Osa.text)
                Text(s.loading ? "Recherche autour…"
                     : s.error == "network" ? "Service indisponible"
                     : s.results.isEmpty ? "Rien à proximité"
                     : "\(s.results.count) à proximité")
                    .font(.osa(14, .medium)).foregroundStyle(Osa.dim)
                    .contentTransition(.opacity)
            }
            Spacer()
            Button { search.closeCategory() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Osa.text)
                    .frame(width: 34, height: 34)
                    .background(Osa.surfaceHi, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Fermer la liste")
        }
    }

    @ViewBuilder
    private func content(_ cat: SearchCategory, _ s: SearchCategoryState) -> some View {
        if s.loading {
            SearchSkeleton(rows: 4)
        } else if s.error == "network" {
            HStack {
                SearchHint(text: "La recherche autour de vous ne répond pas.", warn: true)
                Button("Réessayer") { search.runCategory(cat.id, center: s.center) }
                    .font(.osa(14, .semibold)).foregroundStyle(Osa.text)
            }
        } else if s.error == "empty" {
            SearchHint(text: "Aucun résultat « \(cat.label.lowercased()) » dans un rayon de \(Int(cat.maxKm)) km.")
        } else {
            let ref = core.position?.coordinate ?? s.center
            SearchFitScroll(maxHeight: 300) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(s.results.enumerated()), id: \.element.id) { i, r in
                        SearchRow(symbol: cat.symbol, title: r.name, subtitle: r.detail.isEmpty ? r.typeLabel : r.detail,
                                  meta: SearchFormat.distanceLabel(ref, r.coordinate), number: i + 1) {
                            search.openPlace(SearchPlaceData(saved: r.saved, from: .list, needsAddress: r.detail.isEmpty))
                        }
                    }
                }
            }
        }
    }

    /// La carte a été déplacée loin du centre de recherche.
    private func moved(_ s: SearchCategoryState) -> Bool {
        guard let c = search.mapCenter else { return false }
        return Geo.distance(c, s.center) > max(800, search.mapSpan * 0.35)
    }
}
