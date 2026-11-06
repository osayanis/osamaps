import SwiftUI

/// Slot `.top` : la barre « Où allez-vous ? » (ouvre la recherche plein écran), les puces « autour de moi »
/// et, en mode « choisir sur la carte », le bandeau d'aide.
struct SearchBarView: View {
    @Environment(Core.self) private var core
    @State private var search = SearchState.shared

    var body: some View {
        VStack(spacing: 10) {
            if search.pickOnMap, let pick = search.picking {
                pickBanner(pick)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                bar
                if showChips {
                    chips.transition(.opacity)
                }
            }
        }
        .opacity(search.focused ? 0 : 1)
        .animation(Osa.anim, value: search.pickOnMap)
        .animation(Osa.anim, value: showChips)
    }

    private var showChips: Bool {
        !search.focused && (core.panel == nil || core.panel == "search-results")
    }

    private var bar: some View {
        Button {
            Haptic.play("light")
            search.focused = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Osa.dim)
                Text(search.query.isEmpty ? "Où allez-vous ?" : search.query)
                    .font(.osa(17, .semibold))
                    .foregroundStyle(search.query.isEmpty ? Osa.dim : Osa.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 18).padding(.trailing, 14)
            .frame(height: 52)
            .contentShape(Capsule())
        }
        .buttonStyle(SearchToolPress())
        .background {
            Capsule().fill(.ultraThinMaterial).overlay(Capsule().fill(Osa.bg.opacity(0.72)))
        }
        .overlay(Capsule().strokeBorder(Osa.line))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
        .overlay(alignment: .trailing) {
            if !search.query.isEmpty {
                Button {
                    search.clearQuery()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Osa.faint)
                        .frame(width: 44, height: 44)
                }
                .padding(.trailing, 4)
                .accessibilityLabel("Effacer")
            }
        }
        .accessibilityLabel("Rechercher un lieu ou une adresse")
    }

    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SearchCategory.visible) { c in
                        let on = search.category?.id == c.id
                        Button {
                            withAnimation(Osa.anim) { proxy.scrollTo(c.id, anchor: .center) }
                            if on { search.closeCategory() } else { search.runCategory(c.id) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: c.symbol).font(.system(size: 13, weight: .semibold))
                                Text(c.label).font(.osa(14, .semibold))
                            }
                            .foregroundStyle(on ? Color.black : Osa.text)
                            .padding(.horizontal, 14)
                            .frame(height: 38)
                            .background {
                                if on {
                                    Capsule().fill(Color.white)
                                } else {
                                    Capsule().fill(.ultraThinMaterial).overlay(Capsule().fill(Osa.bg.opacity(0.7)))
                                }
                            }
                            .overlay(Capsule().strokeBorder(on ? Color.clear : Osa.line))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(SearchToolPress())
                        .id(c.id)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
        .padding(.horizontal, -12)
        .contentMargins(.horizontal, 12, for: .scrollContent)
    }

    private func pickBanner(_ pick: SearchPick) -> some View {
        HStack(spacing: 12) {
            SearchBadge(symbol: pick.symbol, size: 36, prominent: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(pick.placeholder).font(.osa(15, .bold)).foregroundStyle(Osa.text)
                Text("Appui long sur la carte pour choisir l'endroit")
                    .font(.osa(13, .medium)).foregroundStyle(Osa.dim)
            }
            Spacer(minLength: 4)
            Button("Annuler") { search.cancelPicking() }
                .font(.osa(14, .semibold))
                .foregroundStyle(Osa.text)
                .padding(.horizontal, 12).frame(height: 36)
                .background(Osa.surfaceHi, in: Capsule())
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .osaGlass(Osa.radiusL)
    }
}
