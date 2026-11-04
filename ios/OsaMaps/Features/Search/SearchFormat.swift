import Foundation
import CoreLocation
import MapKit

/// Texte : normalisation et correspondance (port de `api.ts` de la version web).
enum SearchText {
    /// Sans accents, minuscules, mots séparés par une espace.
    static func norm(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).lowercased()
        var out = ""
        var space = false
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch); space = false
            } else if !space, !out.isEmpty {
                out.append(" "); space = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Correspondance 0…1 entre la requête et un libellé.
    static func match(_ q: String, name: String, detail: String) -> Double {
        let nq = norm(q), nn = norm(name)
        guard !nq.isEmpty else { return 0 }
        if nn == nq { return 1 }
        let tokens = nq.split(separator: " ")
        let words = (nn + " " + norm(detail)).split(separator: " ")
        let found = tokens.filter { t in words.contains { $0.hasPrefix(t) } }.count
        var s = Double(found) / Double(max(1, tokens.count)) * 0.75
        if nn.hasPrefix(nq) { s += 0.2 } else if nn.contains(nq) { s += 0.1 }
        return min(1, s)
    }

    /// Un mot du libellé commence par la requête (ou le libellé la contient).
    static func loose(_ q: String, _ s: String) -> Bool {
        let nq = norm(q), ns = norm(s)
        guard !nq.isEmpty else { return false }
        return ns.split(separator: " ").contains { $0.hasPrefix(nq) } || ns.contains(nq)
    }

    /// « 46.12, 3.42 » ou « 46,12 3,42 » → coordonnées.
    static func parseCoords(_ q: String) -> CLLocationCoordinate2D? {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard let re = try? NSRegularExpression(pattern: #"^(-?\d{1,2}(?:[.,]\d+)?)\s*[,; ]\s*(-?\d{1,3}(?:[.,]\d+)?)$"#),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let r1 = Range(m.range(at: 1), in: t), let r2 = Range(m.range(at: 2), in: t),
              let lat = Double(t[r1].replacingOccurrences(of: ",", with: ".")),
              let lng = Double(t[r2].replacingOccurrences(of: ",", with: ".")),
              abs(lat) <= 90, abs(lng) <= 180 else { return nil }
        return .init(latitude: lat, longitude: lng)
    }
}

/// Formats et correspondances d'icônes (port de `format.ts`).
enum SearchFormat {
    private static let symbols: [String: String] = [
        "address": "mappin.and.ellipse", "street": "road.lanes", "city": "building.2.fill", "poi": "mappin",
        "fuel": "fuelpump.fill", "charge": "ev.charger.fill", "parking": "parkingsign.circle.fill",
        "food": "fork.knife", "cafe": "cup.and.saucer.fill", "bakery": "birthday.cake.fill",
        "pharmacy": "cross.case.fill", "shop": "cart.fill", "toilets": "toilet.fill", "health": "cross.fill",
        "train": "tram.fill", "bus": "bus.fill", "park": "tree.fill", "home": "house.fill", "work": "briefcase.fill",
        "car": "car.fill", "favorite": "star.fill", "recent": "clock", "coords": "location.fill.viewfinder",
        "map": "mappin", "hotel": "bed.double.fill", "school": "graduationcap.fill", "bank": "building.columns.fill",
        "store": "bag.fill", "friend": "person.fill",
    ]

    static func symbol(_ kind: String?) -> String { symbols[kind ?? ""] ?? "mappin" }

    /// Catégories Apple → libellé français + famille d'icône.
    static let poiInfo: [MKPointOfInterestCategory: (label: String, kind: String)] = [
        .gasStation: ("Station-service", "fuel"), .evCharger: ("Borne de recharge", "charge"),
        .parking: ("Parking", "parking"), .restaurant: ("Restaurant", "food"), .cafe: ("Café", "cafe"),
        .bakery: ("Boulangerie", "bakery"), .pharmacy: ("Pharmacie", "pharmacy"), .hospital: ("Hôpital", "health"),
        .foodMarket: ("Supermarché", "shop"), .store: ("Commerce", "store"), .restroom: ("Toilettes", "toilets"),
        .publicTransport: ("Transports", "train"), .park: ("Parc", "park"), .nationalPark: ("Parc national", "park"),
        .hotel: ("Hôtel", "hotel"), .school: ("École", "school"), .university: ("Université", "school"),
        .bank: ("Banque", "bank"), .atm: ("Distributeur", "bank"), .police: ("Police", "poi"),
        .postOffice: ("Bureau de poste", "poi"), .museum: ("Musée", "poi"), .movieTheater: ("Cinéma", "poi"),
        .theater: ("Théâtre", "poi"), .library: ("Bibliothèque", "poi"), .fitnessCenter: ("Salle de sport", "poi"),
        .airport: ("Aéroport", "poi"), .carRental: ("Location de voitures", "car"),
        .nightlife: ("Bar", "cafe"), .brewery: ("Brasserie", "cafe"),
        .winery: ("Domaine viticole", "poi"), .stadium: ("Stade", "poi"), .zoo: ("Zoo", "park"),
        .beach: ("Plage", "park"), .campground: ("Camping", "park"),
        .fireStation: ("Caserne de pompiers", "poi"), .laundry: ("Laverie", "poi"), .amusementPark: ("Parc d'attractions", "park"),
    ]

    static func distanceLabel(_ from: CLLocationCoordinate2D?, _ to: CLLocationCoordinate2D) -> String? {
        guard let from else { return nil }
        return Geo.formatDistance(Geo.distance(from, to))
    }

    private static let dirs = ["au nord", "au nord-est", "à l'est", "au sud-est", "au sud", "au sud-ouest", "à l'ouest", "au nord-ouest"]

    /// « 2,3 km au nord-est » + cap en degrés.
    static func direction(_ from: CLLocationCoordinate2D, _ to: CLLocationCoordinate2D) -> (text: String, deg: Double) {
        let deg = Geo.bearing(from, to)
        let d = Geo.distance(from, to)
        if d < 30 { return ("Vous y êtes", deg) }
        return ("\(Geo.formatDistance(d)) \(dirs[Int((deg / 45).rounded()) % 8])", deg)
    }

    /// « à l'instant », « il y a 5 min », « il y a 2 h », « hier », « le 3 nov. ».
    static func ago(_ t: Date, now: Date = .now) -> String {
        let s = now.timeIntervalSince(t)
        if s < 60 { return "à l'instant" }
        if s < 3600 { return "il y a \(Int((s / 60).rounded())) min" }
        if s < 86_400 { return "il y a \(Int((s / 3600).rounded())) h" }
        if s < 172_800 { return "hier" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM"
        return "le \(f.string(from: t))"
    }

    static func coord(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }

    static func pointId(_ lat: Double, _ lng: Double) -> String {
        String(format: "pt:%.5f,%.5f", lat, lng)
    }
}

/// Liens de partage et autres applications de navigation (port de `share.ts`).
enum SearchShare {
    /// https://osalabs.fr/maps/?lieu=46.12780,3.42580,Vichy
    static func webURL(_ p: SearchSaved) -> URL {
        let name = String(p.name.replacingOccurrences(of: ",", with: " ").prefix(80))
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?,"))) ?? ""
        return URL(string: String(format: "https://osalabs.fr/maps/?lieu=%.5f,%.5f,", p.lat, p.lng) + enc)!
    }

    /// osamaps://lieu?lat=46.12780&lng=3.42580&name=Vichy
    static func appURL(_ p: SearchSaved) -> URL {
        var c = URLComponents()
        c.scheme = "osamaps"; c.host = "lieu"
        c.queryItems = [.init(name: "lat", value: String(format: "%.5f", p.lat)),
                        .init(name: "lng", value: String(format: "%.5f", p.lng)),
                        .init(name: "name", value: String(p.name.prefix(80)))]
        return c.url!
    }

    static func message(_ p: SearchSaved) -> String {
        let head = [p.name, p.detail].compactMap { $0 }.joined(separator: ", ")
        return "\(head)\nDans OsaMaps : \(appURL(p).absoluteString)"
    }

    static func waze(_ p: SearchSaved) -> URL {
        URL(string: String(format: "https://waze.com/ul?ll=%.6f,%.6f&navigate=yes", p.lat, p.lng))!
    }

    static func google(_ p: SearchSaved) -> URL {
        URL(string: String(format: "https://www.google.com/maps/dir/?api=1&destination=%.6f,%.6f", p.lat, p.lng))!
    }

    @MainActor
    static func openInAppleMaps(_ p: SearchSaved) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: p.coordinate))
        item.name = p.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    /// Lit `osamaps://lieu?lat=&lng=&name=` (ou `?lieu=lat,lng,nom` comme le lien web).
    static func parseLieu(_ url: URL) -> (coord: CLLocationCoordinate2D, name: String?)? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        var lat = Double(q["lat"] ?? ""), lng = Double(q["lng"] ?? q["lon"] ?? "")
        var name = q["name"]
        if lat == nil, let raw = q["lieu"] {
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 2 {
                lat = Double(parts[0]); lng = Double(parts[1])
                name = parts.dropFirst(2).joined(separator: ",")
            }
        }
        guard let lat, let lng, abs(lat) <= 90, abs(lng) <= 180 else { return nil }
        let n = name?.trimmingCharacters(in: .whitespaces).prefix(80)
        return (.init(latitude: lat, longitude: lng), (n?.isEmpty ?? true) ? nil : String(n!))
    }
}
