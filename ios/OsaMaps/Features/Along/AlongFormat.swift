import Foundation

/// Formats et calculs de prix (port de `format.ts` et `suggest.ts`).
enum AlongFormat {
    /// Un prix est « frais » s'il a été mis à jour il y a moins de 10 jours (sinon on ne le met pas en avant).
    static let freshInterval: TimeInterval = 10 * 24 * 3600

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoLocal: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Paris")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return iso.date(from: s) ?? isoLocal.date(from: String(s.prefix(19)))
    }

    /// « 2,139 »
    static func price3(_ p: Double) -> String { String(format: "%.3f", p).replacingOccurrences(of: ".", with: ",") }

    /// « 8,40 € », « 23 € »
    static func euros(_ v: Double) -> String {
        v < 10 ? String(format: "%.2f €", v).replacingOccurrences(of: ".", with: ",") : "\(Int(v.rounded())) €"
    }

    /// « 6,5 »
    static func decimal(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    }

    static func isFresh(_ maj: String?, now: Date = .now) -> Bool {
        guard let d = date(maj) else { return false }
        return now.timeIntervalSince(d) < freshInterval
    }

    /// Prix utilisable pour mon carburant (présent, frais, pas en rupture).
    static func usablePrice(_ s: AlongFuelStation, _ e: AlongEnergy, now: Date = .now) -> Double? {
        guard let pr = s.price(e), !s.isShort(e), isFresh(pr.maj, now: now) else { return nil }
        return pr.p
    }

    /// « à l'instant », « il y a 25 min », « il y a 2 h », « il y a 3 j », « il y a 4 mois ».
    static func ago(_ s: String?, now: Date = .now) -> String {
        guard let d = date(s) else { return "date inconnue" }
        let min = max(0, Int((now.timeIntervalSince(d) / 60).rounded()))
        if min < 2 { return "à l'instant" }
        if min < 60 { return "il y a \(min) min" }
        let h = Int((Double(min) / 60).rounded())
        if h < 24 { return "il y a \(h) h" }
        let days = Int((Double(h) / 24).rounded())
        if days < 45 { return "il y a \(days) j" }
        return "il y a \(Int((Double(days) / 30).rounded())) mois"
    }

    /// État d'ouverture à l'instant : « Ouvert jusqu'à 19:00 », « Fermé · ouvre à 07:00 »…
    static func openState(_ s: AlongFuelStation, now: Date = .now) -> (open: Bool?, text: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let wd = cal.component(.weekday, from: now) // 1 = dimanche
        let day = (wd + 5) % 7                      // lundi = 0
        let hm = String(format: "%02d:%02d", cal.component(.hour, from: now), cal.component(.minute, from: now))
        let today: [[String]]?? = s.hours.flatMap { $0.indices.contains(day) ? $0[day] : nil }
        if case let .some(.some(slots)) = today {
            let pairs = slots.filter { $0.count == 2 }
            if !pairs.isEmpty {
                if let slot = pairs.first(where: { $0[0] <= hm && hm < $0[1] }) {
                    return (true, "Ouvert jusqu'à \(slot[1])" + (s.h24 ? " · automate 24 h/24" : ""))
                }
                if s.h24 { return (true, "Boutique fermée · automate 24 h/24") }
                if let next = pairs.first(where: { $0[0] > hm }) { return (false, "Fermé · ouvre à \(next[0])") }
                return (false, "Fermé pour aujourd'hui")
            }
            return s.h24 ? (true, "Automate 24 h/24 (boutique fermée)") : (false, "Fermé aujourd'hui")
        }
        if s.h24 { return (true, "Automate 24 h/24") }
        return (nil, "Horaires non communiqués")
    }

    // MARK: - Suggestions

    struct Pick { var station: AlongFuelStation; var price: Double; var ahead: Double }

    /// Stations devant (au moins 300 m après `fromAlong`) avec un prix frais, triées par prix puis par détour.
    static func rankOnRoute(_ stations: [AlongFuelStation], _ e: AlongEnergy, fromAlong: Double = 0) -> [Pick] {
        let now = Date.now
        return stations.compactMap { s -> Pick? in
            guard let a = s.along, a >= fromAlong + 300, let p = usablePrice(s, e, now: now) else { return nil }
            return Pick(station: s, price: p, ahead: a - fromAlong)
        }
        .sorted { ($0.price, $0.station.offset ?? 0) < ($1.price, $1.station.offset ?? 0) }
    }

    /// Prix médian (frais) de mon carburant, ou nil.
    static func medianPrice(_ stations: [AlongFuelStation], _ e: AlongEnergy) -> Double? {
        let now = Date.now
        let v = stations.compactMap { usablePrice($0, e, now: now) }.sorted()
        guard !v.isEmpty else { return nil }
        let m = v.count / 2
        return v.count % 2 == 1 ? v[m] : (v[m - 1] + v[m]) / 2
    }

    /// Ids des stations les moins chères (prix frais, égalités comprises), pour les mettre en vert.
    static func cheapestIds(_ stations: [AlongFuelStation], _ e: AlongEnergy) -> Set<String> {
        let now = Date.now
        let prices = stations.compactMap { s in usablePrice(s, e, now: now).map { (s.id, $0) } }
        guard let min = prices.map(\.1).min() else { return [] }
        return Set(prices.filter { $0.1 <= min + 1e-9 }.map(\.0))
    }

    static let dayShort = ["Lun", "Mar", "Mer", "Jeu", "Ven", "Sam", "Dim"]
}
