import Foundation
import CoreLocation

/// Recherche minimale d'étape (Base Adresse Nationale / IGN), propre à ce module : le module search
/// possède la vraie recherche ; ici on veut juste pouvoir taper « Varennes » pour un arrêt.
struct RoutingHit: Identifiable, Hashable, Sendable {
    var id: String { "\(name)|\(lat),\(lng)" }
    var name: String
    var detail: String?
    var lat: Double
    var lng: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

private struct RoutingBanResponse: Decodable {
    struct Feature: Decodable {
        struct Geometry: Decodable { var coordinates: [Double] }
        struct Props: Decodable {
            var label: String?
            var name: String?
            var city: String?
            var postcode: String?
            var context: String?
            var type: String?
        }
        var geometry: Geometry
        var properties: Props
    }
    var features: [Feature]?
}

@MainActor
enum RoutingGeocode {
    private static var cache: [String: [RoutingHit]] = [:]
    private static var order: [String] = []

    private static func hit(_ f: RoutingBanResponse.Feature) -> RoutingHit? {
        guard f.geometry.coordinates.count >= 2 else { return nil }
        let p = f.properties
        let name = p.name ?? p.label ?? "Lieu"
        let detail = [p.postcode, p.city].compactMap { $0 }.joined(separator: " ")
        let isCity = p.type == "municipality"
        return RoutingHit(name: isCity ? (p.city ?? name) : name,
                          detail: isCity ? p.context : (detail.isEmpty ? p.context : detail),
                          lat: f.geometry.coordinates[1], lng: f.geometry.coordinates[0])
    }

    static func search(_ q: String, near: CLLocationCoordinate2D?) async throws -> [RoutingHit] {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3 else { return [] }
        let key = query.lowercased() + "|" + (near.map { String(format: "%.1f,%.1f", $0.longitude, $0.latitude) } ?? "")
        if let c = cache[key] { return c }
        var u = URLComponents(url: External.geocodeFr.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "q", value: String(query.prefix(120))), URLQueryItem(name: "limit", value: "5")]
        if let near {
            items.append(URLQueryItem(name: "lon", value: String(format: "%.4f", near.longitude)))
            items.append(URLQueryItem(name: "lat", value: String(format: "%.4f", near.latitude)))
        }
        u.queryItems = items
        let data: RoutingBanResponse = try await API.external(u.url!)
        let out = (data.features ?? []).compactMap(hit)
        cache[key] = out
        order.append(key)
        if order.count > 60 { cache[order.removeFirst()] = nil }
        return out
    }

    static func reverse(_ c: CLLocationCoordinate2D) async -> RoutingHit? {
        var u = URLComponents(url: External.geocodeFr.appendingPathComponent("reverse"), resolvingAgainstBaseURL: false)!
        u.queryItems = [URLQueryItem(name: "lon", value: String(format: "%.5f", c.longitude)),
                        URLQueryItem(name: "lat", value: String(format: "%.5f", c.latitude)),
                        URLQueryItem(name: "limit", value: "1")]
        guard let data: RoutingBanResponse = try? await API.external(u.url!) else { return nil }
        return data.features?.first.flatMap(hit)
    }
}
