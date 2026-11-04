import Foundation
import CoreLocation

/// Ids des panneaux du bas possédés par ce module, et retour au panneau remplacé à la fermeture.
@MainActor
enum ReportsPanels {
    static let panel = "reports"
    static let detail = "report-detail"

    struct Back { var panel: String?; var data: Any? }
    struct Data { var back: Back; var id: String? }

    static func isOwn(_ p: String?) -> Bool { p == panel || p == detail }

    /// Ouvre un panneau du module en mémorisant celui qu'on remplace.
    static func openOwn(_ id: String, reportId: String? = nil) {
        let core = Core.shared
        let back: Back = isOwn(core.panel)
            ? ((core.panelData as? Data)?.back ?? Back(panel: nil, data: nil))
            : Back(panel: core.panel, data: core.panelData)
        core.openPanel(id, data: Data(back: back, id: reportId))
    }

    static func closeOwn() {
        let core = Core.shared
        guard isOwn(core.panel) else { return }
        let back = (core.panelData as? Data)?.back
        core.openPanel(back?.panel, data: back?.data)
    }
}

/// En conduite : repère les signalements DEVANT sur l'itinéraire actif (≤ 1,5 km, même sens) et
/// émet `.driveAlert` (le module guidance affiche et annonce). Deux étapes par signalement, même id :
/// en entrant à ≤ 1,5 km, puis à ≤ 300 m. En passant à côté, propose « Toujours là ? ».
/// Port fidèle de `web/src/features/reports/watch.ts`.
@MainActor
enum ReportsWatch {
    static let aheadMax = 1500.0
    static let near = 300.0
    /// Mètres entre le signalement et le tracé.
    static let onRoute = 45.0
    /// Degrés.
    static let sameWay = 70.0

    private static var cache: (id: String, cum: [Double])?
    /// id → étape déjà annoncée (1 = 1,5 km, 2 = 300 m).
    private static var alerted: [String: Int] = [:]
    /// Passés à moins de 60 m (en attente de s'éloigner pour demander).
    private static var nearSet: Set<String> = []
    private static var asked: Set<String> = []
    private static var last = Date.distantPast
    private static var lastArea = Date.distantPast
    private static var tokens: [BusToken] = []

    static func start() {
        guard tokens.isEmpty else { return }
        tokens.append(Bus.shared.on { event in
            switch event {
            case .geoTick(let p):
                let now = Date()
                guard now.timeIntervalSince(last) >= 0.9 else { return }
                last = now
                tick()
                // la zone autour de la position, même si la carte ne bouge pas (toutes les 20 s)
                if now.timeIntervalSince(lastArea) > 20 {
                    lastArea = now
                    let c = p.coordinate
                    Task { await ReportsStore.shared.watchArea(w: c.longitude, s: c.latitude, e: c.longitude, n: c.latitude, around: c) }
                }
            case .driveStart:
                lastArea = .distantPast
            case .driveStop:
                alerted.removeAll(); nearSet.removeAll()
                ReportsStore.shared.setAsk(nil)
            default: break
            }
        })
    }

    private static func cum(_ r: Route) -> [Double] {
        if let c = cache, c.id == r.id { return c.cum }
        let c = Geo.cumulative(r.coordinates)
        cache = (r.id, c)
        return c
    }

    static func tick() {
        let core = Core.shared
        guard core.mode == .drive, let position = core.position else { return }
        let me = position.coordinate
        let store = ReportsStore.shared
        let list = store.items.values.filter { Geo.distance(me, $0.coordinate) < aheadMax + 300 }

        // ——— alertes le long de l'itinéraire ———
        if let route = core.route, route.coords.count > 1 {
            let line = route.coordinates
            let c = cum(route)
            let from = max(0, (core.progress?.shapeIndex ?? 0) - 2)
            if let mySnap = Geo.snap(me, to: line, cum: c, from: from) {
                // fenêtre : 200 m derrière → 1,7 km devant
                var i0 = mySnap.index, i1 = mySnap.index + 1
                while i0 > 0 && mySnap.along - c[i0] < 200 { i0 -= 1 }
                while i1 < line.count - 1 && c[i1] - mySnap.along < aheadMax + 200 { i1 += 1 }
                for r in list {
                    guard store.settings.alert(r.type),
                          let s = Geo.snap(r.coordinate, to: line, cum: c, from: i0, to: i1),
                          s.distance <= onRoute else { continue }
                    let k = min(line.count - 1, s.index + 1)
                    if let h = r.heading, k > s.index, Reports.angleDiff(h, Geo.bearing(line[s.index], line[k])) > sameWay { continue }
                    let ahead = s.along - mySnap.along
                    if ahead <= 15 || ahead > aheadMax { continue }
                    let stage = ahead <= near ? 2 : 1
                    if (alerted[r.id] ?? 0) >= stage { continue }
                    alerted[r.id] = stage
                    emit(.driveAlert(DriveAlert(
                        id: "report:\(r.id)", kind: r.type.rawValue,
                        text: "\(r.title) dans \(Geo.formatDistance(ahead))",
                        distance: ahead.rounded(), tone: r.type.tone)))
                }
            }
        }

        // ——— « Toujours là ? » en passant à côté (avec ou sans itinéraire) ———
        guard store.settings.ask else { return }
        for r in list {
            if store.mine[r.id] != nil || store.voted[r.id] != nil || asked.contains(r.id) { continue }
            let d = Geo.distance(me, r.coordinate)
            if d < 60 {
                // même sens que nous (si on le sait), sinon c'est l'autre voie
                if let rh = r.heading, let ph = position.heading, Reports.angleDiff(rh, ph) > sameWay { continue }
                nearSet.insert(r.id)
            } else if nearSet.contains(r.id) && d > 90 {
                nearSet.remove(r.id)
                asked.insert(r.id)
                if store.ask == nil { store.setAsk(.init(id: r.id, at: .now)) }
            }
        }
    }
}
