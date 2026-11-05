import SwiftUI
import CoreLocation

/// Panneau "place" : la fiche d'un lieu. Ouvrable par n'importe quel module :
/// `Core.shared.openPanel("place", data: place)` (un `Place` du Core suffit).
struct SearchPlaceSheet: View {
    @Environment(Core.self) private var core

    var body: some View {
        let _ = core.panelVersion
        if let d = SearchPlaceData.from(core.panelData) {
            SearchPlaceCard(place: d)
                .id("\(d.saved.id)|\(d.saved.lat),\(d.saved.lng)|\(core.panelVersion)")
        }
    }
}

private struct SearchPlaceCard: View {
    let place: SearchPlaceData
    @Environment(Core.self) private var core
    @Environment(\.openURL) private var openURL
    @State private var search = SearchState.shared
    @State private var address: SearchGeocoder.Address?
    @State private var addressState: AddrState

    private enum AddrState { case idle, loading, none }

    init(place: SearchPlaceData) {
        self.place = place
        _addressState = State(initialValue: place.needsAddress ? .loading : .idle)
    }

    private var p: SearchSaved { place.saved }
    private var isPoint: Bool { p.name == "Point sur la carte" || p.kind == "map" }
    private var isCar: Bool { p.kind == "car" }
    private var isHome: Bool { p.kind == "home" }
    private var isWork: Bool { p.kind == "work" }

    /// Le lieu complété par l'adresse trouvée (pour l'enregistrer, le partager, y aller).
    private var full: SearchSaved {
        var s = p
        if let a = address {
            if isPoint { s.name = a.name; s.detail = s.detail ?? (a.detail.isEmpty ? nil : a.detail) }
            else if s.detail == nil { s.detail = [a.name, a.detail].filter { !$0.isEmpty }.joined(separator: ", ") }
        }
        return s
    }

    private var label: String? {
        if isCar { return "Stationnement" }
        if isHome { return "Maison" }
        if isWork { return "Travail" }
        return p.typeLabel ?? (isPoint ? "Point sur la carte" : nil)
    }

    var body: some View {
        SearchCard(onClose: close) {
            VStack(alignment: .leading, spacing: 14) {
                header
                facts
                actions
            }
        }
        .task(id: "\(p.lat),\(p.lng)") {
            guard place.needsAddress else { return }
            let a = await SearchGeocoder.reverse(p.coordinate)
            guard !Task.isCancelled else { return }
            address = a
            addressState = a == nil ? .none : .idle
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fiche : \(full.name)")
    }

    // MARK: en-tête

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            SearchBadge(symbol: isCar ? "car.fill" : SearchFormat.symbol(p.kind), size: 44)
            VStack(alignment: .leading, spacing: 3) {
                if let label {
                    Text(label.uppercased())
                        .font(.osa(11, .bold)).tracking(0.6)
                        .foregroundStyle(Osa.faint)
                }
                Text(addressState == .loading && isPoint ? "Recherche de l'adresse…" : full.name)
                    .font(.osa(21, .bold))
                    .foregroundStyle(Osa.text)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                if let d = full.detail, !d.isEmpty {
                    Text(d).font(.osa(14, .medium)).foregroundStyle(Osa.dim).lineLimit(2)
                } else if addressState == .none {
                    Text("Adresse inconnue").font(.osa(14, .medium)).foregroundStyle(Osa.dim)
                }
            }
            .animation(Osa.anim, value: addressState == .loading)
            Spacer(minLength: 4)
            Button(action: close) {
                Image(systemName: place.from == .list ? "chevron.left" : "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Osa.text)
                    .frame(width: 34, height: 34)
                    .background(Osa.surfaceHi, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .padding(.top, -5).padding(.trailing, -5)
            .accessibilityLabel(place.from == .list ? "Revenir à la liste" : "Fermer la fiche")
        }
    }

    // MARK: infos

    private var facts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let pos = core.position?.coordinate {
                    let dir = SearchFormat.direction(pos, p.coordinate)
                    SearchFact(symbol: "location.north.fill", text: dir.text, rotation: dir.deg)
                }
                if isCar, let t = p.time {
                    SearchFact(symbol: "clock", text: "Garée \(SearchFormat.ago(t))")
                }
                Button {
                    UIPasteboard.general.string = SearchFormat.coord(p.coordinate)
                    Haptic.play("light")
                    search.toast("Coordonnées copiées", icon: "doc.on.doc", tone: .good)
                } label: {
                    SearchFact(symbol: "doc.on.doc", text: SearchFormat.coord(p.coordinate))
                }
                .buttonStyle(SearchToolPress())
                .accessibilityLabel("Copier les coordonnées")
            }
        }
        .scrollClipDisabled()
    }

    // MARK: actions

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                search.goTo(full)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCar ? "figure.walk" : "arrow.triangle.turn.up.right.diamond.fill")
                    Text(isCar ? "Retrouver ma voiture" : "Y aller")
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 30)
            }
            .buttonStyle(.osaPill)

            HStack(spacing: 8) {
                if !isCar {
                    let fav = search.isFavorite(p.coordinate)
                    Button {
                        let now = search.toggleFavorite(full)
                        Haptic.play(now ? "success" : "light")
                        search.toast(now ? "Ajouté aux favoris" : "Retiré des favoris", icon: now ? "star.fill" : "star.slash",
                                     tone: now ? .good : .info)
                    } label: {
                        SearchToolLabel(symbol: fav ? "star.fill" : "star", title: fav ? "Enregistré" : "Favori", on: fav)
                    }
                    .buttonStyle(SearchToolPress())
                    .accessibilityAddTraits(fav ? .isSelected : [])
                }

                ShareLink(item: SearchShare.webURL(full), subject: Text(full.name), message: Text(SearchShare.message(full))) {
                    SearchToolLabel(symbol: "square.and.arrow.up", title: "Partager")
                }
                .buttonStyle(SearchToolPress())

                if let phone = p.phone, let url = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) {
                    Button { openURL(url) } label: { SearchToolLabel(symbol: "phone.fill", title: "Appeler") }
                        .buttonStyle(SearchToolPress())
                        .accessibilityLabel("Appeler \(phone)")
                }

                Menu {
                    Button { SearchShare.openInAppleMaps(full) } label: { Label("Plans", systemImage: "map.fill") }
                    Button { openURL(SearchShare.waze(full)) } label: { Label("Waze", systemImage: "arrow.up.right.square") }
                    Button { openURL(SearchShare.google(full)) } label: { Label("Google Maps", systemImage: "arrow.up.right.square") }
                } label: {
                    SearchToolLabel(symbol: "arrow.up.right.square", title: "Autre GPS")
                }
                .menuOrder(.fixed)

                if isCar {
                    Button {
                        search.forgetCar()
                        core.openPanel(nil)
                        search.toast("Stationnement oublié", icon: "car.fill")
                    } label: { SearchToolLabel(symbol: "trash", title: "Oublier") }
                        .buttonStyle(SearchToolPress())
                } else {
                    Menu {
                        moreMenu
                    } label: {
                        SearchToolLabel(symbol: "ellipsis", title: "Plus")
                    }
                    .menuOrder(.fixed)
                }
            }
        }
    }

    @ViewBuilder private var moreMenu: some View {
        if !isHome {
            Button {
                let had = search.home != nil
                search.setShortcut(.home, full)
                Haptic.play("success")
                search.toast(had ? "Maison mise à jour" : "Maison enregistrée", icon: "house.fill", tone: .good)
            } label: {
                Label(search.home != nil ? "Remplacer l'adresse de la maison" : "Définir comme Maison", systemImage: "house.fill")
            }
        }
        if !isWork {
            Button {
                let had = search.work != nil
                search.setShortcut(.work, full)
                Haptic.play("success")
                search.toast(had ? "Travail mis à jour" : "Travail enregistré", icon: "briefcase.fill", tone: .good)
            } label: {
                Label(search.work != nil ? "Remplacer l'adresse du travail" : "Définir comme Travail", systemImage: "briefcase.fill")
            }
        }
        if core.route != nil {
            Button {
                emit(.routeAddStop(full.place))
                core.openPanel(nil)
            } label: { Label("Ajouter comme étape", systemImage: "plus.circle") }
        }
        Button {
            UIPasteboard.general.url = SearchShare.webURL(full)
            search.toast("Lien copié", icon: "doc.on.doc", tone: .good)
        } label: { Label("Copier le lien", systemImage: "link") }
        if let s = p.url, let url = URL(string: s) {
            Button { openURL(url) } label: { Label("Site web", systemImage: "safari.fill") }
        }
    }

    private func close() {
        if place.from == .list, search.category != nil {
            core.openPanel("search-results")
        } else {
            core.openPanel(nil)
            if place.from != .list { search.closeCategory() }
        }
    }
}
