import Foundation
import CoreLocation
import MapKit
import Observation

/// État du module Recherche & lieux (équivalent de `state.ts` + `nearby.ts` de la version web).
/// Seules les données « lieux » sont persistées (Store, clés « search.* »).
@MainActor
@Observable
final class SearchState {
    static let shared = SearchState()

    private enum K {
        static let home = "search.home", work = "search.work", favorites = "search.favorites"
        static let recents = "search.recents", car = "search.car"
    }

    var home: SearchSaved? { didSet { persist(K.home, home) } }
    var work: SearchSaved? { didSet { persist(K.work, work) } }
    var favorites: [SearchSaved] { didSet { Store.save(K.favorites, favorites) } }
    var recents: [SearchSaved] { didSet { Store.save(K.recents, recents) } }
    var car: SearchSaved? { didSet { persist(K.car, car) } }

    // MARK: interface

    var query = ""
    /// Recherche plein écran ouverte.
    var focused = false
    /// Mode « choisir un lieu » (Maison, Travail, favori).
    var picking: SearchPick?
    /// En mode « choisir » : la recherche est repliée, on attend un appui long sur la carte.
    var pickOnMap = false
    var category: SearchCategoryState?
    /// Accueil déplié (récents visibles).
    var expanded = false

    enum Status { case idle, loading, done, error }
    var results: [SearchResult] = []
    var completions: [SearchResult] = []
    var status: Status = .idle

    /// Centre et largeur (m) de la carte visible : « Rechercher dans cette zone ».
    var mapCenter: CLLocationCoordinate2D?
    var mapSpan: Double = 0

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var categoryTask: Task<Void, Never>?

    private init() {
        home = Store.load(K.home, default: SearchSaved?.none)
        work = Store.load(K.work, default: SearchSaved?.none)
        favorites = Store.load(K.favorites, default: [SearchSaved]())
        recents = Store.load(K.recents, default: [SearchSaved]())
        car = Store.load(K.car, default: SearchSaved?.none)
        SearchEngine.shared.onCompletions = { [weak self] in self?.refreshCompletions() }
    }

    private func persist(_ key: String, _ v: SearchSaved?) {
        if let v { Store.save(key, v) } else { Store.remove(key) }
    }

    private var core: Core { Core.shared }
    private var here: CLLocationCoordinate2D? { core.position?.coordinate }

    // MARK: - Recherche au fil de la frappe

    /// Appelé à chaque frappe : suggestions Apple tout de suite, recherche complète après 320 ms de calme.
    func queryChanged() {
        let q = query.trimmingCharacters(in: .whitespaces)
        searchTask?.cancel()
        SearchEngine.shared.complete(SearchText.parseCoords(q) == nil ? q : "", near: here)
        guard q.count >= 3, SearchText.parseCoords(q) == nil else {
            results = []; status = .idle
            return
        }
        status = .loading
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, let self else { return }
            do {
                let r = try await SearchEngine.shared.search(q, near: self.here)
                guard !Task.isCancelled else { return }
                self.results = r
                self.status = .done
                self.refreshCompletions()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.status = .error }
            }
        }
    }

    /// Suggestions Apple pas encore résolues qui n'existent pas déjà dans les résultats.
    private func refreshCompletions() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { completions = []; return }
        let known = Set(results.map { SearchText.norm($0.name) })
        completions = SearchEngine.shared.completions
            .filter { !known.contains(SearchText.norm($0.title)) && !$0.title.isEmpty }
            .prefix(results.isEmpty ? 6 : 3)
            .enumerated()
            .map { i, c in
                SearchResult(id: "cmp:\(c.title)|\(c.subtitle)", name: c.title, detail: c.subtitle, lat: 0, lng: 0,
                             kind: c.subtitle.isEmpty ? "city" : "poi", typeLabel: nil, source: .completion,
                             rel: 0.6 - Double(i) * 0.05, completion: c)
            }
    }

    func clearQuery() {
        query = ""
        queryChanged()
    }

    // MARK: - Lieux enregistrés

    private func near(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ m: Double = 60) -> Bool {
        Geo.distance(a, b) < m
    }

    func addRecent(_ p: SearchSaved) {
        var item = p.cleaned
        item.time = .now
        recents = Array(([item] + recents.filter { !near($0.coordinate, item.coordinate) }).prefix(20))
    }

    func removeRecent(_ id: String) { recents.removeAll { $0.id == id } }
    func clearRecents() { recents = [] }

    func isFavorite(_ c: CLLocationCoordinate2D) -> Bool { favorites.contains { near($0.coordinate, c, 30) } }

    /// Ajoute ou retire des favoris ; renvoie true si le lieu est maintenant favori.
    @discardableResult
    func toggleFavorite(_ p: SearchSaved) -> Bool {
        if isFavorite(p.coordinate) {
            favorites.removeAll { near($0.coordinate, p.coordinate, 30) }
            return false
        }
        var f = p.cleaned
        f.id = "fav:\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 36))"
        f.time = nil
        favorites = Array((favorites + [f]).prefix(40))
        return true
    }

    func renameFavorite(_ id: String, _ name: String) {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !n.isEmpty, let i = favorites.firstIndex(where: { $0.id == id }) else { return }
        favorites[i].name = n
    }

    func removeFavorite(_ id: String) { favorites.removeAll { $0.id == id } }

    func setShortcut(_ which: SearchPick, _ p: SearchSaved?) {
        var s = p?.cleaned
        s?.id = which.rawValue; s?.kind = which.rawValue; s?.time = nil
        switch which {
        case .home: home = s
        case .work: work = s
        case .favorite: break
        }
    }

    func parkCar(_ c: CLLocationCoordinate2D, detail: String? = nil) {
        car = SearchSaved(id: "car", name: "Ma voiture", detail: detail, coordinate: c, kind: "car", time: .now)
    }

    func forgetCar() { car = nil }

    // MARK: - Actions

    /// Ouvre la fiche d'un lieu et centre la carte dessus (au-dessus du panneau).
    func openPlace(_ d: SearchPlaceData) {
        focused = false
        core.openPanel("place", data: d)
        fly(to: d.coordinate)
    }

    /// Choisit ce lieu comme destination : le module routing calcule et passe en aperçu.
    func goTo(_ p: SearchSaved) {
        if p.kind != "home" && p.kind != "work" && p.kind != "car" { addRecent(p) }
        closeCategory()
        focused = false; picking = nil; pickOnMap = false
        query = ""; results = []; completions = []; status = .idle
        core.openPanel(nil)
        Haptic.play("light")
        emit(.placeGo(p.place))
    }

    /// Mode « choisir un lieu » : la recherche s'ouvre avec la bonne invite.
    func startPicking(_ target: SearchPick) {
        let fromSettings = core.settingsOpen
        core.settingsOpen = false
        core.openPanel(nil)
        closeCategory()
        picking = target
        pickOnMap = false
        query = ""; results = []; completions = []; status = .idle
        if fromSettings {
            // laisser l'écran Réglages se fermer avant de donner le clavier à la recherche
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                if self.picking == target { self.focused = true }
            }
        } else {
            focused = true
        }
    }

    /// Replie la recherche et attend un appui long sur la carte.
    func pickFromMap() {
        focused = false
        pickOnMap = true
    }

    func cancelPicking() {
        picking = nil
        pickOnMap = false
    }

    func completePick(_ p: SearchSaved) {
        guard let t = picking else { return }
        switch t {
        case .favorite:
            if !isFavorite(p.coordinate) { toggleFavorite(p) }
            toast("« \(p.name) » ajouté aux favoris", icon: "star.fill", tone: .good)
        case .home:
            setShortcut(.home, p)
            toast("Adresse de la maison enregistrée", icon: "house.fill", tone: .good)
        case .work:
            setShortcut(.work, p)
            toast("Adresse du travail enregistrée", icon: "briefcase.fill", tone: .good)
        }
        Haptic.play("success")
        picking = nil; pickOnMap = false; focused = false
        query = ""; results = []; completions = []; status = .idle
    }

    /// Ferme la recherche plein écran.
    func closeSearch() {
        focused = false
        if !pickOnMap { picking = nil }
    }

    func toast(_ text: String, icon: String? = nil, tone: Toast.Tone = .info) {
        emit(.toast(Toast(text: text, icon: icon, tone: tone)))
    }

    // MARK: - Autour de moi

    /// Centre de recherche « autour » : la zone regardée si l'utilisateur a bougé la carte, sinon sa position.
    func searchCenter() -> CLLocationCoordinate2D {
        if let map = core.map, !core.follow || core.position == nil { return map.centerCoordinate }
        return here ?? core.map?.centerCoordinate ?? Location.defaultCenter
    }

    func runCategory(_ id: String, center: CLLocationCoordinate2D? = nil) {
        guard let cat = SearchCategory.byId(id) else { return }
        let c = center ?? searchCenter()
        categoryTask?.cancel()
        focused = false
        category = SearchCategoryState(id: id, center: c)
        // la zone « regardée » repart du centre de recherche (sinon le bouton « dans cette zone » clignote)
        mapCenter = c
        mapSpan = 0
        core.openPanel("search-results")
        Haptic.play("light")
        categoryTask = Task { [weak self] in
            do {
                let results = try await SearchEngine.shared.nearby(cat, center: c)
                guard !Task.isCancelled, let self, self.category?.id == id else { return }
                self.category = SearchCategoryState(id: id, center: c, results: results, loading: false,
                                                    error: results.isEmpty ? "empty" : nil)
                self.fitResults(center: c, results.map(\.coordinate))
            } catch {
                guard !Task.isCancelled, let self, self.category?.id == id else { return }
                self.category = SearchCategoryState(id: id, center: c, results: [], loading: false, error: "network")
            }
        }
    }

    func closeCategory() {
        categoryTask?.cancel()
        category = nil
        if core.panel == "search-results" { core.openPanel(nil) }
    }

    // MARK: - Caméra

    /// Centre la carte sur un point, au-dessus du panneau du bas, sans trop zoomer ni dézoomer.
    func fly(to c: CLLocationCoordinate2D) {
        guard let map = core.map else { return }
        core.follow = false
        let currentSpan = map.region.span.latitudeDelta * 111_000
        let meters = min(max(currentSpan, 600), 2500)
        let region = MKCoordinateRegion(center: c, latitudinalMeters: meters, longitudinalMeters: meters)
        let bottom = max(core.sheetHeight, 300) + 20
        map.setVisibleMapRect(Self.rect(region), edgePadding: UIEdgeInsets(top: 110, left: 30, bottom: bottom, right: 30), animated: true)
    }

    private func fitResults(center: CLLocationCoordinate2D, _ coords: [CLLocationCoordinate2D]) {
        guard !coords.isEmpty else { return }
        // les 8 plus proches suffisent à cadrer (sinon une borne à 50 km dézoome tout)
        let pts = [center] + coords.prefix(8)
        guard let map = core.map else { return }
        core.follow = false
        var rect = MKMapRect.null
        for p in pts { rect = rect.union(MKMapRect(origin: MKMapPoint(p), size: MKMapSize(width: 1, height: 1))) }
        let minSize = 1200 * MKMapPointsPerMeterAtLatitude(center.latitude)
        if rect.size.width < minSize { rect = rect.insetBy(dx: -(minSize - rect.size.width) / 2, dy: 0) }
        if rect.size.height < minSize { rect = rect.insetBy(dx: 0, dy: -(minSize - rect.size.height) / 2) }
        let bottom = max(core.sheetHeight, 320) + 24
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 150, left: 40, bottom: bottom, right: 50), animated: true)
    }

    static func rect(_ r: MKCoordinateRegion) -> MKMapRect {
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: r.center.latitude + r.span.latitudeDelta / 2,
                                                  longitude: r.center.longitude - r.span.longitudeDelta / 2))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: r.center.latitude - r.span.latitudeDelta / 2,
                                                  longitude: r.center.longitude + r.span.longitudeDelta / 2))
        return MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: - Suggestion selon l'heure

    struct Suggestion { var place: SearchSaved; var title: String; var symbol: String }

    /// « Rentrer à la maison » le soir, « Aller au travail » en semaine le matin, « Retourner à ma voiture ».
    func suggestion(now: Date = .now) -> Suggestion? {
        guard let pos = here else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let h = cal.component(.hour, from: now)
        let wd = cal.component(.weekday, from: now)   // 1 = dimanche
        let weekday = (2...6).contains(wd)
        func far(_ p: SearchSaved?, _ m: Double) -> Bool { p.map { Geo.distance(pos, $0.coordinate) > m } ?? false }
        if let home, far(home, 500), h >= 16 || h < 3 { return .init(place: home, title: "Rentrer à la maison", symbol: "house.fill") }
        if let work, far(work, 500), weekday, h >= 6, h < 11 { return .init(place: work, title: "Aller au travail", symbol: "briefcase.fill") }
        if let car, let t = car.time, now.timeIntervalSince(t) < 36 * 3600, far(car, 150), !far(car, 5000) {
            return .init(place: car, title: "Retourner à ma voiture", symbol: "car.fill")
        }
        return nil
    }
}
