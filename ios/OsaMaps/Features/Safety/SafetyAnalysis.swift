import Foundation
import CoreLocation

/// Analyse d'un itinéraire (port de `analysis.ts`) : tout est exprimé en « distance le long du tracé »
/// (mètres depuis le départ), ce qui rend les alertes en conduite triviales (on compare à la distance parcourue).
/// Fonctions pures, appelables hors du MainActor.

struct SafetyDanger: Hashable, Sendable {
    var id: String
    var start: Double
    var end: Double
    var kind: String
}

struct SafetyCurve: Hashable, Sendable {
    var id: String
    var start: Double
    var end: Double
    var radius: Double
    var angle: Double
    /// Virages enchaînés (lacets).
    var count: Int
}

struct SafetyRoutePoi: Hashable, Sendable {
    enum Kind: String, Sendable { case levelCrossing = "level-crossing", school }
    var id: String
    var along: Double
    var kind: Kind
}

struct SafetyZfeCrossing: Hashable, Sendable {
    var entry: Double
    var exit: Double
    var props: SafetyZfeProps
}

/// Index spatial des segments du tracé (cellules de ~2 km).
struct SafetySegIndex: Sendable {
    struct Cell: Hashable, Sendable { var x: Int; var y: Int }
    static let cell = 0.02

    let coords: [CLLocationCoordinate2D]
    let cum: [Double]
    let cells: [Cell: [Int]]

    init(coords: [CLLocationCoordinate2D], cum: [Double]) {
        self.coords = coords
        self.cum = cum
        var cells: [Cell: [Int]] = [:]
        let c = Self.cell
        for i in coords.indices.dropFirst() {
            let a = coords[i - 1], b = coords[i]
            for x in Int(floor(min(a.longitude, b.longitude) / c))...Int(floor(max(a.longitude, b.longitude) / c)) {
                for y in Int(floor(min(a.latitude, b.latitude) / c))...Int(floor(max(a.latitude, b.latitude) / c)) {
                    cells[Cell(x: x, y: y), default: []].append(i)
                }
            }
        }
        self.cells = cells
    }

    var total: Double { cum.last ?? 0 }

    /// Segments (index de fin i : segment i-1 → i) dont la cellule touche le disque (centre, rayon m).
    func segmentsNear(_ c: CLLocationCoordinate2D, _ r: Double) -> [Int] {
        let dLat = r / SafetyGeo.mPerDeg, dLng = r / (SafetyGeo.mPerDeg * cos(c.latitude * .pi / 180))
        let k = Self.cell
        var out = Set<Int>()
        for x in Int(floor((c.longitude - dLng) / k))...Int(floor((c.longitude + dLng) / k)) {
            for y in Int(floor((c.latitude - dLat) / k))...Int(floor((c.latitude + dLat) / k)) {
                if let list = cells[Cell(x: x, y: y)] { out.formUnion(list) }
            }
        }
        return out.sorted()
    }
}

enum SafetyAnalysis {
    /// Géométrie plane locale autour de c (mètres).
    private static func local(_ c: CLLocationCoordinate2D) -> (CLLocationCoordinate2D) -> (Double, Double) {
        let kx = SafetyGeo.mPerDeg * cos(c.latitude * .pi / 180)
        return { p in ((p.longitude - c.longitude) * kx, (p.latitude - c.latitude) * SafetyGeo.mPerDeg) }
    }

    /// Distance (m) du point c au segment ab, et paramètre t de la projection.
    private static func segDist(_ c: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> (d: Double, t: Double) {
        let L = local(c)
        let (ax, ay) = L(a), (bx, by) = L(b)
        let dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy
        let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
        return (hypot(ax + t * dx, ay + t * dy), t)
    }

    /// Projette un point sur le tracé : distance au tracé et distance le long.
    static func project(_ ix: SafetySegIndex, _ p: CLLocationCoordinate2D, maxDist: Double) -> (offset: Double, along: Double)? {
        var best: (offset: Double, along: Double)?
        for i in ix.segmentsNear(p, maxDist) {
            let (d, t) = segDist(p, ix.coords[i - 1], ix.coords[i])
            if d <= maxDist, best == nil || d < best!.offset {
                best = (d, ix.cum[i - 1] + t * (ix.cum[i] - ix.cum[i - 1]))
            }
        }
        return best
    }

    // MARK: - Zones de danger

    /// Projection avec le segment touché (pour comparer les caps).
    private static func projectSeg(_ ix: SafetySegIndex, _ p: CLLocationCoordinate2D, maxDist: Double) -> (offset: Double, along: Double, seg: Int)? {
        var best: (offset: Double, along: Double, seg: Int)?
        for i in ix.segmentsNear(p, maxDist) {
            let (d, t) = segDist(p, ix.coords[i - 1], ix.coords[i])
            if d <= maxDist, best == nil || d < best!.offset {
                best = (d, ix.cum[i - 1] + t * (ix.cum[i] - ix.cum[i - 1]), i)
            }
        }
        return best
    }

    private static func heading(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let (x, y) = local(a)(b)
        return atan2(x, y) * 180 / .pi
    }

    /// Portions de l'itinéraire qui suivent une ligne de tronçon : on parcourt la ligne tous les 15 m, chaque
    /// point doit être à moins de 22 m du tracé ET rouler dans le même sens (écart de cap < 50° ; les deux
    /// sens pour une route à double sens). Une route qui ne fait que croiser le tronçon ne compte pas.
    static func lineOverlap(_ ix: SafetySegIndex, _ line: [CLLocationCoordinate2D], oneway: Bool) -> [(start: Double, end: Double)] {
        guard line.count >= 2 else { return [] }
        var lineLen = 0.0
        var out: [(start: Double, end: Double)] = []
        var run: (lo: Double, hi: Double)?
        var misses = 0
        func close() {
            if let r = run, r.hi - r.lo >= min(60, 0.5 * lineLen) { out.append((r.lo, r.hi)) }
            run = nil
        }
        for i in 1..<line.count { lineLen += Geo.distance(line[i - 1], line[i]) }
        for i in 1..<line.count {
            let a = line[i - 1], b = line[i]
            let len = Geo.distance(a, b)
            let h = heading(a, b)
            let n = max(1, Int(ceil(len / 15)))
            for k in 0...(i == line.count - 1 ? n : n - 1) {
                let t = Double(k) / Double(n)
                let p = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                               longitude: a.longitude + (b.longitude - a.longitude) * t)
                if let hit = projectSeg(ix, p, maxDist: 22) {
                    let diff = abs(angleDiff(heading(ix.coords[hit.seg - 1], ix.coords[hit.seg]), h))
                    if diff < 50 || (!oneway && diff > 130) {
                        run = run.map { (min($0.lo, hit.along), max($0.hi, hit.along)) } ?? (hit.along, hit.along)
                        misses = 0
                        continue
                    }
                }
                misses += 1
                if misses > 3 { close() } // un trou de plus de ~45 m coupe la portion
            }
        }
        close()
        return out
    }

    /// Zones de danger sur l'itinéraire, en distance le long du tracé.
    ///  - tronçon : la portion de l'itinéraire qui le parcourt (dans le sens de circulation si connu) ;
    ///  - disque de repli : la corde du disque sur le tracé si le tracé passe à moins de r/2 du centre (le
    ///    serveur garantit que l'appareil y est), allongée jusqu'à la longueur réglementaire (2r).
    static func dangerIntervals(_ ix: SafetySegIndex, _ zones: [SafetyZone]) -> [SafetyDanger] {
        let total = ix.total
        var raw: [SafetyDanger] = []
        for z in zones {
            if let r = z.radius {
                raw += diskIntervals(ix, z, r: r, total: total)
                continue
            }
            for line in z.lines {
                for p in lineOverlap(ix, line, oneway: z.oneway) {
                    raw.append(SafetyDanger(id: z.id, start: max(0, p.start), end: min(total, p.end), kind: z.kind))
                }
            }
        }
        // fusion des zones qui se chevauchent (deux appareils proches, deux chaussées = une seule zone)
        raw.sort { $0.start < $1.start }
        var out: [SafetyDanger] = []
        for z in raw {
            if let last = out.last, z.start <= last.end + 30 {
                out[out.count - 1].end = max(last.end, z.end)
            } else {
                out.append(z)
            }
        }
        return out
    }

    private static func diskIntervals(_ ix: SafetySegIndex, _ z: SafetyZone, r: Double, total: Double) -> [SafetyDanger] {
        let c = z.mid
        let L = local(c)
        var parts: [(start: Double, end: Double, minD: Double)] = []
        for i in ix.segmentsNear(c, r) {
            let a = ix.coords[i - 1], b = ix.coords[i]
            let (ax, ay) = L(a), (bx, by) = L(b)
            let dx = bx - ax, dy = by - ay
            let qa = dx * dx + dy * dy
            if qa == 0 { continue }
            let qb = 2 * (dx * ax + dy * ay)
            let qc = ax * ax + ay * ay - r * r
            let disc = qb * qb - 4 * qa * qc
            if disc < 0 { continue }
            let s = disc.squareRoot()
            let t0 = max(0, (-qb - s) / (2 * qa)), t1 = min(1, (-qb + s) / (2 * qa))
            if t0 >= t1 { continue }
            let len = ix.cum[i] - ix.cum[i - 1]
            let minD = segDist(c, a, b).d
            let start = ix.cum[i - 1] + t0 * len, end = ix.cum[i - 1] + t1 * len
            if let last = parts.last, start - last.end < 50 {
                parts[parts.count - 1].end = max(last.end, end)
                parts[parts.count - 1].minD = min(last.minD, minD)
            } else {
                parts.append((start, end, minD))
            }
        }
        var out: [SafetyDanger] = []
        for p in parts where p.minD <= r / 2 {
            var start = p.start, end = p.end
            let need = 2 * r - (end - start)
            if need > 0 { start -= need / 2; end += need / 2 }
            out.append(SafetyDanger(id: z.id, start: max(0, start), end: min(total, end), kind: z.kind))
        }
        return out
    }

    // MARK: - Virages serrés

    private static let turnTypes: Set<Int> = [9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 26, 27]

    private static func angleDiff(_ a: Double, _ b: Double) -> Double {
        (b - a + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    /// Virages serrés depuis la géométrie (mêmes seuils que la version web) : rééchantillonnage tous les
    /// 10 m, rayon de courbure estimé sur une fenêtre de 50 m (< 120 m), angle total ≥ 40°. Les changements
    /// de direction aux intersections (manœuvres) et dans les ronds-points sont ignorés ; des virages à
    /// moins de 200 m l'un de l'autre forment une seule alerte « Virages serrés ».
    static func findCurves(_ route: Route, _ cum: [Double]) -> [SafetyCurve] {
        let coords = route.coordinates
        let total = cum.last ?? 0
        guard coords.count >= 3, total >= 200 else { return [] }
        let step = 10.0, w = 5
        var pts: [CLLocationCoordinate2D] = []
        var j = 1
        var d = 0.0
        while d <= total {
            while j < cum.count - 1 && cum[j] < d { j += 1 }
            let seg = cum[j] - cum[j - 1]
            let t = (d - cum[j - 1]) / (seg != 0 ? seg : 1)
            let a = coords[j - 1], b = coords[j]
            pts.append(.init(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t))
            d += step
        }
        guard pts.count > 1 else { return [] }
        var head: [Double] = []
        head.reserveCapacity(pts.count)
        for i in 0..<(pts.count - 1) {
            let (x, y) = local(pts[i])(pts[i + 1])
            head.append(atan2(x, y) * 180 / .pi)
        }
        // zones exclues : autour des manœuvres de type « tourner », et dans les ronds-points
        var excluded: [(Double, Double)] = []
        var roundaboutStart: Double?
        for m in route.maneuvers {
            let at = cum[min(max(0, m.shapeIndex), cum.count - 1)]
            if m.type == 26 { roundaboutStart = at }
            if m.type == 27, let rs = roundaboutStart { excluded.append((rs - 60, at + 60)); roundaboutStart = nil }
            if turnTypes.contains(m.type) { excluded.append((at - 60, at + 60)) }
        }
        func isExcluded(_ a: Double, _ b: Double) -> Bool { excluded.contains { a <= $0.1 && b >= $0.0 } }
        func radius(_ turn: Double) -> Double {
            let rad = abs(turn) * .pi / 180
            return Double(w) * step / (rad != 0 ? rad : 1e-9)
        }

        var curves: [SafetyCurve] = []
        var i = 0
        while i < head.count - w {
            let turn = angleDiff(head[i], head[i + w])
            let r = radius(turn)
            if r >= 120 { i += 1; continue }
            let sign = turn < 0 ? -1.0 : 1.0
            var k = i, minR = r
            while k + 1 < head.count - w {
                let t2 = angleDiff(head[k + 1], head[k + 1 + w])
                let r2 = radius(t2)
                if r2 >= 120 || (t2 < 0 ? -1.0 : 1.0) != sign { break }
                minR = min(minR, r2)
                k += 1
            }
            var angle = 0.0
            var q = i
            while q < k + w && q + 1 < head.count { angle += angleDiff(head[q], head[q + 1]); q += 1 }
            let start = Double(i) * step, end = Double(k + w) * step
            if abs(angle) >= 40 && !isExcluded(start, end) {
                if let prev = curves.last, start - prev.end < 200 {
                    curves[curves.count - 1].end = end
                    curves[curves.count - 1].radius = min(prev.radius, minR.rounded())
                    curves[curves.count - 1].count += 1
                } else {
                    curves.append(SafetyCurve(id: "\(route.id)-c\(Int(start.rounded()))", start: start, end: end,
                                              radius: minR.rounded(), angle: angle.rounded(), count: 1))
                }
            }
            i = k + w
        }
        return curves
    }

    // MARK: - Passages à niveau, écoles

    static func poisAlong(_ ix: SafetySegIndex, lc: [[Double]], sc: [[Double]]) -> [SafetyRoutePoi] {
        var out: [SafetyRoutePoi] = []
        func key(_ p: [Double]) -> String { String(format: "%.5f,%.5f", p[0], p[1]) }
        for p in lc where p.count >= 2 {
            // le nœud est sur la route
            if let hit = project(ix, .init(latitude: p[1], longitude: p[0]), maxDist: 20) {
                out.append(.init(id: "lc-\(key(p))", along: hit.along, kind: .levelCrossing))
            }
        }
        for p in sc where p.count >= 2 {
            // centre du bâtiment / terrain : un peu en retrait
            if let hit = project(ix, .init(latitude: p[1], longitude: p[0]), maxDist: 120) {
                out.append(.init(id: "sc-\(key(p))", along: hit.along, kind: .school))
            }
        }
        out.sort { $0.along < $1.along }
        // une seule alerte pour plusieurs écoles proches (ou un passage à niveau à double voie)
        var kept: [SafetyRoutePoi] = []
        for p in out where !kept.contains(where: { $0.kind == p.kind && p.along - $0.along < (p.kind == .school ? 400 : 60) }) {
            kept.append(p)
        }
        return kept
    }

    // MARK: - ZFE

    static func zfeCrossings(_ coords: [CLLocationCoordinate2D], _ cum: [Double], _ features: [SafetyZfeFeature]) -> [SafetyZfeCrossing] {
        guard !coords.isEmpty else { return [] }
        var out: [SafetyZfeCrossing] = []
        for f in features {
            var w = Double.infinity, s = Double.infinity, e = -Double.infinity, n = -Double.infinity
            for poly in f.geometry.coordinates { for p in poly.first ?? [] where p.count >= 2 {
                w = min(w, p[0]); e = max(e, p[0]); s = min(s, p[1]); n = max(n, p[1])
            } }
            var entry = -1.0, exit = -1.0
            for i in coords.indices {
                // sous-échantillonne les longs segments (autoroutes) tous les ~100 m
                let steps = i == 0 ? 1 : max(1, Int(ceil((cum[i] - cum[i - 1]) / 100)))
                for k in 1...steps {
                    let t = Double(k) / Double(steps)
                    let p = i == 0 ? coords[0] : CLLocationCoordinate2D(
                        latitude: coords[i - 1].latitude + (coords[i].latitude - coords[i - 1].latitude) * t,
                        longitude: coords[i - 1].longitude + (coords[i].longitude - coords[i - 1].longitude) * t)
                    if p.longitude < w || p.longitude > e || p.latitude < s || p.latitude > n { continue }
                    if SafetyGeo.inMultiPolygon(p, f.geometry.coordinates) {
                        let along = i == 0 ? 0 : cum[i - 1] + (cum[i] - cum[i - 1]) * t
                        if entry < 0 { entry = along }
                        exit = along
                    }
                }
            }
            if entry >= 0 { out.append(.init(entry: entry, exit: exit, props: f.properties)) }
        }
        return out.sorted { $0.entry < $1.entry }
    }

    // MARK: - Suivi en conduite

    /// Accrochage au tracé dans une fenêtre autour du dernier index connu (rapide à chaque position).
    static func snapWindow(_ p: CLLocationCoordinate2D, _ coords: [CLLocationCoordinate2D], _ cum: [Double], hint: Int) -> (index: Int, along: Double, offset: Double) {
        func scan(_ from: Int, _ to: Int) -> (index: Int, along: Double, offset: Double) {
            var best = (index: hint, along: cum.indices.contains(hint) ? cum[hint] : 0, offset: Double.infinity)
            let lo = max(1, from), hi = min(coords.count, to)
            guard lo < hi else { return best }
            for i in lo..<hi {
                let (d, t) = segDist(p, coords[i - 1], coords[i])
                if d < best.offset { best = (i - 1, cum[i - 1] + t * (cum[i] - cum[i - 1]), d) }
            }
            return best
        }
        var best = scan(hint - 5, hint + 400)
        if best.offset > 80 { best = scan(1, coords.count) }
        return best
    }

    /// Portion du tracé entre deux distances le long (pour dessiner une zone sur l'itinéraire).
    static func slice(_ coords: [CLLocationCoordinate2D], _ cum: [Double], from a: Double, to b: Double) -> [CLLocationCoordinate2D] {
        guard coords.count >= 2 else { return coords }
        var out = [Geo.along(coords, cum, a)]
        for i in cum.indices where cum[i] > a && cum[i] < b { out.append(coords[i]) }
        out.append(Geo.along(coords, cum, b))
        return out
    }
}
