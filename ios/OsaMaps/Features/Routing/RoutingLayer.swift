import MapKit
import UIKit

/// Calques de l'itinéraire (port de `RoutingLayer.tsx`) : alternatives grises touchables, tracé actif
/// blanc avec halo, partie déjà parcourue estompée en conduite, marqueurs d'arrivée et d'étapes.
/// Les tracés sont insérés TOUT EN BAS des overlays « aboveRoads » : les calques des autres modules
/// (trafic, signalements…) restent visibles par-dessus.

/// Un tracé d'itinéraire (actif ou alternative).
final class RoutingRouteOverlay: MKPolyline {
    var routeId = ""
    var index = 0
    var isActive = false
}

final class RoutingDestinationAnnotation: MKPointAnnotation {}

final class RoutingStopAnnotation: MKPointAnnotation {
    var number = 1
}

/// Rendu d'un tracé : dessine lui-même halo + liseré + trait (actif) ou liseré + trait gris (alternative),
/// et la partie parcourue estompée — sans recréer d'overlay à chaque position.
final class RoutingLineRenderer: MKOverlayRenderer {
    private let pts: [MKMapPoint]
    let isActive: Bool
    private(set) var passedIndex = 0

    init(overlay: RoutingRouteOverlay) {
        let p = overlay.points()
        pts = (0..<overlay.pointCount).map { p[$0] }
        isActive = overlay.isActive
        super.init(overlay: overlay)
    }

    /// Met à jour la partie parcourue et ne redessine que la zone concernée.
    func setPassed(_ index: Int) {
        let i = max(0, min(index, pts.count - 1))
        guard i != passedIndex, !pts.isEmpty else { return }
        let a = min(i, passedIndex), b = max(i, passedIndex)
        passedIndex = i
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for k in max(0, a - 1)...min(pts.count - 1, b + 1) {
            minX = min(minX, pts[k].x); maxX = max(maxX, pts[k].x)
            minY = min(minY, pts[k].y); maxY = max(maxY, pts[k].y)
        }
        let pad = max(4000, max(maxX - minX, maxY - minY) * 0.1)
        setNeedsDisplay(MKMapRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad))
    }

    /// Largeur (pt écran) interpolée entre le zoom 8 et le zoom 16, comme la version web.
    private static func width(_ z: Double, _ w8: Double, _ w16: Double) -> CGFloat {
        let t = max(0, min(1, (z - 8) / 8))
        return CGFloat(w8 + (w16 - w8) * t)
    }

    private func path(_ range: ClosedRange<Int>, in rect: MKMapRect) -> CGPath? {
        guard range.count >= 2 else { return nil }
        let p = CGMutablePath()
        var drawing = false
        var any = false
        for i in range.lowerBound..<range.upperBound {
            let a = pts[i], b = pts[i + 1]
            let visible = max(a.x, b.x) >= rect.minX && min(a.x, b.x) <= rect.maxX
                && max(a.y, b.y) >= rect.minY && min(a.y, b.y) <= rect.maxY
            if visible {
                if !drawing { p.move(to: point(for: a)); drawing = true }
                p.addLine(to: point(for: b))
                any = true
            } else {
                drawing = false
            }
        }
        return any ? p : nil
    }

    private func stroke(_ path: CGPath, _ ctx: CGContext, color: UIColor, width: CGFloat, zoomScale: MKZoomScale) {
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width / zoomScale)
        ctx.strokePath()
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        guard pts.count >= 2 else { return }
        let z = 20 + log2(Double(zoomScale))
        let maxW = Self.width(z, 16, 30)
        let pad = Double(maxW / zoomScale)
        let rect = mapRect.insetBy(dx: -pad, dy: -pad)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if !isActive {
            guard let p = path(0...(pts.count - 1), in: rect) else { return }
            stroke(p, ctx, color: UIColor.black.withAlphaComponent(0.35), width: Self.width(z, 6, 12), zoomScale: zoomScale)
            stroke(p, ctx, color: UIColor(red: 0.604, green: 0.604, blue: 0.635, alpha: 0.7), width: Self.width(z, 3.5, 8), zoomScale: zoomScale)
            return
        }

        let idx = passedIndex
        if idx > 0, let passed = path(0...idx, in: rect) {
            stroke(passed, ctx, color: UIColor.white.withAlphaComponent(0.22), width: Self.width(z, 3.5, 9), zoomScale: zoomScale)
        }
        guard let rest = path(idx...(pts.count - 1), in: rect) else { return }
        stroke(rest, ctx, color: UIColor.white.withAlphaComponent(0.14), width: maxW, zoomScale: zoomScale)
        stroke(rest, ctx, color: UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 0.8), width: Self.width(z, 7, 14), zoomScale: zoomScale)
        stroke(rest, ctx, color: .white, width: Self.width(z, 4, 9), zoomScale: zoomScale)
    }
}

/// Vues des marqueurs (arrivée : disque blanc à cœur sombre ; étape : pastille numérotée).
final class RoutingMarkerView: MKAnnotationView {
    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        collisionMode = .circle
        displayPriority = .required
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 7
        layer.shadowOffset = CGSize(width: 0, height: 4)
        label.font = .systemFont(ofSize: 12, weight: .heavy)
        label.textColor = .white
        label.textAlignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ a: MKAnnotation) {
        subviews.filter { $0 !== label }.forEach { $0.removeFromSuperview() }
        layer.sublayers?.filter { $0.name == "routing" }.forEach { $0.removeFromSuperlayer() }
        if let stop = a as? RoutingStopAnnotation {
            frame = CGRect(x: 0, y: 0, width: 26, height: 26)
            let c = CAShapeLayer()
            c.name = "routing"
            c.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 1.25, dy: 1.25)).cgPath
            c.fillColor = UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 1).cgColor
            c.strokeColor = UIColor.white.cgColor
            c.lineWidth = 2.5
            layer.insertSublayer(c, at: 0)
            label.isHidden = false
            label.text = String(stop.number)
            label.frame = bounds
            zPriority = .defaultSelected
            accessibilityLabel = "Étape \(stop.number)"
        } else {
            frame = CGRect(x: 0, y: 0, width: 30, height: 30)
            let ring = CAShapeLayer()
            ring.name = "routing"
            ring.path = UIBezierPath(ovalIn: bounds).cgPath
            ring.fillColor = UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 0.75).cgColor
            let disc = CAShapeLayer()
            disc.name = "routing"
            disc.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).cgPath
            disc.fillColor = UIColor.white.cgColor
            let dot = CAShapeLayer()
            dot.name = "routing"
            dot.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 11, dy: 11)).cgPath
            dot.fillColor = UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 1).cgColor
            [ring, disc, dot].enumerated().forEach { layer.insertSublayer($1, at: UInt32($0)) }
            label.isHidden = true
            zPriority = .max
            accessibilityLabel = "Arrivée"
        }
        centerOffset = .zero
    }
}

/// Contrôleur du calque : suit le Core et l'état du module, et met la carte à jour.
@MainActor
final class RoutingMapController: NSObject, UIGestureRecognizerDelegate {
    static let shared = RoutingMapController()

    private weak var map: MKMapView?
    private var overlays: [RoutingRouteOverlay] = []
    private weak var activeRenderer: RoutingLineRenderer?
    private var overlayKey = ""
    private var annotations: [MKAnnotation] = []
    private var annotationKey = ""
    /// Cadrage : itinéraires déjà cadrés, l'utilisateur a-t-il bougé la carte, hauteur du panneau au cadrage.
    private var fittedKey = ""
    private var touched = false
    private var fittedHeight: CGFloat = 0
    private var fitTask: Task<Void, Never>?

    private var core: Core { Core.shared }
    private var model: RoutingModel { RoutingModel.shared }

    var layer: MapLayer {
        MapLayer(id: "routing", zIndex: 20,
                 attach: { [unowned self] map in self.attach(map) },
                 renderer: { [unowned self] overlay in self.renderer(for: overlay) },
                 annotationView: { map, a in Self.view(map, a) },
                 didSelect: { _, a in a is RoutingDestinationAnnotation || a is RoutingStopAnnotation })
    }

    private func attach(_ map: MKMapView) {
        self.map = map
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        map.addGestureRecognizer(tap)
        for g in [UIPanGestureRecognizer(target: self, action: #selector(moved(_:))),
                  UIPinchGestureRecognizer(target: self, action: #selector(moved(_:)))] as [UIGestureRecognizer] {
            g.cancelsTouchesInView = false
            g.delegate = self
            map.addGestureRecognizer(g)
        }

        RoutingObserve.watch({ [unowned self] in self.currentOverlayKey() }) { [unowned self] _ in self.syncOverlays() }
        RoutingObserve.watch({ [unowned self] in self.currentAnnotationKey() }) { [unowned self] _ in self.syncAnnotations() }
        RoutingObserve.watch({ Core.shared.mode == .drive ? (Core.shared.progress?.shapeIndex ?? 0) : 0 }) { [unowned self] i in
            self.activeRenderer?.setPassed(i)
        }
        RoutingObserve.watch({ [unowned self] in self.fitKey() }) { [unowned self] _ in self.scheduleFit() }
        RoutingObserve.watch({ Core.shared.mode }) { [unowned self] mode in
            if mode != .preview { self.fittedKey = ""; self.touched = false; self.fittedHeight = 0 }
        }
        syncOverlays()
        syncAnnotations()
    }

    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }

    // MARK: Tracés

    private func currentOverlayKey() -> String {
        let c = core
        switch c.mode {
        case .browse: return "none"
        case .preview: return "p|" + c.routes.map { "\($0.id):\($0.coords.count)" }.joined(separator: ",") + "|\(c.activeRoute)"
        case .drive: return "d|" + (c.route.map { "\($0.id):\($0.coords.count)" } ?? "")
        }
    }

    private func syncOverlays() {
        guard let map else { return }
        let key = currentOverlayKey()
        guard key != overlayKey else { return }
        overlayKey = key
        map.removeOverlays(overlays)
        overlays = []
        activeRenderer = nil
        let c = core
        guard c.mode != .browse else { return }
        var list: [RoutingRouteOverlay] = []
        for (i, r) in c.routes.enumerated() {
            let isActive = i == c.activeRoute
            if c.mode == .drive && !isActive { continue }
            var coords = r.coordinates
            guard coords.count >= 2 else { continue }
            let o = RoutingRouteOverlay(coordinates: &coords, count: coords.count)
            o.routeId = r.id; o.index = i; o.isActive = isActive
            list.append(o)
        }
        // actif d'abord à l'index 0, puis les alternatives à l'index 0 → alternatives sous l'actif,
        // et le tout sous les calques des autres modules
        for o in list where o.isActive { map.insertOverlay(o, at: 0, level: .aboveRoads) }
        for o in list where !o.isActive { map.insertOverlay(o, at: 0, level: .aboveRoads) }
        overlays = list
    }

    private func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        guard let o = overlay as? RoutingRouteOverlay else { return nil }
        let r = RoutingLineRenderer(overlay: o)
        if o.isActive {
            activeRenderer = r
            if core.mode == .drive { r.setPassed(core.progress?.shapeIndex ?? 0) }
        }
        return r
    }

    // MARK: Marqueurs

    private func passedStops() -> Int {
        guard core.mode == .drive, let r = core.route, let idx = model.meta[r.id]?.stopShapeIndex else { return 0 }
        let s = core.progress?.shapeIndex ?? 0
        return idx.filter { $0 < s }.count
    }

    private func currentAnnotationKey() -> String {
        guard core.mode != .browse, let d = core.destination else { return "none" }
        let skip = passedStops()
        return "\(d.id)|\(d.lat),\(d.lng)|" + model.stops.enumerated().map { "\($0.offset < skip ? "x" : $0.element.id)" }.joined(separator: ",")
    }

    private func syncAnnotations() {
        guard let map else { return }
        let key = currentAnnotationKey()
        guard key != annotationKey else { return }
        annotationKey = key
        map.removeAnnotations(annotations)
        annotations = []
        guard core.mode != .browse, let d = core.destination else { return }
        let dest = RoutingDestinationAnnotation()
        dest.coordinate = d.coordinate
        dest.title = d.name
        var list: [MKAnnotation] = [dest]
        let skip = passedStops()
        for (k, s) in model.stops.enumerated() where k >= skip {
            let a = RoutingStopAnnotation()
            a.coordinate = s.coordinate
            a.title = s.name
            a.number = k + 1
            list.append(a)
        }
        map.addAnnotations(list)
        annotations = list
    }

    private static func view(_ map: MKMapView, _ a: MKAnnotation) -> MKAnnotationView? {
        guard a is RoutingDestinationAnnotation || a is RoutingStopAnnotation else { return nil }
        let id = a is RoutingStopAnnotation ? "routing.stop" : "routing.dest"
        let v = (map.dequeueReusableAnnotationView(withIdentifier: id) as? RoutingMarkerView) ?? RoutingMarkerView(annotation: a, reuseIdentifier: id)
        v.annotation = a
        v.configure(a)
        return v
    }

    // MARK: Cadrage

    private func fitKey() -> String {
        let c = core
        guard c.mode == .preview else { return "none" }
        let h = Int(c.sheetHeight / 24)
        if model.status == .error { return "err|\(c.destination?.id ?? "")|\(h)" }
        return c.routes.map(\.id).joined(separator: "|") + "#\(h)"
    }

    private func scheduleFit() {
        fitTask?.cancel()
        // petit délai : le panneau se met en place (hauteur mesurée) avant de cadrer
        fitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.fit()
        }
    }

    private func fit() {
        let c = core
        guard c.mode == .preview, let map else { return }
        let sheet = c.sheetHeight
        if model.status == .error, let d = c.destination {
            var pts = [d.coordinate]
            if let p = c.position { pts.append(p.coordinate) }
            if pts.count == 1 {
                c.follow = false
                map.setRegion(MKCoordinateRegion(center: d.coordinate, latitudinalMeters: 4000, longitudinalMeters: 4000), animated: true)
            } else {
                MapHub.fit(pts)
            }
            return
        }
        guard !c.routes.isEmpty else { return }
        let key = c.routes.map(\.id).joined(separator: "|")
        let isNew = key != fittedKey
        if !isNew && (touched || abs(sheet - fittedHeight) < 24) { return }
        var pts = c.routes.flatMap(\.coordinates)
        if let p = c.position { pts.append(p.coordinate) }
        if map.camera.heading != 0 || map.camera.pitch != 0 {
            let cam = map.camera.copy() as! MKMapCamera
            cam.heading = 0; cam.pitch = 0
            map.setCamera(cam, animated: false)
        }
        MapHub.fit(pts, animated: true)
        fittedKey = key
        touched = false
        fittedHeight = sheet
    }

    // MARK: Gestes

    @objc private func moved(_ g: UIGestureRecognizer) {
        if g.state == .began && core.mode == .preview { touched = true }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, let map else { return }
        let pt = g.location(in: map)
        let c = core
        if model.pickOnMap && c.mode != .browse {
            let coord = map.convert(pt, toCoordinateFrom: map)
            model.pickOnMap = false
            Task { @MainActor in
                let found = await RoutingGeocode.reverse(coord)
                RoutingModel.shared.addStop(RoutingModel.stopPlace(name: found?.name ?? "Étape", coordinate: coord, detail: found?.detail))
            }
            return
        }
        guard c.mode == .preview, c.routes.count > 1 else { return }
        var best: (index: Int, dist: CGFloat)?
        var activeDist = CGFloat.infinity
        for (i, r) in c.routes.enumerated() {
            let d = Self.screenDistance(pt, r.coordinates, map)
            if i == c.activeRoute { activeDist = d; continue }
            if d < (best?.dist ?? .infinity) { best = (i, d) }
        }
        // le tracé actif (au-dessus) a la priorité ; zone de toucher large (une ligne de 4 pt est introuvable au doigt)
        if let best, best.dist < 24, best.dist < activeDist || activeDist > 10 {
            model.selectRoute(best.index)
        }
    }

    /// Distance en points écran entre un toucher et une ligne.
    private static func screenDistance(_ p: CGPoint, _ coords: [CLLocationCoordinate2D], _ map: MKMapView) -> CGFloat {
        guard coords.count >= 2 else { return .infinity }
        let bounds = map.bounds.insetBy(dx: -60, dy: -60)
        var best = CGFloat.infinity
        var prev = map.convert(coords[0], toPointTo: map)
        for k in 1..<coords.count {
            let cur = map.convert(coords[k], toPointTo: map)
            defer { prev = cur }
            if !bounds.contains(prev) && !bounds.contains(cur) { continue }
            let dx = cur.x - prev.x, dy = cur.y - prev.y
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, ((p.x - prev.x) * dx + (p.y - prev.y) * dy) / len2)) : 0
            let x = prev.x + dx * t - p.x, y = prev.y + dy * t - p.y
            best = min(best, (x * x + y * y).squareRoot())
        }
        return best
    }
}
