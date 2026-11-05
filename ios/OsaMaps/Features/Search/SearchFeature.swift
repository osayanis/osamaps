import SwiftUI
import CoreLocation
import Observation

/// Recherche & lieux : barre de recherche (Apple + Base Adresse Nationale), puces « autour de moi », accueil
/// (Maison, Travail, favoris, récents, Ma voiture), fiche lieu (panneau "place"), appui long sur la carte,
/// liens `osamaps://lieu`, réglages « Mes lieux ».
///
/// Contrat pour les autres modules :
///   - ouvrir une fiche : `Core.shared.openPanel("place", data: place)` (un `Place` du Core suffit) ;
///   - « Y aller » : `openPanel(nil)` puis `emit(.placeGo(place))` ;
///   - toute destination `.placeGo` rejoint les récents ; `.driveArrived` enregistre « Ma voiture ».
/// Liens gérés (via `.custom(name: "url")`) :
///   osamaps://lieu?lat=46.1278&lng=3.4258&name=Vichy   (ou ?lieu=lat,lng,nom) → fiche du lieu
///   osamaps://recherche?q=boulangerie                  → recherche plein écran (q facultatif)
///   osamaps://autour/fuel                              → puce « autour de moi » (fuel, charge, parking, food…)
@MainActor
let searchFeature = Feature(
    id: "search",
    name: "Recherche & lieux",
    slots: [
        SlotEntry(.top, order: 0) { SearchBarView() },
        SlotEntry(.sheet, order: 10) { SearchSheet() },
        SlotEntry(.overlay, order: 50) { SearchOverlay() },
        SlotEntry(.settings, order: 10) { SearchSettingsView() },
    ],
    mapLayers: [SearchMapLayer.layer],
    start: { SearchBoot.start() }
)

@MainActor
enum SearchBoot {
    private static var tokens: [BusToken] = []
    private static var lastMode: Mode = .browse

    static func start() {
        guard tokens.isEmpty else { return }
        let s = SearchState.shared
        tokens.append(Bus.shared.on { event in
            switch event {
            case .placeGo(let p):
                remember(p)
            case .driveArrived:
                parkAtArrival()
            case .custom(let name, let payload) where name == "url":
                if let raw = payload["url"], let url = URL(string: raw) { handle(url) }
            default:
                break
            }
        })
        lastMode = Core.shared.mode
        observeMode()
        _ = s
        #if DEBUG
        debugHooks()
        #endif
    }

    #if DEBUG
    /// Tests dans le Simulateur (iOS 27 demande une confirmation à chaque `simctl openurl`) :
    ///   -searchTestSeed YES                           → lieux d'exemple (maison, travail, favoris, récents)
    ///   -searchTestURL "osamaps://autour/bakery|osamaps://lieu?…"  → liens rejoués au démarrage (2,5 s d'écart)
    private static func debugHooks() {
        let d = UserDefaults.standard
        if d.bool(forKey: "searchTestSeed") {
            let s = SearchState.shared
            s.setShortcut(.home, SearchSaved(id: "h", name: "8 Rue de Paris", detail: "03000 Moulins",
                                             coordinate: .init(latitude: 46.567452, longitude: 3.331425)))
            s.setShortcut(.work, SearchSaved(id: "w", name: "Avenue des Isles", detail: "03000 Avermes",
                                             coordinate: .init(latitude: 46.5838, longitude: 3.3125)))
            s.favorites = [SearchSaved(id: "fav:1", name: "Vichy", detail: "03200 · Allier",
                                       coordinate: .init(latitude: 46.1278, longitude: 3.4258), kind: "city")]
            s.recents = [
                SearchSaved(id: "r1", name: "Céréa", detail: "8 Rue d'Allier, 03000 Moulins",
                            coordinate: .init(latitude: 46.5651, longitude: 3.3347), kind: "bakery", time: .now.addingTimeInterval(-3600)),
                SearchSaved(id: "r2", name: "Gare de Moulins", detail: "Place de la Gare, 03000 Moulins",
                            coordinate: .init(latitude: 46.5606, longitude: 3.3410), kind: "train", time: .now.addingTimeInterval(-90_000)),
            ]
        }
        guard let raw = d.string(forKey: "searchTestURL") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for part in raw.split(separator: "|") {
                if let u = URL(string: String(part)) { Links.handle(u) }
                try? await Task.sleep(for: .seconds(2.5))
            }
        }
    }
    #endif

    /// Toute destination choisie (par n'importe quel module) rejoint les récents.
    private static func remember(_ p: Place) {
        let s = SearchState.shared
        let c = p.coordinate
        if let last = s.recents.first, let t = last.time, Date().timeIntervalSince(t) < 3, Geo.distance(last.coordinate, c) < 60 { return }
        for q in [s.home, s.work, s.car].compactMap({ $0 }) where Geo.distance(q.coordinate, c) < 60 { return }
        s.addRecent(SearchSaved(id: String(format: "go:%.5f,%.5f", c.longitude, c.latitude), name: p.name, detail: p.detail,
                                coordinate: c, kind: p.kind == "friend" ? "friend" : (p.kind ?? "address")))
    }

    /// Arrivée : on retient où la voiture est garée (puis son adresse, quand elle est connue).
    private static func parkAtArrival() {
        guard let pos = Core.shared.position?.coordinate else { return }
        let s = SearchState.shared
        s.parkCar(pos)
        s.toast("Position de la voiture enregistrée", icon: "car.fill", tone: .good)
        Task { @MainActor in
            guard let a = await SearchGeocoder.reverse(pos), let car = s.car,
                  car.lat == pos.latitude, car.lng == pos.longitude else { return }
            s.car?.detail = [a.name, a.detail].filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    /// En quittant l'exploration (aperçu, conduite) on range la recherche ; au retour de conduite, on oublie la catégorie.
    private static func observeMode() {
        withObservationTracking {
            _ = Core.shared.mode
        } onChange: {
            Task { @MainActor in
                let mode = Core.shared.mode
                let s = SearchState.shared
                if mode != .browse {
                    s.focused = false
                    s.picking = nil
                    s.pickOnMap = false
                } else if lastMode == .drive {
                    s.category = nil
                }
                lastMode = mode
                observeMode()
            }
        }
    }

    // MARK: liens

    static func handle(_ url: URL) {
        let s = SearchState.shared
        let core = Core.shared
        switch url.host()?.lowercased() {
        case "lieu", "place":
            guard let lieu = SearchShare.parseLieu(url) else { return }
            let d = SearchPlaceData(
                saved: SearchSaved(id: "link:\(SearchFormat.pointId(lieu.coord.latitude, lieu.coord.longitude))",
                                   name: lieu.name ?? "Point sur la carte", coordinate: lieu.coord,
                                   kind: lieu.name == nil ? "map" : "poi"),
                from: .link, needsAddress: true)
            whenMapReady {
                if core.mode != .browse { return }
                s.openPlace(d)
            }
        case "recherche", "search":
            guard core.mode == .browse else { return }
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            core.openPanel(nil)
            s.query = q
            s.focused = true
            s.queryChanged()
        case "autour", "nearby":
            guard core.mode == .browse, let id = url.pathComponents.dropFirst().first, SearchCategory.byId(id) != nil else { return }
            whenMapReady { s.runCategory(id) }
        default:
            break
        }
    }

    /// Exécute `action` quand la carte est prête (lien reçu au lancement).
    private static func whenMapReady(_ action: @escaping @MainActor () -> Void, tries: Int = 0) {
        if Core.shared.mapReady || tries > 40 { action(); return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            whenMapReady(action, tries: tries + 1)
        }
    }
}
