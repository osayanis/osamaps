import MapKit
import UIKit

/// Calque de trafic : tronçons colorés (communauté + stations Bison Futé) et évènements officiels.
/// Port de `TrafficLayer.tsx` : charge la zone visible (bbox), s'abonne à la zone (`traffic:watch`)
/// et applique les diffusions `traffic:update`.
@MainActor
final class TrafficMapController {
    static let shared = TrafficMapController()

    static let minZoom = 7.0
    static let eventsMinZoom = 8.0
    /// Degrés : le serveur refuse au-delà de 4.
    static let maxSpan = 3.8
    static let minSpan = 0.1

    private weak var map: MKMapView?
    private var segs: [String: TrafficSegment] = [:]
    private var events: [TrafficEvent] = []
    private var overlays: [TrafficLinesOverlay] = []
    private var annotations: [String: TrafficEventAnnotation] = [:]
    private var seq = 0
    private var watching = false
    /// Zone déjà chargée (avec marge) et quand : inutile de recharger si on reste dedans.
    private var loaded: (bbox: [Double], at: Date)?
    private var pendingRefresh: Task<Void, Never>?
    private var lastFetch = Date.distantPast
    private var renderScheduled = false
    private var tokens: [BusToken] = []
    private var visibleObserved = TrafficStore.shared.visible
    private var modeObserved = Core.shared.mode

    // MARK: - MapLayer

    var layer: MapLayer {
        MapLayer(id: "traffic", zIndex: 20,
                 attach: { [unowned self] map in attach(map) },
                 renderer: { overlay in
                     guard let o = overlay as? TrafficLinesOverlay else { return nil }
                     return TrafficLinesRenderer(overlay: o)
                 },
                 annotationView: { [unowned self] map, ann in annotationView(map, ann) },
                 didSelect: { _, ann in
                     guard let a = ann as? TrafficEventAnnotation else { return false }
                     Haptic.play("light")
                     Core.shared.openPanel("traffic-event", data: a.props)
                     return true
                 },
                 regionDidChange: { [unowned self] _ in scheduleRefresh() },
                 tap: { [unowned self] coord in tapped(coord) })
    }

    private func attach(_ map: MKMapView) {
        self.map = map

        tokens.append(Socket.shared.on("traffic:update") { [weak self] args in
            guard let u = trafficDecode(args.first, as: TrafficUpdate.self) else { return }
            self?.apply(u)
        })
        tokens.append(Socket.shared.onConnect { [weak self] in
            guard let self, self.watching else { return }
            self.loaded = nil
            self.refresh()
        })
        observeVisible()
        refresh()
    }

    private func observeVisible() {
        withObservationTracking {
            _ = TrafficStore.shared.visible
            _ = Core.shared.mode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if Core.shared.mode != self.modeObserved {
                    self.modeObserved = Core.shared.mode
                    self.render() // change de niveau d'overlay
                }
                if TrafficStore.shared.visible != self.visibleObserved {
                    self.visibleObserved = TrafficStore.shared.visible
                    self.loaded = nil
                    self.refresh()
                }
                self.observeVisible()
            }
        }
    }

    // MARK: - Chargement

    /// Zoom « web » (0 = monde entier dans 256 pt).
    static func zoom(of map: MKMapView) -> Double {
        let span = map.region.span.longitudeDelta
        guard span > 0, map.bounds.width > 0 else { return 0 }
        return log2(360 * Double(map.bounds.width) / 256 / span)
    }

    /// Zone à charger : la vue + 15 % de marge, limitée à 3,8° autour du centre.
    /// En conduite (caméra inclinée), la zone visible va jusqu'à l'horizon : d'où le plafond `cap` autour du centre.
    private func viewBbox(margin: Double = 0.15, cap: Double = TrafficMapController.maxSpan) -> [Double]? {
        guard let map, Self.zoom(of: map) >= Self.minZoom else { return nil }
        let r = map.visibleMapRect
        let nw = MKMapPoint(x: r.minX, y: r.minY).coordinate
        let se = MKMapPoint(x: r.maxX, y: r.maxY).coordinate
        var w = nw.longitude, e = se.longitude, n = nw.latitude, s = se.latitude
        let mx = (e - w) * margin, my = (n - s) * margin
        w -= mx; e += mx; s -= my; n += my
        let c = map.centerCoordinate
        // zone minimale (≈ 8 km) : zoomé ou en conduite, on ne recharge pas tous les 300 m
        if margin > 0, e - w < Self.minSpan { w = c.longitude - Self.minSpan / 2; e = c.longitude + Self.minSpan / 2 }
        if margin > 0, n - s < Self.minSpan * 0.7 { s = c.latitude - Self.minSpan * 0.35; n = c.latitude + Self.minSpan * 0.35 }
        if e - w > cap { w = c.longitude - cap / 2; e = c.longitude + cap / 2 }
        if n - s > cap { s = c.latitude - cap / 2; n = c.latitude + cap / 2 }
        return [max(-180, w), max(-85, s), min(180, e), min(85, n)]
    }

    /// En conduite la caméra bouge sans arrêt : on regroupe (≤ 1 chargement / 0,6 s, sans attendre l'immobilité).
    private func scheduleRefresh() {
        guard pendingRefresh == nil else { return }
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.pendingRefresh = nil
            self?.refresh()
        }
    }

    func refresh() {
        seq += 1
        let my = seq
        let bb = TrafficStore.shared.visible ? viewBbox() : nil
        guard let bb else {
            if watching { Socket.shared.emit("traffic:watch", ["bbox": NSNull()]); watching = false }
            loaded = nil
            if !segs.isEmpty || !events.isEmpty { segs.removeAll(); events.removeAll() }
            render()
            return
        }
        updateEventVisibility()
        // déjà chargé, récent, et la vue est dedans : les diffusions socket tiennent la zone à jour
        // (comparaison sur une vue plafonnée plus serrée, sinon une vue inclinée n'est jamais « dedans »)
        if let l = loaded, Date().timeIntervalSince(l.at) < 120, Self.contains(l.bbox, viewBbox(margin: 0, cap: Self.maxSpan * 0.6) ?? bb) { return }
        // au plus un chargement toutes les 3 s ; le suivant est reprogrammé
        if Date().timeIntervalSince(lastFetch) < 3 { scheduleRefresh(); return }
        lastFetch = Date()
        Socket.shared.emit("traffic:watch", ["bbox": bb])
        watching = true
        let q = bb.map { String(format: "%.4f", $0) }.joined(separator: ",")
        Task { @MainActor [weak self] in
            do {
                async let s = API.get("traffic?bbox=\(q)", as: TrafficSegmentsResponse.self)
                async let e = API.get("traffic/events?bbox=\(q)", as: TrafficEventsResponse.self)
                let (segsRes, evRes) = try await (s, e)
                guard let self, my == self.seq, TrafficStore.shared.visible else { return }
                self.segs = Dictionary(segsRes.features.map { ($0.properties.id, $0) }, uniquingKeysWith: { _, b in b })
                self.events = evRes.features
                self.loaded = (bb, Date())
                self.render()
                #if DEBUG
                let slow = segsRes.features.filter { $0.properties.level != "ok" }.count
                NSLog("OsaMaps traffic: %d tronçons (%d ralentis), %d évènements [%@]", segsRes.features.count, slow, evRes.features.count, q)
                #endif
            } catch {
                // serveur injoignable : on garde ce qu'on a
                #if DEBUG
                NSLog("OsaMaps traffic: chargement impossible (%@)", String(describing: error))
                #endif
            }
        }
    }

    private static func contains(_ outer: [Double], _ inner: [Double]) -> Bool {
        inner[0] >= outer[0] && inner[1] >= outer[1] && inner[2] <= outer[2] && inner[3] <= outer[3]
    }

    private func apply(_ u: TrafficUpdate) {
        defer { TrafficDriveController.shared.trafficChanged() }
        guard TrafficStore.shared.visible, watching else { return }
        for f in u.features ?? [] { segs[f.properties.id] = f }
        for id in u.removed ?? [] { segs[id] = nil }
        render()
    }

    // MARK: - Rendu

    private func render() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.renderNow()
        }
    }

    private func renderNow() {
        guard let map else { return }
        // un overlay par niveau, du moins grave (dessous) au plus grave (dessus)
        var fresh: [TrafficLinesOverlay] = []
        for level in [TrafficLevel.ok, .slow, .jam] {
            let lines = segs.values.filter { $0.properties.trafficLevel == level }.map { $0.coordinates.map(MKMapPoint.init) }.filter { $0.count >= 2 }
            if !lines.isEmpty { fresh.append(TrafficLinesOverlay(level: level, lines: lines)) }
        }
        // insérés tout en bas de leur niveau : l'itinéraire reste par-dessus le trafic.
        // Exploration : sous les libellés. Conduite : le tracé de routing est en .aboveLabels, on y va aussi
        // (sinon le trafic passerait sous les bâtiments 3D et le tracé).
        let level: MKOverlayLevel = Core.shared.mode == .drive ? .aboveLabels : .aboveRoads
        for (i, o) in fresh.enumerated() { map.insertOverlay(o, at: i, level: level) }
        map.removeOverlays(overlays)
        overlays = fresh
        updateEventVisibility()
    }

    /// Évènements : seulement à partir du zoom 8, mis à jour par différence (pas de clignotement).
    private func updateEventVisibility() {
        guard let map else { return }
        let show = TrafficStore.shared.visible && Self.zoom(of: map) >= Self.eventsMinZoom
        var wanted: [String: TrafficEvent] = [:]
        if show { for e in events { wanted[e.properties.id] = e } }
        let stale = annotations.filter { wanted[$0.key] == nil || wanted[$0.key]!.properties != $0.value.props }
        if !stale.isEmpty {
            map.removeAnnotations(Array(stale.values))
            for k in stale.keys { annotations[k] = nil }
        }
        var add: [TrafficEventAnnotation] = []
        for (id, e) in wanted where annotations[id] == nil {
            guard let c = e.coordinate else { continue }
            let a = TrafficEventAnnotation(props: e.properties, coordinate: c)
            annotations[id] = a
            add.append(a)
        }
        if !add.isEmpty { map.addAnnotations(add) }
    }

    private func annotationView(_ map: MKMapView, _ ann: MKAnnotation) -> MKAnnotationView? {
        guard let a = ann as? TrafficEventAnnotation else { return nil }
        let id = "traffic-event"
        let v = map.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: a, reuseIdentifier: id)
        v.annotation = a
        let kind = a.props.eventKind
        v.image = TrafficEventImage.image(kind)
        v.canShowCallout = false
        v.collisionMode = .circle
        v.displayPriority = MKFeatureDisplayPriority(rawValue: 900 - Float(kind.rank) * 40)
        v.isAccessibilityElement = true
        v.accessibilityLabel = [a.props.title, a.props.road].compactMap { $0 }.joined(separator: ", ")
        v.accessibilityTraits = .button
        return v
    }

    // MARK: - Appui sur un tronçon

    /// Tape simple sur la carte (hors marqueurs, filtrés par le socle) : fiche du tronçon le plus proche (≤ 14 pt).
    private func tapped(_ coord: CLLocationCoordinate2D) -> Bool {
        guard let map, TrafficStore.shared.visible, !segs.isEmpty else { return false }
        let p = map.convert(coord, toPointTo: map)
        var best: (d: CGFloat, seg: TrafficSegment)?
        for s in segs.values {
            let pts = s.coordinates.map { map.convert($0, toPointTo: map) }
            for i in pts.indices.dropFirst() {
                let d = Self.distance(p, pts[i - 1], pts[i])
                if d < 14, best == nil || d < best!.d || (d - best!.d < 3 && s.properties.trafficLevel.rank > best!.seg.properties.trafficLevel.rank) {
                    best = (d, s)
                }
            }
        }
        guard let best else { return false }
        Haptic.play("light")
        Core.shared.openPanel("traffic-segment", data: best.seg.properties)
        return true
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
        let x = a.x + dx * t - p.x, y = a.y + dy * t - p.y
        return (x * x + y * y).squareRoot()
    }

    // MARK: - Accès pour les fiches / tests

    var currentEvents: [TrafficEvent] { events }
    var currentSegments: [TrafficSegment] { Array(segs.values) }
}

private extension TrafficLevel {
    var rank: Int { self == .jam ? 2 : self == .slow ? 1 : 0 }
}

/// Évènement officiel posé sur la carte (sous-classe propre au module).
final class TrafficEventAnnotation: MKPointAnnotation {
    let props: TrafficEventProps
    init(props: TrafficEventProps, coordinate: CLLocationCoordinate2D) {
        self.props = props
        super.init()
        self.coordinate = coordinate
        self.title = props.title
    }
}

/// Pastilles des évènements : fond sombre, anneau de la couleur d'état, glyphe blanc.
@MainActor
enum TrafficEventImage {
    private static var cache: [TrafficEventKind: UIImage] = [:]

    static func image(_ kind: TrafficEventKind) -> UIImage {
        if let i = cache[kind] { return i }
        let size: CGFloat = 30
        let cfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        let glyph = (UIImage(systemName: kind.symbol, withConfiguration: cfg) ?? UIImage(systemName: "exclamationmark", withConfiguration: cfg)!)
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let img = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let r = CGRect(x: 1.5, y: 1.5, width: size - 3, height: size - 3)
            let c = ctx.cgContext
            c.setFillColor(UIColor(red: 14 / 255, green: 14 / 255, blue: 20 / 255, alpha: 0.92).cgColor)
            c.fillEllipse(in: r)
            c.setStrokeColor(kind.uiTone.cgColor)
            c.setLineWidth(2.5)
            c.strokeEllipse(in: r.insetBy(dx: 0.5, dy: 0.5))
            let gs = glyph.size
            let scale = min(1, 17 / max(gs.width, gs.height))
            let w = gs.width * scale, h = gs.height * scale
            glyph.draw(in: CGRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
        }
        cache[kind] = img
        return img
    }
}

/// Un overlay par niveau de trafic, contenant toutes les lignes de ce niveau. Immuable :
/// MapKit dessine les tuiles sur des fils d'arrière-plan.
final class TrafficLinesOverlay: NSObject, MKOverlay, @unchecked Sendable {
    let level: TrafficLevel
    let lines: [[MKMapPoint]]
    let rects: [MKMapRect]
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D

    init(level: TrafficLevel, lines: [[MKMapPoint]]) {
        self.level = level
        self.lines = lines
        var rects: [MKMapRect] = []
        var all = MKMapRect.null
        for l in lines {
            let xs = l.map(\.x), ys = l.map(\.y)
            let r = MKMapRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            rects.append(r)
            all = all.union(r)
        }
        self.rects = rects
        // marge pour l'épaisseur et le décalage (sinon les tuiles du bord coupent les traits)
        boundingMapRect = all.insetBy(dx: -40_000, dy: -40_000)
        coordinate = MKMapPoint(x: all.midX, y: all.midY).coordinate
    }
}

/// Dessine les lignes d'un niveau : épaisseur selon le zoom, décalées à droite du sens de circulation
/// (les deux sens d'une route ne se superposent pas) — mêmes courbes que la version web.
final class TrafficLinesRenderer: MKOverlayRenderer, @unchecked Sendable {
    private let color: CGColor
    private let alphaValue: CGFloat

    init(overlay: TrafficLinesOverlay) {
        let c: UIColor
        switch overlay.level {
        case .ok: c = UIColor(red: 0.204, green: 0.78, blue: 0.349, alpha: 1)
        case .slow: c = UIColor(red: 1.0, green: 0.624, blue: 0.039, alpha: 1)
        case .jam: c = UIColor(red: 1.0, green: 0.271, blue: 0.227, alpha: 1)
        }
        color = c.cgColor
        alphaValue = overlay.level == .ok ? 0.7 : 0.95
        super.init(overlay: overlay)
    }

    /// Interpolation exponentielle (base 1,5) entre paliers de zoom, comme MapLibre.
    static func interp(_ z: Double, _ stops: [(Double, Double)]) -> Double {
        if z <= stops[0].0 { return stops[0].1 }
        for i in 1..<stops.count where z <= stops[i].0 {
            let (z0, v0) = stops[i - 1], (z1, v1) = stops[i]
            let base = 1.5
            let t = (pow(base, z - z0) - 1) / (pow(base, z1 - z0) - 1)
            return v0 + (v1 - v0) * t
        }
        return stops[stops.count - 1].1
    }

    static let widthStops: [(Double, Double)] = [(6, 1.2), (10, 2.6), (14, 5), (18, 11)]
    static let offsetStops: [(Double, Double)] = [(6, 0.6), (10, 1.6), (14, 3.5), (18, 8)]

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        guard let o = overlay as? TrafficLinesOverlay else { return }
        let z = 20 + log2(Double(zoomScale))
        let width = Self.interp(z, Self.widthStops) / Double(zoomScale)
        let offset = Self.interp(z, Self.offsetStops) / Double(zoomScale)
        let pad = (width + offset) * 2
        let clip = mapRect.insetBy(dx: -pad, dy: -pad)
        let path = CGMutablePath()
        for (i, line) in o.lines.enumerated() where o.rects[i].intersects(clip) {
            for k in line.indices.dropFirst() {
                let a = line[k - 1], b = line[k]
                let dx = b.x - a.x, dy = b.y - a.y
                let len = (dx * dx + dy * dy).squareRoot()
                guard len > 0 else { continue }
                // à droite du sens (y vers le sud) : (-dy, dx) normalisé
                let nx = -dy / len * offset, ny = dx / len * offset
                path.move(to: point(for: MKMapPoint(x: a.x + nx, y: a.y + ny)))
                path.addLine(to: point(for: MKMapPoint(x: b.x + nx, y: b.y + ny)))
            }
        }
        guard !path.isEmpty else { return }
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setAlpha(alphaValue)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }
}
