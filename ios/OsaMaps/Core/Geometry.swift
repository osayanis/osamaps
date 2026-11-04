import Foundation
import CoreLocation

/// Calculs géographiques (port de `geometry.ts`) et formats en français.
enum Geo {
    static let earthRadius = 6_371_008.8

    /// Distance en mètres (haversine).
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dφ = φ2 - φ1, dλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Cap en degrés (0 = nord) de a vers b.
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Distances cumulées le long d'une ligne (même longueur que `line`).
    static func cumulative(_ line: [CLLocationCoordinate2D]) -> [Double] {
        var out = [Double](repeating: 0, count: line.count)
        for i in line.indices.dropFirst() { out[i] = out[i - 1] + distance(line[i - 1], line[i]) }
        return out
    }

    /// Point à `d` mètres du début de la ligne.
    static func along(_ line: [CLLocationCoordinate2D], _ cum: [Double], _ d: Double) -> CLLocationCoordinate2D {
        guard let last = line.last else { return .init() }
        if d <= 0 { return line[0] }
        guard let i = cum.firstIndex(where: { $0 >= d }), i > 0 else { return last }
        let seg = cum[i] - cum[i - 1]
        let t = seg > 0 ? (d - cum[i - 1]) / seg : 0
        return .init(latitude: line[i - 1].latitude + (line[i].latitude - line[i - 1].latitude) * t,
                     longitude: line[i - 1].longitude + (line[i].longitude - line[i - 1].longitude) * t)
    }

    struct Snap { var point: CLLocationCoordinate2D; var index: Int; var t: Double; var distance: Double; var along: Double }

    /// Accroche `p` au segment le plus proche de `line` (option : chercher seulement dans [from, to)).
    static func snap(_ p: CLLocationCoordinate2D, to line: [CLLocationCoordinate2D], cum: [Double]? = nil, from: Int = 0, to end: Int? = nil) -> Snap? {
        guard line.count >= 2 else { return nil }
        let c = cum ?? cumulative(line)
        let kx = cos(p.latitude * .pi / 180) * 111_320.0, ky = 110_540.0
        var best: Snap?
        let upper = min(end ?? line.count - 1, line.count - 1)
        for i in max(0, from)..<max(max(0, from), upper) {
            let a = line[i], b = line[i + 1]
            let ax = (a.longitude - p.longitude) * kx, ay = (a.latitude - p.latitude) * ky
            let bx = (b.longitude - p.longitude) * kx, by = (b.latitude - p.latitude) * ky
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
            let x = ax + dx * t, y = ay + dy * t
            let d = (x * x + y * y).squareRoot()
            if best == nil || d < best!.distance {
                let pt = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                longitude: a.longitude + (b.longitude - a.longitude) * t)
                best = Snap(point: pt, index: i, t: t, distance: d, along: c[i] + (c[i + 1] - c[i]) * t)
            }
        }
        return best
    }

    /// Décode une polyline encodée (Valhalla : précision 6).
    static func decodePolyline(_ s: String, precision: Double = 1e6) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        let bytes = Array(s.utf8)
        var i = 0, lat = 0, lng = 0
        while i < bytes.count {
            for k in 0..<2 {
                var result = 0, shift = 0, b = 0
                repeat {
                    b = Int(bytes[i]) - 63; i += 1
                    result |= (b & 0x1f) << shift
                    shift += 5
                } while b >= 0x20 && i < bytes.count
                let delta = (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
                if k == 0 { lat += delta } else { lng += delta }
            }
            out.append(.init(latitude: Double(lat) / precision, longitude: Double(lng) / precision))
        }
        return out
    }

    // MARK: - Formats français

    /// « 300 m », « 1,2 km », « 12 km ».
    static func formatDistance(_ m: Double) -> String {
        if m < 50 { return "\(Int((m / 5).rounded()) * 5) m" }
        if m < 1000 { return "\(Int((m / 10).rounded()) * 10) m" }
        if m < 10_000 { return String(format: "%.1f km", m / 1000).replacingOccurrences(of: ".", with: ",") }
        return "\(Int((m / 1000).rounded())) km"
    }

    /// « 7 min », « 1 h 05 ».
    static func formatDuration(_ s: Double) -> String {
        let mins = Int((s / 60).rounded())
        if mins < 60 { return "\(max(1, mins)) min" }
        return String(format: "%d h %02d", mins / 60, mins % 60)
    }

    /// Heure d'arrivée « 17:42 ».
    static func formatETA(_ seconds: Double, from now: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f.string(from: now.addingTimeInterval(seconds))
    }
}
