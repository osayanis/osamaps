import Foundation
import CoreLocation
import MapKit

/// Accès aux recherches : Apple (MKLocalSearch, MKLocalSearchCompleter, MKLocalPointsOfInterestRequest)
/// et Base Adresse Nationale / IGN (adresses françaises, service gratuit : cache + une salve par frappe stabilisée).
@MainActor
final class SearchEngine: NSObject, MKLocalSearchCompleterDelegate {
    static let shared = SearchEngine()

    // MARK: cache mémoire (10 min, 150 entrées)

    private var cache: [String: (t: Date, v: [SearchResult])] = [:]
    private var cacheOrder: [String] = []
    private let ttl: TimeInterval = 600

    private func cached(_ key: String) -> [SearchResult]? {
        guard let hit = cache[key], Date().timeIntervalSince(hit.t) < ttl else { return nil }
        return hit.v
    }

    private func store(_ key: String, _ v: [SearchResult]) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = (.now, v)
        while cacheOrder.count > 150 { cache[cacheOrder.removeFirst()] = nil }
    }

    // MARK: suggestions Apple (au fil de la frappe)

    private let completer = MKLocalSearchCompleter()
    /// Dernières suggestions reçues (titre/sous-titre, sans coordonnées).
    private(set) var completions: [MKLocalSearchCompletion] = []
    var onCompletions: (() -> Void)?

    private override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func complete(_ q: String, near: CLLocationCoordinate2D?) {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { completions = []; completer.cancel(); onCompletions?(); return }
        if let near { completer.region = MKCoordinateRegion(center: near, latitudinalMeters: 60_000, longitudinalMeters: 60_000) }
        completer.queryFragment = t
    }

    nonisolated func completerDidUpdateResults(_ c: MKLocalSearchCompleter) {
        let list = c.results
        Task { @MainActor in
            self.completions = list
            self.onCompletions?()
        }
    }

    nonisolated func completer(_ c: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.completions = []
            self.onCompletions?()
        }
    }

    // MARK: recherche combinée

    /// Apple (lieux, commerces, adresses) + IGN (adresses françaises), en parallèle.
    /// Une source en panne n'empêche pas l'autre de répondre ; les deux en panne → erreur.
    func search(_ q: String, near: CLLocationCoordinate2D?) async throws -> [SearchResult] {
        async let apple = Result(asyncCatching: { try await self.searchApple(q, near: near) })
        async let ban = Result(asyncCatching: { try await self.searchBan(q, near: near) })
        let (a, b) = await (apple, ban)
        try Task.checkCancellation()
        var all: [SearchResult] = []
        var ok = false
        if case .success(let r) = a { all += r; ok = true }
        if case .success(let r) = b { all += r; ok = true }
        if !ok { throw URLError(.cannotConnectToHost) }
        return Self.rank(q, all, near: near)
    }

    private func searchApple(_ q: String, near: CLLocationCoordinate2D?) async throws -> [SearchResult] {
        let key = "apple|\(SearchText.norm(q))|\(Self.grid(near))"
        if let hit = cached(key) { return hit }
        let r = MKLocalSearch.Request()
        r.naturalLanguageQuery = String(q.prefix(200))
        r.resultTypes = [.address, .pointOfInterest]
        if let near {
            r.region = MKCoordinateRegion(center: near, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
            // « boulangerie » : un commerce du coin, pas ceux de la grande ville d'à côté
            if SearchCategory.matching(q) != nil, #available(iOS 18.0, macOS 15.0, *) {
                r.regionPriority = .required
                r.region = MKCoordinateRegion(center: near, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
            }
        }
        let items = try await Self.run(MKLocalSearch(request: r))
        let out = items.prefix(10).enumerated().map { SearchResult(mapItem: $1, rank: $0) }
        store(key, out)
        return out
    }

    /// Résout une suggestion Apple (au toucher) en lieu complet.
    func resolve(_ completion: MKLocalSearchCompletion) async throws -> SearchResult? {
        let items = try await Self.run(MKLocalSearch(request: MKLocalSearch.Request(completion: completion)))
        guard let first = items.first else { return nil }
        var r = SearchResult(mapItem: first, rank: 0)
        if r.name.isEmpty { r.name = completion.title }
        return r
    }

    /// MKLocalSearch → [MKMapItem] ; « aucun résultat » n'est pas une erreur.
    private static func run(_ s: MKLocalSearch) async throws -> [MKMapItem] {
        do {
            return try await withTaskCancellationHandler {
                try await s.start().mapItems
            } onCancel: {
                s.cancel()
            }
        } catch let e as MKError where e.code == .placemarkNotFound {
            return []
        }
    }

    // MARK: IGN / BAN

    private struct BanResponse: Decodable { var features: [BanFeature]? }
    private struct BanFeature: Decodable {
        struct Geometry: Decodable { var coordinates: [Double] }
        struct Props: Decodable {
            var label: String?; var name: String?; var type: String?; var score: Double?
            var city: String?; var postcode: String?; var context: String?; var id: String?
        }
        var geometry: Geometry
        var properties: Props
        var coordinate: CLLocationCoordinate2D? {
            geometry.coordinates.count >= 2 ? .init(latitude: geometry.coordinates[1], longitude: geometry.coordinates[0]) : nil
        }
    }

    private static let banTypes: [String: (String, String)] = [
        "housenumber": ("Adresse", "address"), "street": ("Rue", "street"),
        "locality": ("Lieu-dit", "city"), "municipality": ("Commune", "city"),
    ]

    private func searchBan(_ q: String, near: CLLocationCoordinate2D?) async throws -> [SearchResult] {
        guard q.count >= 3 else { return [] }
        var c = URLComponents(url: External.geocodeFr.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "q", value: String(q.prefix(200))), .init(name: "limit", value: "6"),
                        .init(name: "autocomplete", value: "1")]
        if let near {
            c.queryItems! += [.init(name: "lat", value: String(format: "%.4f", near.latitude)),
                              .init(name: "lon", value: String(format: "%.4f", near.longitude))]
        }
        let url = c.url!
        if let hit = cached(url.absoluteString) { return hit }
        let d: BanResponse = try await API.external(url)
        let out: [SearchResult] = (d.features ?? []).compactMap { f in
            guard let coord = f.coordinate else { return nil }
            let p = f.properties
            let (typeLabel, kind) = Self.banTypes[p.type ?? ""] ?? ("Adresse", "address")
            let dept = p.context?.split(separator: ",").dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) }
            let detail = p.type == "municipality"
                ? [p.postcode, dept].compactMap { $0 }.joined(separator: " · ")
                : [p.postcode, p.city].compactMap { $0 }.joined(separator: " ")
            let name = p.name ?? p.label ?? "Adresse"
            return SearchResult(id: "ban:\(p.id ?? p.label ?? name)", name: name, detail: detail,
                                lat: coord.latitude, lng: coord.longitude, kind: kind, typeLabel: typeLabel,
                                source: .ban, rel: p.score ?? 0.5)
        }
        store(url.absoluteString, out)
        return out
    }

    // MARK: classement

    /// Doublon : même nom (ou presque) et proche, ou quasiment au même point.
    static func isDup(_ a: SearchResult, _ b: SearchResult) -> Bool {
        let d = Geo.distance(a.coordinate, b.coordinate)
        if d < 25 { return true }
        let same = SearchText.norm(a.name) == SearchText.norm(b.name)
        if same && a.kind == "city" && b.kind == "city" { return d < 8000 }
        if same && a.kind == "street" && b.kind == "street" { return d < 800 }
        return same && d < 150
    }

    /// Pertinence texte 55 %, source 20 %, proximité 25 % ; une commune au nom exact passe devant.
    static func rank(_ q: String, _ list: [SearchResult], near: CLLocationCoordinate2D?) -> [SearchResult] {
        let nq = SearchText.norm(q)
        // « boulangerie », « pharmacie »… : on cherche un commerce, pas le lieu-dit du même nom à 200 km
        let wantsPlace = SearchCategory.matching(q) != nil
        let scored = list.map { r -> SearchResult in
            var r = r
            let tm = SearchText.match(q, name: r.name, detail: r.detail + " " + (r.typeLabel ?? ""))
            let prox = near.map { 1 / (1 + Geo.distance($0, r.coordinate) / 1000 / 15) } ?? 0
            let cityBonus = r.kind == "city" && SearchText.norm(r.name) == nq ? 0.25 : 0
            r.score = tm * 0.55 + r.rel * 0.2 + prox * 0.25 + cityBonus
            // une adresse IGN qui ne ressemble pas à la requête (« Le Moulin » pour « gare moulins ») : bruit
            if r.source == .ban && tm < 0.3 { r.score = -1 }
            if r.source == .ban && wantsPlace { r.score *= 0.6 }
            return r
        }
        var out: [SearchResult] = []
        for r in scored.filter({ $0.score >= 0 }).sorted(by: { $0.score > $1.score }) {
            if let i = out.firstIndex(where: { isDup($0, r) }) {
                // on garde le libellé le plus riche (le commerce Apple plutôt que l'adresse brute)
                if out[i].typeLabel == nil || (out[i].source == .ban && r.source == .apple && r.kind != "address" && r.kind != "street" && r.kind != "city") {
                    let s = out[i].score
                    out[i] = r; out[i].score = s
                }
            } else {
                out.append(r)
            }
        }
        return Array(out.prefix(12))
    }

    private static func grid(_ c: CLLocationCoordinate2D?) -> String {
        guard let c else { return "-" }
        return String(format: "%.1f,%.1f", c.latitude, c.longitude)
    }

    // MARK: autour de moi

    /// POI d'une catégorie autour d'un point (Apple). Cache sur une grille d'≈ 1 km.
    /// Deux voies : la recherche par catégorie (MKLocalPointsOfInterestRequest) et la recherche texte filtrée ;
    /// si la première ne répond pas (ou rien), on tente l'autre.
    func nearby(_ cat: SearchCategory, center: CLLocationCoordinate2D) async throws -> [SearchResult] {
        let key = String(format: "near|%@|%.2f,%.2f", cat.id, center.latitude, center.longitude)
        if let hit = cached(key) { return hit }
        let ways: [() async throws -> [MKMapItem]] = cat.textFirst
            ? [{ try await self.nearbyText(cat, center) }, { try await self.nearbyPOI(cat, center) }]
            : [{ try await self.nearbyPOI(cat, center) }, { try await self.nearbyText(cat, center) }]
        var items: [MKMapItem] = []
        var failure: Error?
        for way in ways {
            do {
                items = try await way()
                if !items.isEmpty { break }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = failure ?? error
            }
            try Task.checkCancellation()
        }
        if items.isEmpty, let failure { throw failure }
        var out: [SearchResult] = []
        let sorted = items
            .map { SearchResult(mapItem: $0, rank: 0, fallbackLabel: cat.single) }
            .sorted { Geo.distance(center, $0.coordinate) < Geo.distance(center, $1.coordinate) }
        for var r in sorted where Geo.distance(center, r.coordinate) < cat.maxKm * 1000 {
            if r.typeLabel == nil { r.typeLabel = cat.single }
            if !out.contains(where: { Self.isDup($0, r) }) { out.append(r) }
        }
        out = Array(out.prefix(20))
        store(key, out)
        return out
    }

    private func nearbyPOI(_ cat: SearchCategory, _ center: CLLocationCoordinate2D) async throws -> [MKMapItem] {
        let r = MKLocalPointsOfInterestRequest(center: center, radius: min(cat.maxKm, 30) * 1000)
        r.pointOfInterestFilter = MKPointOfInterestFilter(including: cat.poi)
        return try await Self.run(MKLocalSearch(request: r))
    }

    /// Recherche texte filtrée sur la catégorie. La région n'est qu'indicative pour Apple : on la garde petite
    /// (sinon des résultats à 90 km remontent), et on filtre ensuite par distance.
    private func nearbyText(_ cat: SearchCategory, _ center: CLLocationCoordinate2D) async throws -> [MKMapItem] {
        let r = MKLocalSearch.Request()
        r.naturalLanguageQuery = cat.query
        r.resultTypes = .pointOfInterest
        r.pointOfInterestFilter = MKPointOfInterestFilter(including: cat.poi)
        let m = min(cat.maxKm, 12) * 2000
        r.region = MKCoordinateRegion(center: center, latitudinalMeters: m, longitudinalMeters: m)
        if #available(iOS 18.0, macOS 15.0, *) { r.regionPriority = .required }
        return try await Self.run(MKLocalSearch(request: r))
    }
}

/// Géocodage inverse : Apple (CLGeocoder) d'abord, IGN en secours.
@MainActor
enum SearchGeocoder {
    struct Address: Equatable { var name: String; var detail: String }

    private static var cache: [String: Address] = [:]
    private static let geocoder = CLGeocoder()

    static func reverse(_ c: CLLocationCoordinate2D) async -> Address? {
        let key = String(format: "%.5f,%.5f", c.latitude, c.longitude)
        if let hit = cache[key] { return hit }
        var a = await apple(c)
        if a == nil, !Task.isCancelled { a = try? await ban(c) }
        if let a { cache[key] = a }
        return a
    }

    private static func apple(_ c: CLLocationCoordinate2D) async -> Address? {
        if geocoder.isGeocoding { geocoder.cancelGeocode() }
        guard let pm = try? await geocoder.reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude),
                                                                  preferredLocale: Locale(identifier: "fr_FR")).first else { return nil }
        if let loc = pm.location, loc.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) > 300 { return nil }
        let street = [pm.subThoroughfare, pm.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let city = [pm.postalCode, pm.locality].compactMap { $0 }.joined(separator: " ")
        let name = !street.isEmpty ? street : (pm.areasOfInterest?.first ?? pm.name ?? pm.locality ?? "")
        guard !name.isEmpty else { return nil }
        return Address(name: name, detail: city)
    }

    private struct BanReverse: Decodable {
        struct F: Decodable {
            struct G: Decodable { var coordinates: [Double] }
            struct P: Decodable { var name: String?; var label: String?; var postcode: String?; var city: String? }
            var geometry: G; var properties: P
        }
        var features: [F]?
    }

    private static func ban(_ c: CLLocationCoordinate2D) async throws -> Address? {
        let url = URL(string: String(format: "%@/reverse?lat=%.6f&lon=%.6f&limit=1", External.geocodeFr.absoluteString, c.latitude, c.longitude))!
        let d: BanReverse = try await API.external(url)
        guard let f = d.features?.first, f.geometry.coordinates.count >= 2 else { return nil }
        let fc = CLLocationCoordinate2D(latitude: f.geometry.coordinates[1], longitude: f.geometry.coordinates[0])
        // trop loin du point demandé : l'adresse ne veut plus rien dire
        if Geo.distance(c, fc) > 250 { return nil }
        let p = f.properties
        return Address(name: p.name ?? p.label ?? "", detail: [p.postcode, p.city].compactMap { $0 }.joined(separator: " "))
    }
}

private extension Result where Failure == Error {
    init(asyncCatching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
