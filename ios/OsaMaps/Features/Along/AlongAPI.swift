import Foundation
import CoreLocation

/// Appels au serveur (contrat : `server/features/along.js`).
enum AlongAPI {
    struct FuelResponse: Decodable, Sendable { var updatedAt: Double?; var stations: [AlongFuelStation] }
    struct EvResponse: Decodable, Sendable { var updatedAt: Double?; var stations: [AlongEvStation] }
    struct RestResponse: Decodable, Sendable { var areas: [AlongRestArea]; var partial: Bool? }

    private struct LineBody: Encodable { var points: [[Double]]; var maxDist: Double; var minKw: Double? }
    private struct RestBody: Encodable { var points: [[Double]]; var fromAlong: Double; var window: Double }

    /// bbox = (ouest, sud, est, nord), 2° max de côté.
    static func fuel(bbox: (Double, Double, Double, Double)) async throws -> FuelResponse {
        try await API.get("along/fuel?bbox=\(box(bbox))")
    }

    static func ev(bbox: (Double, Double, Double, Double)) async throws -> EvResponse {
        try await API.get("along/ev?bbox=\(box(bbox))")
    }

    static func fuelOnRoute(_ line: [CLLocationCoordinate2D], maxDist: Double = 1000) async throws -> FuelResponse {
        try await API.post("along/fuel/route", body: LineBody(points: thin(line), maxDist: maxDist))
    }

    static func evOnRoute(_ line: [CLLocationCoordinate2D], maxDist: Double = 1500) async throws -> EvResponse {
        try await API.post("along/ev/route", body: LineBody(points: thin(line), maxDist: maxDist, minKw: 7))
    }

    static func restAhead(_ line: [CLLocationCoordinate2D], fromAlong: Double, window: Double = 40_000) async throws -> RestResponse {
        try await API.post("along/rest/route", body: RestBody(points: thin(line), fromAlong: max(0, fromAlong), window: window))
    }

    private static func box(_ b: (Double, Double, Double, Double)) -> String {
        [b.0, b.1, b.2, b.3].map { String(format: "%.4f", $0) }.joined(separator: ",")
    }

    /// Réduit un tracé à `max` points [lng, lat] (le serveur en accepte 600) en gardant les extrémités.
    static func thin(_ line: [CLLocationCoordinate2D], max: Int = 500) -> [[Double]] {
        let r5 = { (v: Double) in (v * 1e5).rounded() / 1e5 }
        guard line.count > max else { return line.map { [r5($0.longitude), r5($0.latitude)] } }
        let step = Double(line.count - 1) / Double(max - 1)
        return (0..<max).map { i in
            let c = line[Int((Double(i) * step).rounded())]
            return [r5(c.longitude), r5(c.latitude)]
        }
    }
}
