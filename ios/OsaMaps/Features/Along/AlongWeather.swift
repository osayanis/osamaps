import Foundation
import CoreLocation

/// Météo prévue à l'heure de passage en quelques points du tracé (Open-Meteo, sans clé). Port de `weather.ts`.
struct AlongWeatherPoint: Sendable, Hashable {
    /// Fraction du trajet (0 = départ, 1 = arrivée).
    var at: Double
    /// Mètres depuis le départ.
    var along: Double
    var lat: Double
    var lng: Double
    /// Heure de passage prévue.
    var time: Date
    var temp: Double
    /// mm sur l'heure.
    var precip: Double
    /// cm sur l'heure.
    var snow: Double
    var code: Int
    /// Probabilité de précipitations (%).
    var prob: Double?
}

struct AlongWeatherHazard: Sendable {
    enum Kind: Int, Sendable { case ice, snow, storm, rain, fog }
    var kind: Kind
    /// Pour l'aperçu : « Risque de verglas vers 15:30 (0 °C) ».
    var text: String
    /// Pour l'alerte de conduite (le guidage ajoute la distance) : « Risque de verglas ».
    var short: String
    var point: AlongWeatherPoint
    var tone: DriveAlert.Tone
}

struct AlongRouteWeather: Sendable {
    var routeId: String
    var points: [AlongWeatherPoint]
    var arrivalNow: (temp: Double, code: Int, precip: Double)?
    var hazard: AlongWeatherHazard?
    var fetchedAt: Date
}

enum AlongWeather {
    private struct OmLocation: Decodable {
        struct Current: Decodable { var temperature_2m: Double?; var weather_code: Int?; var precipitation: Double? }
        struct Hourly: Decodable {
            var time: [Double]
            var temperature_2m: [Double?]
            var precipitation: [Double?]
            var snowfall: [Double?]
            var weather_code: [Int?]
            var precipitation_probability: [Double?]?
        }
        var current: Current?
        var hourly: Hourly?
    }

    struct Incomplete: LocalizedError { var errorDescription: String? { "météo incomplète" } }

    static func fetch(route: Route, departAt: Date = .now) async throws -> AlongRouteWeather {
        let line = route.coordinates
        let cum = Geo.cumulative(line)
        let total = (cum.last ?? 0) > 0 ? cum.last! : route.distance
        let fractions: [Double] = total > 80_000 ? [0, 0.25, 0.5, 0.75, 1] : [0, 0.5, 1]
        let pts = fractions.map { f -> (Double, Double, CLLocationCoordinate2D, Date) in
            let d = total * f
            return (f, d, Geo.along(line, cum, d), departAt.addingTimeInterval(route.duration * f))
        }
        var c = URLComponents(url: External.weather, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "latitude", value: pts.map { String(format: "%.3f", $0.2.latitude) }.joined(separator: ",")),
            .init(name: "longitude", value: pts.map { String(format: "%.3f", $0.2.longitude) }.joined(separator: ",")),
            .init(name: "hourly", value: "temperature_2m,precipitation,snowfall,weather_code,precipitation_probability"),
            .init(name: "current", value: "temperature_2m,weather_code,precipitation"),
            .init(name: "timezone", value: "UTC"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "forecast_days", value: "3"),
        ]
        let (data, resp) = try await API.session.data(from: c.url!)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw API.HTTPError(status: h.statusCode, message: "météo")
        }
        let locs: [OmLocation]
        if let arr = try? API.decoder.decode([OmLocation].self, from: data) { locs = arr } else { locs = [try API.decoder.decode(OmLocation.self, from: data)] }

        var points: [AlongWeatherPoint] = []
        for (i, p) in pts.enumerated() {
            guard locs.indices.contains(i), let h = locs[i].hourly, !h.time.isEmpty else { throw Incomplete() }
            // l'heure dont le milieu est le plus proche de l'heure de passage
            let target = p.3.timeIntervalSince1970
            var k = 0, best = Double.infinity
            for (j, t) in h.time.enumerated() { let d = abs(t + 1800 - target); if d < best { best = d; k = j } }
            func at<T>(_ a: [T?]?, _ def: T) -> T { guard let a, a.indices.contains(k) else { return def }; return a[k] ?? def }
            points.append(AlongWeatherPoint(at: p.0, along: p.1, lat: p.2.latitude, lng: p.2.longitude, time: p.3,
                                            temp: at(h.temperature_2m, 0), precip: at(h.precipitation, 0), snow: at(h.snowfall, 0),
                                            code: at(h.weather_code, 0), prob: h.precipitation_probability.flatMap { $0.indices.contains(k) ? $0[k] : nil }))
        }
        let cur = locs.last?.current
        let now: (Double, Int, Double)? = cur.flatMap { c in c.temperature_2m.map { ($0, c.weather_code ?? 0, c.precipitation ?? 0) } }
        return AlongRouteWeather(routeId: route.id, points: points,
                                 arrivalNow: now.map { (temp: $0.0, code: $0.1, precip: $0.2) },
                                 hazard: findHazard(points), fetchedAt: .now)
    }

    // Codes WMO utilisés par Open-Meteo.
    static let snowCodes: Set<Int> = [71, 73, 75, 77, 85, 86]
    static let freezingCodes: Set<Int> = [56, 57, 66, 67]
    static let stormCodes: Set<Int> = [95, 96, 99]
    static let heavyRainCodes: Set<Int> = [65, 82]
    static let fogCodes: Set<Int> = [45, 48]

    /// Le danger le plus sérieux du trajet (verglas > neige > orage > forte pluie > brouillard).
    static func findHazard(_ points: [AlongWeatherPoint]) -> AlongWeatherHazard? {
        func whereText(_ p: AlongWeatherPoint) -> String { p.at == 0 ? "au départ" : p.at == 1 ? "à l'arrivée" : "vers \(hour(p.time))" }
        var found: [AlongWeatherHazard] = []
        for p in points {
            let wet = p.precip >= 0.2 || (p.prob ?? 0) >= 60
            if freezingCodes.contains(p.code) || (p.temp <= 1 && wet && !snowCodes.contains(p.code)) {
                found.append(.init(kind: .ice, text: "Risque de verglas \(whereText(p)) (\(Int(p.temp.rounded())) °C)", short: "Risque de verglas", point: p, tone: .danger))
            } else if snowCodes.contains(p.code) || p.snow >= 0.2 {
                found.append(.init(kind: .snow, text: "Neige prévue \(whereText(p))", short: "Neige sur la route", point: p, tone: .danger))
            } else if stormCodes.contains(p.code) {
                found.append(.init(kind: .storm, text: "Orages prévus \(whereText(p))", short: "Orages sur la route", point: p, tone: .warn))
            } else if heavyRainCodes.contains(p.code) || p.precip >= 4 {
                found.append(.init(kind: .rain, text: "Forte pluie prévue \(whereText(p))", short: "Forte pluie sur la route", point: p, tone: .warn))
            } else if fogCodes.contains(p.code) {
                found.append(.init(kind: .fog, text: "Brouillard prévu \(whereText(p))", short: "Brouillard sur la route", point: p, tone: .warn))
            }
        }
        return found.sorted { ($0.kind.rawValue, $0.point.at) < ($1.kind.rawValue, $1.point.at) }.first
    }

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f
    }()
    static func hour(_ d: Date) -> String { hourFormatter.string(from: d) }

    /// Libellé court d'un code météo WMO.
    static func label(_ code: Int) -> String {
        switch code {
        case 0: "Ciel dégagé"
        case 1...2: "Quelques nuages"
        case 3: "Couvert"
        case _ where fogCodes.contains(code): "Brouillard"
        case 51...55: "Bruine"
        case _ where freezingCodes.contains(code): "Pluie verglaçante"
        case 61...63: "Pluie"
        case 65: "Forte pluie"
        case _ where snowCodes.contains(code): "Neige"
        case 80...81: "Averses"
        case 82: "Fortes averses"
        case _ where stormCodes.contains(code): "Orage"
        default: "Temps variable"
        }
    }

    /// Symbole SF pour un code WMO.
    static func symbol(_ code: Int) -> String {
        if code <= 1 { return "sun.max.fill" }
        if code <= 3 { return "cloud.fill" }
        if fogCodes.contains(code) { return "cloud.fog.fill" }
        if snowCodes.contains(code) { return "cloud.snow.fill" }
        if stormCodes.contains(code) { return "cloud.bolt.rain.fill" }
        if freezingCodes.contains(code) { return "cloud.sleet.fill" }
        return code >= 51 ? "cloud.rain.fill" : "cloud.fill"
    }
}
