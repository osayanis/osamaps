import Foundation
import CoreLocation
import MapKit

// MARK: - Lieux enregistrés

/// Un lieu enregistré (maison, travail, favori, récent, voiture). Persisté via `Store` (clés « search.* »).
struct SearchSaved: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var detail: String?
    var lat: Double
    var lng: Double
    /// Famille d'icône : address, street, city, poi, fuel, home, work, car…
    var kind: String?
    var typeLabel: String?
    /// Récents : dernière utilisation ; voiture : heure de stationnement.
    var time: Date?
    var phone: String?
    var url: String?

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }

    init(id: String, name: String, detail: String? = nil, coordinate c: CLLocationCoordinate2D, kind: String? = nil,
         typeLabel: String? = nil, time: Date? = nil, phone: String? = nil, url: String? = nil) {
        self.id = id; self.name = name; self.detail = detail
        self.lat = c.latitude; self.lng = c.longitude
        self.kind = kind; self.typeLabel = typeLabel; self.time = time; self.phone = phone; self.url = url
    }

    /// Version nettoyée (longueurs bornées, coordonnées arrondies) avant d'être enregistrée.
    var cleaned: SearchSaved {
        var s = self
        s.name = String(name.prefix(120))
        s.detail = detail.map { String($0.prefix(160)) }
        s.lat = (lat * 1e6).rounded() / 1e6
        s.lng = (lng * 1e6).rounded() / 1e6
        return s
    }

    /// Le `Place` du Core (pour `.placeGo`).
    var place: Place { Place(id: id, name: name, detail: detail, coordinate: coordinate, kind: kind) }
}

/// Données du panneau "place" (fiche lieu). Les autres modules ouvrent ce panneau avec un simple `Place`
/// (`core.openPanel("place", data: place)`) : il est converti par `SearchPlaceData.from(_:)`.
struct SearchPlaceData: Hashable, Sendable {
    enum Origin: String, Sendable { case list, search, map, link, home, other }

    var saved: SearchSaved
    var from: Origin = .other
    /// Adresse à compléter par géocodage inverse (appui long, lien partagé, lieu sans adresse).
    var needsAddress = false

    var coordinate: CLLocationCoordinate2D { saved.coordinate }

    /// Normalise ce qu'un module a pu mettre dans `panelData`.
    static func from(_ any: Any?) -> SearchPlaceData? {
        switch any {
        case let d as SearchPlaceData:
            return d
        case let p as Place:
            let s = SearchSaved(id: p.id, name: p.name.isEmpty ? "Point sur la carte" : p.name, detail: p.detail,
                                coordinate: p.coordinate, kind: p.kind)
            return SearchPlaceData(saved: s, from: .other, needsAddress: p.detail == nil && p.kind != "city")
        case let s as SearchSaved:
            return SearchPlaceData(saved: s, from: .other, needsAddress: s.detail == nil)
        case let item as MKMapItem:
            return SearchPlaceData(saved: SearchResult(mapItem: item, rank: 0).saved, from: .other, needsAddress: false)
        case let d as [String: Any]:
            func num(_ k: String) -> Double? {
                if let v = d[k] as? Double { return v }
                if let v = d[k] as? String { return Double(v) }
                return nil
            }
            guard let lat = num("lat"), let lng = num("lng"), abs(lat) <= 90, abs(lng) <= 180 else { return nil }
            let name = (d["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Point sur la carte"
            let s = SearchSaved(id: d["id"] as? String ?? SearchFormat.pointId(lat, lng), name: name,
                                detail: d["detail"] as? String, coordinate: .init(latitude: lat, longitude: lng),
                                kind: d["kind"] as? String)
            return SearchPlaceData(saved: s, from: .other, needsAddress: s.detail == nil)
        default:
            return nil
        }
    }
}

enum SearchPick: String, Sendable {
    case home, work, favorite

    var placeholder: String {
        switch self {
        case .home: "Adresse de la maison"
        case .work: "Adresse du travail"
        case .favorite: "Ajouter un favori"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .work: "briefcase.fill"
        case .favorite: "star.fill"
        }
    }
}

// MARK: - Résultats de recherche

struct SearchResult: Identifiable {
    enum Source: String { case ban, apple, completion, local, coords }

    var id: String
    var name: String
    var detail: String
    var lat: Double
    var lng: Double
    var kind: String
    var typeLabel: String?
    var source: Source
    /// Pertinence donnée par la source (0…1).
    var rel: Double
    var score: Double = 0
    var phone: String?
    var url: String?
    /// Suggestion Apple pas encore résolue (pas de coordonnées) : résolue au toucher.
    var completion: MKLocalSearchCompletion?

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    var hasCoordinate: Bool { completion == nil }

    var saved: SearchSaved {
        SearchSaved(id: id, name: name, detail: detail.isEmpty ? nil : detail, coordinate: coordinate, kind: kind,
                    typeLabel: typeLabel, phone: phone, url: url)
    }
}

extension SearchResult {
    /// Un résultat Apple (MKLocalSearch / MKLocalPointsOfInterestRequest).
    init(mapItem item: MKMapItem, rank: Int, fallbackLabel: String? = nil) {
        let pm = item.placemark
        let c = pm.coordinate
        let street = [pm.subThoroughfare, pm.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let city = [pm.postalCode, pm.locality].compactMap { $0 }.joined(separator: " ")
        let name = item.name ?? (street.isEmpty ? (pm.locality ?? "Lieu") : street)
        var kind = "poi"
        var typeLabel: String? = fallbackLabel
        if let cat = item.pointOfInterestCategory, let info = SearchFormat.poiInfo[cat] {
            typeLabel = info.label; kind = info.kind
        } else if item.pointOfInterestCategory == nil {
            if pm.thoroughfare == nil, pm.locality != nil, name == pm.locality {
                kind = "city"; typeLabel = "Ville"
            } else if pm.subThoroughfare != nil {
                kind = "address"; typeLabel = "Adresse"
            } else if pm.thoroughfare != nil, name == pm.thoroughfare {
                kind = "street"; typeLabel = "Rue"
            }
        }
        var detailParts: [String] = []
        if !street.isEmpty, street != name { detailParts.append(street) }
        if !city.isEmpty, kind != "city" { detailParts.append(city) }
        if kind == "city" { detailParts.append([pm.postalCode, pm.administrativeArea].compactMap { $0 }.joined(separator: " · ")) }
        if let cc = pm.isoCountryCode, cc != "FR", let country = pm.country { detailParts.append(country) }
        self.init(id: "apple:\(name)|\(String(format: "%.5f,%.5f", c.latitude, c.longitude))",
                  name: name, detail: detailParts.filter { !$0.isEmpty }.joined(separator: ", "),
                  lat: c.latitude, lng: c.longitude, kind: kind, typeLabel: typeLabel, source: .apple,
                  rel: max(0.35, 0.88 - Double(rank) * 0.05),
                  phone: item.phoneNumber, url: item.url?.absoluteString)
    }
}

// MARK: - Catégories « autour de moi »

struct SearchCategory: Identifiable, Hashable {
    var id: String
    var label: String
    /// Au singulier, pour la fiche (« Station-service »).
    var single: String
    var symbol: String
    var poi: [MKPointOfInterestCategory]
    /// Requête texte de secours (MKLocalSearch) si la recherche par catégorie ne répond pas.
    var query: String
    /// Rayon max (km).
    var maxKm: Double
    /// Mots qui font proposer la catégorie quand on les tape.
    var aliases: [String] = []

    static let all: [SearchCategory] = [
        .init(id: "fuel", label: "Essence", single: "Station-service", symbol: "fuelpump.fill", poi: [.gasStation],
              query: "station-service", maxKm: 25, aliases: ["essence", "carburant", "station", "gazole", "diesel"]),
        .init(id: "charge", label: "Recharge", single: "Borne de recharge", symbol: "ev.charger.fill", poi: [.evCharger],
              query: "borne de recharge", maxKm: 50, aliases: ["recharge", "borne", "electrique"]),
        .init(id: "parking", label: "Parking", single: "Parking", symbol: "parkingsign.circle.fill", poi: [.parking],
              query: "parking", maxKm: 10, aliases: ["parking", "garer", "stationnement"]),
        .init(id: "food", label: "Restos", single: "Restaurant", symbol: "fork.knife", poi: [.restaurant],
              query: "restaurant", maxKm: 20, aliases: ["resto", "restaurant", "manger"]),
        .init(id: "bakery", label: "Boulangerie", single: "Boulangerie", symbol: "birthday.cake.fill", poi: [.bakery],
              query: "boulangerie", maxKm: 15, aliases: ["boulangerie", "pain", "patisserie"]),
        .init(id: "pharmacy", label: "Pharmacie", single: "Pharmacie", symbol: "cross.case.fill", poi: [.pharmacy],
              query: "pharmacie", maxKm: 20, aliases: ["pharmacie"]),
        .init(id: "shop", label: "Supermarché", single: "Supermarché", symbol: "cart.fill", poi: [.foodMarket],
              query: "supermarché", maxKm: 20, aliases: ["supermarche", "courses", "epicerie", "hypermarche"]),
        .init(id: "cafe", label: "Cafés", single: "Café", symbol: "cup.and.saucer.fill", poi: [.cafe],
              query: "café", maxKm: 15, aliases: ["cafe", "bar"]),
        .init(id: "toilets", label: "Toilettes", single: "Toilettes", symbol: "toilet.fill", poi: [.restroom],
              query: "toilettes", maxKm: 30, aliases: ["toilettes", "wc"]),
        .init(id: "health", label: "Hôpital", single: "Hôpital", symbol: "cross.fill", poi: [.hospital],
              query: "hôpital", maxKm: 60, aliases: ["hopital", "urgences", "clinique"]),
    ]

    static func byId(_ id: String) -> SearchCategory? { all.first { $0.id == id } }

    /// Catégorie évoquée par une requête (« boul » → Boulangerie).
    static func matching(_ q: String) -> SearchCategory? {
        let n = SearchText.norm(q)
        guard n.count >= 3 else { return nil }
        return all.first { c in
            ([SearchText.norm(c.label)] + c.aliases).contains { $0.hasPrefix(n) || (n.hasPrefix($0) && n.count <= $0.count + 2) }
        }
    }
}

/// État d'une recherche par catégorie (panneau "search-results").
struct SearchCategoryState {
    var id: String
    var center: CLLocationCoordinate2D
    var results: [SearchResult] = []
    var loading = true
    /// "network" ou "empty".
    var error: String?

    var category: SearchCategory? { SearchCategory.byId(id) }
}
