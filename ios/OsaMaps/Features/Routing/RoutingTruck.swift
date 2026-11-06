import Foundation

/// Règles poids lourds (France) utilisées par les itinéraires et le guidage.
///
/// Vitesses — Code de la route :
///  R413-8 (PTAC ou PTRA > 3,5 t, hors transport en commun) :
///    90 km/h autoroute ; 80 km/h routes à caractère prioritaire (relevée à 90 km/h pour ≤ 12 t sur les routes
///    à deux chaussées séparées par un terre-plein central) ; 80 km/h autres routes (abaissée à 60 km/h pour les
///    véhicules articulés ou avec remorque > 12 t) ; 50 km/h en agglomération (70 sur le périphérique parisien).
///  R413-9 (matières dangereuses > 12 t, et transports exceptionnels R433-1) :
///    80 km/h autoroute ; 60 km/h autres routes (70 sur routes prioritaires pour certains véhicules agréés :
///    arrêté non identifié, on garde 60) ; 50 km/h en agglomération.
///  Transports exceptionnels, arrêté du 4 mai 2006 (art. 3 catégories, art. 14 vitesses) :
///    1re cat. (≤ 20 m, ≤ 3 m, ≤ 48 t) : R413-9 ; 2e (≤ 25 m, ≤ 4 m, ≤ 72 t) : R413-9 mais 40 en agglomération ;
///    3e (au-delà) : 60 autoroute, 50 route, 30 agglomération. L'autorisation préfectorale prime toujours.
///  La limite affichée = la plus basse entre la limite de la route (OSM, voitures), la limite poids lourds
///  explicite (maxspeed:hgv) et le plafond de la catégorie ci-dessus.
///  Approximation (Valhalla ne dit pas si une route est « à caractère prioritaire » ni si elle est en
///  agglomération) : trunk / primary / secondary = route prioritaire, les autres = « autres routes » ;
///  l'agglomération est déjà portée par la limite OSM (≤ 50).
///
/// Interdictions de circuler (véhicules de transport de marchandises > 7,5 t de PTAC) — arrêté du 16 avril 2021
/// (art. 1 et 2) + arrêté du 26 décembre 2025 (calendrier 2026, JO du 08/01/2026) :
///  samedis et veilles de fêtes 22 h → 24 h ; dimanches et jours fériés 0 h → 22 h ; samedi férié ou dimanche veille
///  de fête : toute la journée ;
///  samedis d'été (2026 : 11, 18, 25 juillet, 1er et 8 août) : 7 h → 19 h, qui REMPLACE le 22 h → 24 h ;
///  hiver en Auvergne-Rhône-Alpes, certains axes alpins (2026 : 7, 14, 21, 28 février, 7 mars) : 7 h → 18 h + 22 h → 24 h.
///  Île-de-France (art. 3), sur A6a/A6b jusqu'à la RN104, A106, A10 jusqu'à la RN20, A13 jusqu'à Poissy-Orgeval,
///  A12 de Rocquencourt à la RN10 : Paris → province vendredi 16-21 h, veille de fête 16-22 h, samedi 10-18 h,
///  dimanche et férié 22-24 h ; province → Paris lundi ou lendemain de fête 6-10 h, dimanche et férié 22-24 h.
///  Approximation : tronçon = manœuvre sur ces autoroutes dans un cadre autour de Paris, sens = s'éloigne de Paris ou non.
///  Non géré : les jours fériés locaux d'Alsace-Moselle.
enum RoutingTruck {

    // MARK: Vitesses

    /// Vitesse maximale du véhicule pour le calcul des durées (Valhalla `top_speed`).
    /// Limiteur obligatoire des poids lourds : 90 km/h ; convoi exceptionnel : 80 km/h (R413-9).
    static func topSpeed(_ v: Vehicle) -> Int {
        switch v.kind {
        case .car: 130
        case .superheavy: convoyCategory(v) == 3 ? 60 : 80
        case .truck, .heavy: v.hazmat && v.weight > 12 ? 80 : 90
        }
    }

    /// Catégorie de transport exceptionnel (arrêté du 4 mai 2006, art. 3) : la caractéristique la plus forte classe.
    static func convoyCategory(_ v: Vehicle) -> Int {
        if v.length > 25 || v.width > 4 || v.weight > 72 { return 3 }
        if v.length > 20 || v.width > 3 || v.weight > 48 { return 2 }
        return 1
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
        // transports exceptionnels : arrêté du 4 mai 2006, art. 14 (3e catégorie plus lente)
        if v.kind == .superheavy {
            if convoyCategory(v) == 3 { return c == .motorway ? 60 : 50 }
            return c == .motorway ? 80 : 60
        }
        // R413-9 : matières dangereuses > 12 t
        if v.hazmat && v.weight > 12 { return c == .motorway ? 80 : 60 }
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
        // agglomération (limite ≤ 50) : convois de 2e catégorie à 40, de 3e à 30
        if v.kind == .superheavy, let o = out, o <= 50, convoyCategory(v) >= 2 {
            out = min(o, convoyCategory(v) == 3 ? 30 : 40)
        }
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
            // samedi d'été (non férié) : 7 h → 19 h remplace le 22 h → 24 h (art. 2), circulation libre après 19 h
            if summerSaturdays[y]?.contains(where: { $0.0 == m && $0.1 == d }) == true, !hol {
                out.removeAll { $0.0 == 22 && $0.1 == 24 && !nextHol }
                out.append((7, 19, nil))
            }
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

    // MARK: Île-de-France (art. 3)

    enum IdfDir: Sendable { case out, into }
    /// Passage sur les autoroutes d'Île-de-France : secondes après le départ.
    struct IdfPass: Sendable { var dir: IdfDir; var from: Double; var to: Double }

    private static let parisCenter = Coord(lat: 48.8566, lng: 2.3522)
    private static func inIdf(_ c: Coord) -> Bool { c.lat > 48.62 && c.lat < 48.98 && c.lng > 1.98 && c.lng < 2.56 }
    private static func isIdfRoad(_ street: String?) -> Bool {
        guard let s = street?.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: " ", with: "") else { return false }
        return ["A6", "A6A", "A6B", "A10", "A12", "A13", "A106"].contains(s)
    }

    static func idfPassages(_ r: Route) -> [IdfPass] {
        var out: [IdfPass] = []
        var t = 0.0
        for (i, m) in r.maneuvers.enumerated() {
            let t0 = t
            t += m.time
            guard isIdfRoad(m.street), m.shapeIndex < r.coords.count else { continue }
            let end = min(i + 1 < r.maneuvers.count ? r.maneuvers[i + 1].shapeIndex : r.coords.count - 1, r.coords.count - 1)
            guard end > m.shapeIndex else { continue }
            var d = 0.0
            var first: (d: Double, p: Coord)?, last: (d: Double, p: Coord)?
            for k in m.shapeIndex...end {
                if k > m.shapeIndex { d += Geo.distance(r.coords[k - 1].coordinate, r.coords[k].coordinate) }
                if inIdf(r.coords[k]) {
                    if first == nil { first = (d, r.coords[k]) }
                    last = (d, r.coords[k])
                }
            }
            guard let first, let last, d > 0 else { continue }
            let gap = Geo.distance(parisCenter.coordinate, last.p.coordinate) - Geo.distance(parisCenter.coordinate, first.p.coordinate)
            guard abs(gap) >= 500 else { continue }
            let dir: IdfDir = gap > 0 ? .out : .into
            let from = t0 + m.time * first.d / d, to = t0 + m.time * last.d / d
            if let prev = out.last, prev.dir == dir, from - prev.to < 120 {
                out[out.count - 1].to = to
            } else {
                out.append(IdfPass(dir: dir, from: from, to: to))
            }
        }
        return out
    }

    /// Plages propres à l'Île-de-France (en plus du régime national), heures locales.
    static func idfDayBans(_ day: Date, _ dir: IdfDir) -> [(from: Int, to: Int)] {
        let c = cal
        let wd = c.component(.weekday, from: day) // 1 = dimanche
        let next = { (n: Int) in c.date(byAdding: .day, value: n, to: day).map(isHoliday) ?? false }
        let hol = isHoliday(day), nextHol = next(1), prevHol = next(-1)
        let offDay = wd == 1 || hol
        // veille de fête : y compris le samedi avant le dimanche de Pâques / de Pentecôte (calendrier officiel)
        let eve = nextHol || (wd == 7 && next(2))
        var out: [(Int, Int)] = []
        if offDay { out.append((22, 24)) }
        switch dir {
        case .out:
            if wd == 6 && !hol { out.append((16, 21)) }
            if wd == 7 && !hol { out.append((10, 18)) }
            if eve && !offDay { out.append((16, 22)) }
        case .into:
            if !offDay && (wd == 2 || prevHol) { out.append((6, 10)) }
        }
        // plages qui se chevauchent fusionnées (samedi veille de Pâques : 10-18 h + 16-22 h → 10-22 h)
        var merged: [(from: Int, to: Int)] = []
        for w in out.sorted(by: { $0.0 < $1.0 }) {
            if let l = merged.last, w.0 <= l.to { merged[merged.count - 1].to = max(l.to, w.1) } else { merged.append((w.0, w.1)) }
        }
        return merged
    }

    private static func idfLabel(_ d: IdfDir) -> String {
        d == .out ? "les autoroutes de sortie d'Île-de-France vers la province" : "les autoroutes d'entrée en Île-de-France vers Paris"
    }

    /// Interdictions d'Île-de-France qui tombent pendant les passages du trajet sur ces autoroutes.
    static func idfBans(start: Date, passes: [IdfPass]) -> [Ban] {
        let c = cal
        var res: [Ban] = []
        for p in passes {
            let a = start.addingTimeInterval(p.from), b = start.addingTimeInterval(p.to + 60)
            var day = c.startOfDay(for: a)
            while day <= b {
                for w in idfDayBans(day, p.dir) {
                    guard let s = c.date(byAdding: .hour, value: w.from, to: day),
                          let e = c.date(byAdding: .hour, value: w.to, to: day) else { continue }
                    let lab = idfLabel(p.dir)
                    if s < b, e > a, !res.contains(where: { $0.start == s && $0.regional == lab }) {
                        res.append(Ban(start: s, end: e, label: label(s, e), regional: lab))
                    }
                }
                day = c.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            }
        }
        return res
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
