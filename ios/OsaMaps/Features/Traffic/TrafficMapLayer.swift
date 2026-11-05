import MapKit
import UIKit

/// Calque de trafic : tronçons colorés (communauté + stations Bison Futé) et évènements officiels.
/// Port de `TrafficLayer.tsx` : charge la zone visible (bbox), s'abonne à la zone (`traffic:watch`)
/// et applique les diffusions `traffic:update`.
@MainActor
final class TrafficMapController {
    static let shared = TrafficMapController()

    static let minZoom = 7.0
    static let eventsMinZoom = 7.0
    /// Tracés des fermetures / travaux (traits pointillés) seulement de près.
    static let eventLinesMinZoom = 12.0
    /// Degrés : le serveur refuse au-delà de 4.
    static let maxSpan = 3.8
    static let minSpan = 0.1

    private weak var map: MKMapView?
    private var segs: [String: TrafficSegment] = [:]
    private var events: [TrafficEvent] = []
    private var overlays: [TrafficLinesOverlay] = []
    private var eventLines: [TrafficEventLineOverlay] = []
    private var eventLinesKey = ""
    private var annotations: [String: TrafficEventAnnotation] = [:]
    private var seq = 0
    private var watching = false
    /// Zone déjà chargée (avec marge) et quand : inutile de recharger si on reste dedans.
    private var loaded: (bbox: [Double], at: Date, zoomBucket: Int)?
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
                     if let o = overlay as? TrafficEventLineOverlay { return TrafficEventLineRenderer(overlay: o) }
                     guard let o = overlay as? TrafficLinesOverlay else { return nil }
                     return TrafficLinesRenderer(overlay: o)
                 },
                 annotationView: { [unowned self] map, ann in annotationView(map, ann) },
                 didSelect: { map, ann in
                     if let c = ann as? MKClusterAnnotation, c.memberAnnotations.first is TrafficEventAnnotation {
                         // groupe : on zoome dessus (comme Waze), la fiche viendra au toucher d'une pastille seule
                         Haptic.play("light")
                         Core.shared.follow = false
                         let pts = c.memberAnnotations.map { MKMapPoint($0.coordinate) }
                         var r = MKMapRect.null
                         for p in pts { r = r.union(MKMapRect(origin: p, size: MKMapSize(width: 1, height: 1))) }
                         let minSide = MKMapPointsPerMeterAtLatitude(c.coordinate.latitude) * 600
                         if r.size.width < minSide { r = r.insetBy(dx: -(minSide - r.size.width) / 2, dy: 0) }
                         if r.size.height < minSide { r = r.insetBy(dx: 0, dy: -(minSide - r.size.height) / 2) }
                         map.setVisibleMapRect(r, edgePadding: UIEdgeInsets(top: 120, left: 60, bottom: Core.shared.sheetHeight + 60, right: 80), animated: true)
                         return true
                     }
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
        let bucket = Self.zoomBucket(map.map(Self.zoom(of:)) ?? 10)
        if let l = loaded, Date().timeIntervalSince(l.at) < 120, bucket <= l.zoomBucket,
           Self.contains(l.bbox, viewBbox(margin: 0, cap: Self.maxSpan * 0.6) ?? bb) { return }
        // au plus un chargement toutes les 3 s ; le suivant est reprogrammé
        if Date().timeIntervalSince(lastFetch) < 3 { scheduleRefresh(); return }
        lastFetch = Date()
        Socket.shared.emit("traffic:watch", ["bbox": bb])
        watching = true
        let q = bb.map { String(format: "%.4f", $0) }.joined(separator: ",")
        let z = String(format: "%.1f", map.map(Self.zoom(of:)) ?? 10)
        Task { @MainActor [weak self] in
            do {
                async let s = API.get("traffic?bbox=\(q)", as: TrafficSegmentsResponse.self)
                async let e = API.get("events?bbox=\(q)&z=\(z)", as: TrafficEventsResponse.self)
                let (segsRes, evRes) = try await (s, e)
                guard let self, my == self.seq, TrafficStore.shared.visible else { return }
                self.segs = Dictionary(segsRes.features.map { ($0.properties.id, $0) }, uniquingKeysWith: { _, b in b })
                self.events = evRes.features
                self.loaded = (bb, Date(), bucket)
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

    /// Le serveur densifie selon le zoom (`z`) : en zoomant, on recharge en franchissant ces paliers.
    static func zoomBucket(_ z: Double) -> Int { z < 9 ? 0 : z < 10 ? 1 : z < 11 ? 2 : z < 12 ? 3 : z < 13 ? 4 : 5 }

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

    /// Évènements : seulement à partir du zoom 7, filtrés selon le zoom (au loin, seulement l'important),
    /// mis à jour par différence (pas de clignotement). MapKit regroupe les pastilles trop proches.
    private func updateEventVisibility() {
        guard let map else { return }
        let z = Self.zoom(of: map)
        let show = TrafficStore.shared.visible && z >= Self.eventsMinZoom
        var wanted: [String: TrafficEvent] = [:]
        if show {
            for e in events where Self.visible(e.properties, zoom: z) { wanted[e.properties.id] = e }
        }
        updateEventLines(show && z >= Self.eventLinesMinZoom ? Array(wanted.values) : [])
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
        if let c = ann as? MKClusterAnnotation { return clusterView(map, c) }
        guard let a = ann as? TrafficEventAnnotation else { return nil }
        let id = "traffic-event"
        let v = map.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: a, reuseIdentifier: id)
        v.annotation = a
        let kind = a.props.eventKind
        v.image = TrafficEventImage.image(kind, severe: a.props.severity >= 3)
        v.canShowCallout = false
        v.collisionMode = .circle
        // l'important (fermetures, accidents, gravité forte) n'est jamais regroupé ni masqué en premier
        v.displayPriority = MKFeatureDisplayPriority(rawValue: min(1000, 700 + Float(a.props.severity) * 60 - Float(kind.rank) * 10))
        v.clusteringIdentifier = a.props.severity >= 3 && kind.rank <= 2 ? nil : "traffic-events"
        v.isAccessibilityElement = true
        v.accessibilityLabel = [a.props.title, a.props.road].compactMap { $0 }.joined(separator: ", ")
        v.accessibilityTraits = .button
        return v
    }

    private func clusterView(_ map: MKMapView, _ c: MKClusterAnnotation) -> MKAnnotationView? {
        let members = c.memberAnnotations.compactMap { $0 as? TrafficEventAnnotation }
        guard !members.isEmpty, members.count == c.memberAnnotations.count else { return nil }
        let id = "traffic-cluster"
        let v = map.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: c, reuseIdentifier: id)
        v.annotation = c
        let top = members.map(\.props).min { ($0.eventKind.rank, -$0.severity) < ($1.eventKind.rank, -$1.severity) }!
        v.image = TrafficEventImage.cluster(top.eventKind, count: members.count)
        v.canShowCallout = false
        v.collisionMode = .circle
        v.displayPriority = .defaultHigh
        v.isAccessibilityElement = true
        v.accessibilityLabel = "\(members.count) évènements, dont \(top.title)"
        v.accessibilityTraits = .button
        return v
    }

    /// Densité selon le zoom (le serveur filtre déjà, on affine en zoomant/dézoomant sans recharger).
    static func visible(_ p: TrafficEventProps, zoom z: Double) -> Bool {
        switch p.eventKind {
        case .hotspot: return z >= 12.5 || (z >= 11 && p.severity >= 2)
        case .fuel: return z >= 11
        case .weather, .flood: return z < 12 || p.severity >= 3   // vigilance : vue d'ensemble
        case .works, .lanes: return p.severity >= 2 ? z >= 9 : z >= 12
        default: return p.severity >= 3 || z >= 9
        }
    }

    /// Traits pointillés des fermetures et chantiers (de près) : un overlay unique, recréé si la liste change.
    private func updateEventLines(_ list: [TrafficEvent]) {
        guard let map else { return }
        let lines = list.filter { [.closure, .lanes, .works].contains($0.properties.eventKind) && ($0.properties.line?.count ?? 0) >= 2 }
        let key = lines.map(\.properties.id).sorted().joined(separator: "|")
        guard key != eventLinesKey else { return }
        eventLinesKey = key
        map.removeOverlays(eventLines)
        eventLines = lines.map { TrafficEventLineOverlay(kind: $0.properties.eventKind, coords: $0.properties.lineCoordinates) }
        if !eventLines.isEmpty { map.addOverlays(eventLines, level: Core.shared.mode == .drive ? .aboveLabels : .aboveRoads) }
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
/// Gravité forte : pastille un peu plus grande et anneau plus épais.
@MainActor
enum TrafficEventImage {
    private static var cache: [String: UIImage] = [:]

    private static func glyph(_ kind: TrafficEventKind, _ pt: CGFloat) -> UIImage {
        let cfg = UIImage.SymbolConfiguration(pointSize: pt, weight: .bold)
        return (UIImage(systemName: kind.symbol, withConfiguration: cfg) ?? UIImage(systemName: "exclamationmark", withConfiguration: cfg)!)
            .withTintColor(.white, renderingMode: .alwaysOriginal)
    }

    static func image(_ kind: TrafficEventKind, severe: Bool = false) -> UIImage {
        let key = "\(kind.rawValue)-\(severe)"
        if let i = cache[key] { return i }
        let size: CGFloat = severe ? 34 : 28
        let g = glyph(kind, severe ? 14 : 12)
        let img = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let r = CGRect(x: 1.5, y: 1.5, width: size - 3, height: size - 3)
            let c = ctx.cgContext
            c.setFillColor(UIColor(red: 14 / 255, green: 14 / 255, blue: 20 / 255, alpha: 0.92).cgColor)
            c.fillEllipse(in: r)
            c.setStrokeColor(kind.uiTone.cgColor)
            c.setLineWidth(severe ? 3 : 2.2)
            c.strokeEllipse(in: r.insetBy(dx: 0.5, dy: 0.5))
            let gs = g.size
            let maxSide = severe ? 19.0 : 15.0
            let scale = min(1, maxSide / max(gs.width, gs.height))
            let w = gs.width * scale, h = gs.height * scale
            g.draw(in: CGRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
        }
        cache[key] = img
        return img
    }

    /// Groupe d'évènements : pastille de l'évènement le plus important + badge blanc avec le nombre.
    static func cluster(_ kind: TrafficEventKind, count: Int) -> UIImage {
        let label = count > 99 ? "99+" : "\(count)"
        let key = "cluster-\(kind.rawValue)-\(label)"
        if let i = cache[key] { return i }
        let base = image(kind, severe: true)
        let font = UIFont.systemFont(ofSize: 11, weight: .heavy)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: UIColor.black])
        let ts = text.size()
        let bw = max(18, ts.width + 9), bh: CGFloat = 18
        let size = CGSize(width: base.size.width + bw * 0.55, height: base.size.height + 4)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            base.draw(at: CGPoint(x: 0, y: 4))
            let br = CGRect(x: size.width - bw, y: 0, width: bw, height: bh)
            let c = ctx.cgContext
            c.setFillColor(UIColor.white.cgColor)
            c.addPath(UIBezierPath(roundedRect: br, cornerRadius: bh / 2).cgPath)
            c.fillPath()
            text.draw(at: CGPoint(x: br.midX - ts.width / 2, y: br.midY - ts.height / 2))
        }
        cache[key] = img
        return img
    }
}

/// Tracé d'une fermeture ou d'un chantier (immuable, dessiné en pointillés).
final class TrafficEventLineOverlay: MKPolyline, @unchecked Sendable {
    private(set) var kind: TrafficEventKind = .works
    convenience init(kind: TrafficEventKind, coords: [CLLocationCoordinate2D]) {
        self.init(coordinates: coords, count: coords.count)
        self.kind = kind
    }
}

final class TrafficEventLineRenderer: MKPolylineRenderer, @unchecked Sendable {
    init(overlay: TrafficEventLineOverlay) {
        super.init(polyline: overlay)
        strokeColor = overlay.kind == .closure ? UIColor(red: 1.0, green: 0.271, blue: 0.227, alpha: 0.95) : UIColor(red: 1.0, green: 0.624, blue: 0.039, alpha: 0.9)
        lineWidth = overlay.kind == .closure ? 5 : 4
        lineDashPattern = overlay.kind == .closure ? [2, 7] : [6, 6]
        lineCap = .round
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
