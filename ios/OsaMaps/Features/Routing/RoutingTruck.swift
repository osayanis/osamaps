import Foundation

/// Règles poids lourds (France) utilisées par les itinéraires et le guidage.
///
/// Vitesses — Code de la route :
///  R413-8 (PTAC ou PTRA > 3,5 t, hors transport en commun) :
///    90 km/h autoroute ; 80 km/h routes à caractère prioritaire (relevée à 90 km/h pour ≤ 12 t sur les routes
///    à deux chaussées séparées par un terre-plein central) ; 80 km/h autres routes (abaissée à 60 km/h pour les
///    véhicules articulés ou avec remorque > 12 t) ; 50 km/h en agglomération (70 sur le périphérique parisien).
///  R413-9 (matières dangereuses > 12 t, et transports exceptionnels R433-1) :
///    80 km/h autoroute ; 60 km/h autres routes (70 sur routes prioritaires pour certains véhicules agréés) ;
///    50 km/h en agglomération.
///  La limite affichée = la plus basse entre la limite de la route (OSM, voitures), la limite poids lourds
///  explicite (maxspeed:hgv) et le plafond de la catégorie ci-dessus.
///  Approximation (Valhalla ne dit pas si une route est « à caractère prioritaire » ni si elle est en
///  agglomération) : trunk / primary / secondary = route prioritaire, les autres = « autres routes » ;
///  l'agglomération est déjà portée par la limite OSM (≤ 50).
///
/// Interdictions de circuler (véhicules de transport de marchandises > 7,5 t de PTAC, arrêté du 16 avril 2021 +
/// arrêté du 26 décembre 2025 pour le calendrier 2026, brochure Bison Futé « Calendrier 2026 ») :
///  samedis et veilles de fêtes 22 h → 24 h ; dimanches et jours fériés 0 h → 22 h ; samedi férié ou dimanche veille
///  de fête : toute la journée ; + samedis d'été (2026 : 11, 18, 25 juillet, 1er et 8 août, 7 h → 19 h) ;
///  + hiver en Auvergne-Rhône-Alpes sur certains axes alpins (2026 : 7, 14, 21, 28 février, 7 mars, 7 h → 18 h).
enum RoutingTruck {

    // MARK: Vitesses

    /// Vitesse maximale du véhicule pour le calcul des durées (Valhalla `top_speed`).
    /// Limiteur obligatoire des poids lourds : 90 km/h ; convoi exceptionnel : 80 km/h (R413-9).
    static func topSpeed(_ v: Vehicle) -> Int {
        switch v.kind {
        case .car: 130
        case .superheavy: 80
        case .truck, .heavy: v.hazmat && v.weight > 12 ? 80 : 90
        }
    }

    enum RoadCategory { case motorway, divided, priority, other }

    static func category(roadClass rc: String?, car: Int?) -> RoadCategory {
        switch rc {
        case "motorway": return .motorway
        // voie rapide à 110 / 2×2 voies : chaussées séparées
        case "trunk": return (car ?? 0) >= 100 ? .divided : .priority
        case "primary": return (car ?? 0) >= 100 ? .divided : .priority
        case "secondary": return .priority
        case nil:
            // pas de classe (ancien serveur) : on la devine à partir de la limite voitures
            guard let car else { return .priority }
            return car >= 130 ? .motorway : car >= 100 ? .divided : .priority
        default: return .other
        }
    }

    /// Plafond réglementaire du véhicule pour une catégorie de route (km/h), nil pour une voiture.
    static func cap(_ v: Vehicle, _ c: RoadCategory) -> Int? {
        guard v.isTruck else { return nil }
        // R413-9 : matières dangereuses > 12 t et transports exceptionnels
        if v.kind == .superheavy || (v.hazmat && v.weight > 12) {
            return c == .motorway ? 80 : 60
        }
        // R413-8
        let light = v.weight <= 12
        switch c {
        case .motorway: return 90
        case .divided: return light ? 90 : 80
        case .priority: return 80
        // « autres routes » : 60 pour les ensembles articulés / avec remorque > 12 t (semi-remorque)
        case .other: return v.kind == .heavy && !light ? 60 : 80
        }
    }

    /// Limite à afficher pour un tronçon.
    static func limit(car: Int?, hgv: Int?, roadClass: String?, vehicle v: Vehicle) -> Int? {
        guard v.isTruck else { return car }
        let c = category(roadClass: roadClass, car: car)
        var out = [car, hgv].compactMap { $0 }.min()
        // limite inconnue : on n'invente rien, sauf sur autoroute où le plafond PL s'applique toujours
        guard out != nil || c == .motorway else { return nil }
        if let cap = cap(v, c) { out = min(out ?? cap, cap) }
        return out
    }

    // MARK: Interdictions de circuler (> 7,5 t)

    /// Le véhicule est concerné par les interdictions de circuler du week-end et des fêtes.
    static func bansApply(_ v: Vehicle) -> Bool { v.isTruck && v.weight > 7.5 }

    struct Ban: Equatable, Sendable {
        var start: Date
        var end: Date
        /// « samedi 11 juillet, 7 h – 19 h », « du samedi 22 h au dimanche 22 h »…
        var label: String
        /// Interdiction régionale (certains axes seulement).
        var regional: String?
    }

    private static let paris = TimeZone(identifier: "Europe/Paris")!
    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = paris
        c.locale = Locale(identifier: "fr_FR")
        return c
    }

    /// Années dont le calendrier complémentaire (samedis d'été, hiver Auvergne-Rhône-Alpes) est connu.
    static let calendarYears: Set<Int> = [2026]
    /// Samedis d'été, tout le réseau, 7 h → 19 h (arrêté du 26/12/2025).
    private static let summerSaturdays: [Int: [(Int, Int)]] = [2026: [(7, 11), (7, 18), (7, 25), (8, 1), (8, 8)]]
    /// Samedis d'hiver, certains axes d'Auvergne-Rhône-Alpes, 7 h → 18 h.
    private static let winterAURA: [Int: [(Int, Int)]] = [2026: [(2, 7), (2, 14), (2, 21), (2, 28), (3, 7)]]

    /// Dimanche de Pâques (algorithme de Meeus / Butcher).
    static func easter(_ y: Int) -> DateComponents {
        let a = y % 19, b = y / 100, c = y % 100, d = b / 4, e = b % 4
        let f = (b + 8) / 25, g = (b - f + 1) / 3, h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31, day = (h + l - 7 * m + 114) % 31 + 1
        return DateComponents(year: y, month: month, day: day)
    }

    /// Jours fériés en France métropolitaine (ceux retenus par les interdictions de circuler).
    static func isHoliday(_ day: Date) -> Bool {
        let c = cal
        let comps = c.dateComponents([.year, .month, .day], from: day)
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return false }
        let fixed: [(Int, Int)] = [(1, 1), (5, 1), (5, 8), (7, 14), (8, 15), (11, 1), (11, 11), (12, 25)]
        if fixed.contains(where: { $0.0 == m && $0.1 == d }) { return true }
        guard let e = c.date(from: easter(y)) else { return false }
        for offset in [1, 39, 50] { // lundi de Pâques, Ascension, lundi de Pentecôte
            if let h = c.date(byAdding: .day, value: offset, to: e), c.isDate(h, inSameDayAs: day) { return true }
        }
        return false
    }

    /// Plages interdites d'une journée (heures locales, [début, fin[ en heures).
    static func dayBans(_ day: Date) -> [(from: Int, to: Int, regional: String?)] {
        let c = cal
        let wd = c.component(.weekday, from: day) // 1 = dimanche, 7 = samedi
        let hol = isHoliday(day)
        let nextHol = c.date(byAdding: .day, value: 1, to: day).map(isHoliday) ?? false
        let sat = wd == 7, sun = wd == 1
        var out: [(Int, Int, String?)] = []
        if (sat && hol) || (sun && nextHol) {
            out.append((0, 24, nil))
        } else {
            if sun || hol { out.append((0, 22, nil)) }
            if sat || nextHol { out.append((22, 24, nil)) }
        }
        let comps = c.dateComponents([.year, .month, .day], from: day)
        if let y = comps.year, let m = comps.month, let d = comps.day {
            if summerSaturdays[y]?.contains(where: { $0.0 == m && $0.1 == d }) == true { out.append((7, 19, nil)) }
            if winterAURA[y]?.contains(where: { $0.0 == m && $0.1 == d }) == true {
                out.append((7, 18, "certains axes alpins d'Auvergne-Rhône-Alpes"))
            }
        }
        return out
    }

    /// Interdictions qui chevauchent le trajet [départ, arrivée] (plages accolées fusionnées).
    static func bans(from start: Date, to end: Date) -> [Ban] {
        let c = cal
        var raw: [(Date, Date, String?)] = []
        var day = c.startOfDay(for: start).addingTimeInterval(-86_400) // la veille : une plage peut déborder
        while day <= end {
            for b in dayBans(day) {
                guard let s = c.date(byAdding: .hour, value: b.from, to: day),
                      let e = c.date(byAdding: .hour, value: b.to, to: day) else { continue }
                raw.append((s, e, b.regional))
            }
            day = c.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        raw.sort { $0.0 < $1.0 }
        // fusion des plages nationales qui se suivent (samedi 22 h → dimanche 22 h)
        var merged: [(Date, Date, String?)] = []
        for r in raw {
            if let last = merged.last, last.2 == nil, r.2 == nil, r.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, r.1)
            } else {
                merged.append(r)
            }
        }
        return merged
            .filter { $0.0 < end && $0.1 > start }
            .map { Ban(start: $0.0, end: $0.1, label: label($0.0, $0.1), regional: $0.2) }
    }

    private static func label(_ s: Date, _ e: Date) -> String {
        let c = cal
        let day = Date.FormatStyle(date: .omitted, time: .omitted).weekday(.wide).day().month(.wide)
            .locale(Locale(identifier: "fr_FR"))
        var dayStyle = day
        dayStyle.timeZone = paris
        func h(_ d: Date) -> String {
            let comps = c.dateComponents([.hour, .minute], from: d)
            let hh = comps.hour ?? 0
            return comps.minute ?? 0 == 0 ? "\(hh == 0 && d == e ? 24 : hh) h" : String(format: "%d h %02d", hh, comps.minute ?? 0)
        }
        // fin à minuit pile : on parle de « 24 h » le jour même
        let endDay = c.date(byAdding: .second, value: -1, to: e) ?? e
        if c.isDate(s, inSameDayAs: endDay) {
            return "\(s.formatted(dayStyle)), \(h(s)) – \(h(e))"
        }
        return "du \(s.formatted(dayStyle)) \(h(s)) au \(endDay.formatted(dayStyle)) \(h(e))"
    }
}
