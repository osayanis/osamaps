import MapKit
import UIKit

/// Calques de l'itinéraire (port de `RoutingLayer.tsx`) : alternatives grises touchables, tracé actif
/// blanc avec halo, partie déjà parcourue estompée en conduite, marqueurs d'arrivée et d'étapes.
/// Les tracés sont insérés TOUT EN BAS des overlays « aboveRoads » : les calques des autres modules
/// (trafic, signalements…) restent visibles par-dessus.

/// Une couche d'un tracé d'itinéraire. Chaque tracé est fait de plusieurs `MKPolyline` empilées
/// (halo, liseré, trait…) rendues par `MKPolylineRenderer` : MapKit les dessine en vectoriel,
/// sans raccords de tuiles en vue inclinée.
final class RoutingRouteOverlay: MKPolyline {
    enum Role: Int { case altCasing, alt, glow, casing, passed, line }
    var role: Role = .line
    var routeId = ""
    var index = 0
    var isActive: Bool { role != .alt && role != .altCasing }
}

final class RoutingDestinationAnnotation: MKPointAnnotation {}

final class RoutingStopAnnotation: MKPointAnnotation {
    var number = 1
}

/// Style de chaque couche (largeur en points écran, interpolée entre le zoom 8 et le zoom 16 comme la version web).
enum RoutingStyle {
    static func width(_ role: RoutingRouteOverlay.Role, zoom z: Double) -> CGFloat {
        let t = max(0, min(1, (z - 8) / 8))
        func w(_ a: Double, _ b: Double) -> CGFloat { CGFloat(a + (b - a) * t) }
        switch role {
        case .altCasing: return w(6, 12)
        case .alt: return w(3.5, 8)
        case .glow: return w(14, 26)
        case .casing: return w(7, 14)
        case .passed: return w(3.5, 9)
        case .line: return w(4, 9)
        }
    }

    static func color(_ role: RoutingRouteOverlay.Role) -> UIColor {
        switch role {
        case .altCasing: return UIColor.black.withAlphaComponent(0.35)
        case .alt: return UIColor(red: 0.604, green: 0.604, blue: 0.635, alpha: 0.7)
        case .glow: return UIColor.white.withAlphaComponent(0.14)
        case .casing: return UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 0.8)
        case .passed: return UIColor.white.withAlphaComponent(0.22)
        case .line: return .white
        }
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
    private var renderers: [ObjectIdentifier: MKPolylineRenderer] = [:]
    /// Distances cumulées du tracé actif (fraction parcourue pour strokeStart/strokeEnd).
    private var activeCum: [Double] = []
    private var passedIndex = 0
    private var zoomBucket = -1
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
                 didSelect: { _, a in a is RoutingDestinationAnnotation || a is RoutingStopAnnotation },
                 regionDidChange: { [unowned self] map in self.updateWidths(map) },
                 tap: { [unowned self] coord in self.tapped(coord) })
    }

    private func attach(_ map: MKMapView) {
        self.map = map
        for g in [UIPanGestureRecognizer(target: self, action: #selector(moved(_:))),
                  UIPinchGestureRecognizer(target: self, action: #selector(moved(_:)))] as [UIGestureRecognizer] {
            g.cancelsTouchesInView = false
            g.delegate = self
            map.addGestureRecognizer(g)
        }

        RoutingObserve.watch({ [unowned self] in self.currentOverlayKey() }) { [unowned self] _ in self.syncOverlays() }
        RoutingObserve.watch({ [unowned self] in self.currentAnnotationKey() }) { [unowned self] _ in self.syncAnnotations() }
        RoutingObserve.watch({ Core.shared.mode == .drive ? (Core.shared.progress?.shapeIndex ?? 0) : 0 }) { [unowned self] i in
            self.setPassed(i)
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
        renderers = [:]
        activeCum = []
        passedIndex = 0
        let c = core
        guard c.mode != .browse else { return }
        var list: [RoutingRouteOverlay] = []
        for (i, r) in c.routes.enumerated() {
            let isActive = i == c.activeRoute
            if c.mode == .drive && !isActive { continue }
            var coords = r.coordinates
            guard coords.count >= 2 else { continue }
            let roles: [RoutingRouteOverlay.Role] = isActive
                ? (c.mode == .drive ? [.glow, .casing, .passed, .line] : [.glow, .casing, .line])
                : [.altCasing, .alt]
            for role in roles {
                let o = RoutingRouteOverlay(coordinates: &coords, count: coords.count)
                o.role = role; o.routeId = r.id; o.index = i
                list.append(o)
            }
            if isActive { activeCum = Geo.cumulative(coords) }
        }
        // ordre voulu (dessous → dessus) : alternatives, puis halo, liseré, parcouru, trait.
        // Insérées à l'index 0 dans l'ordre inverse → tout reste SOUS les calques des autres modules.
        // En conduite (vue inclinée), les bâtiments 3D masqueraient le tracé : on le pose au-dessus des libellés.
        let activeLevel: MKOverlayLevel = c.mode == .drive ? .aboveLabels : .aboveRoads
        let sorted = list.sorted { ($0.role.rawValue, $0.index) < ($1.role.rawValue, $1.index) }
        for o in sorted.reversed() { map.insertOverlay(o, at: 0, level: o.isActive ? activeLevel : .aboveRoads) }
        overlays = list
        if c.mode == .drive { setPassed(c.progress?.shapeIndex ?? 0) }
    }

    private func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        guard let o = overlay as? RoutingRouteOverlay else { return nil }
        let r = MKPolylineRenderer(polyline: o)
        r.strokeColor = RoutingStyle.color(o.role)
        r.lineWidth = RoutingStyle.width(o.role, zoom: Self.zoom(map))
        r.lineCap = .round
        r.lineJoin = .round
        renderers[ObjectIdentifier(o)] = r
        applyPassed(o, r)
        return r
    }

    private static func zoom(_ map: MKMapView?) -> Double {
        guard let map, map.bounds.width > 0 else { return 14 }
        // largeur visible en points de carte → niveau de zoom (monde = 256 × 2^z points écran)
        let scale = Double(map.bounds.width) / map.visibleMapRect.size.width
        return 20 + log2(max(scale, 1e-9))
    }

    /// Largeurs selon le zoom (seulement quand on change de demi-niveau).
    private func updateWidths(_ map: MKMapView) {
        let z = Self.zoom(map)
        let bucket = Int((z * 2).rounded())
        guard bucket != zoomBucket else { return }
        zoomBucket = bucket
        for o in overlays {
            guard let r = renderers[ObjectIdentifier(o)] else { continue }
            r.lineWidth = RoutingStyle.width(o.role, zoom: z)
            r.setNeedsDisplay()
        }
    }

    /// Partie parcourue (conduite) : le trait plein commence où l'on est, l'estompé s'arrête là.
    private func setPassed(_ index: Int) {
        guard !activeCum.isEmpty else { return }
        let i = max(0, min(index, activeCum.count - 1))
        guard i != passedIndex else { return }
        passedIndex = i
        for o in overlays where o.isActive {
            if let r = renderers[ObjectIdentifier(o)] { applyPassed(o, r); r.setNeedsDisplay() }
        }
    }

    private func applyPassed(_ o: RoutingRouteOverlay, _ r: MKPolylineRenderer) {
        guard o.isActive, let total = activeCum.last, total > 0, passedIndex < activeCum.count else { return }
        let f = CGFloat(activeCum[passedIndex] / total)
        if o.role == .passed { r.strokeStart = 0; r.strokeEnd = f } else { r.strokeStart = f; r.strokeEnd = 1 }
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
        MapHub.fit(pts, animated: true)
        fittedKey = key
        touched = false
        fittedHeight = sheet
    }

    // MARK: Gestes

    @objc private func moved(_ g: UIGestureRecognizer) {
        if g.state == .began && core.mode == .preview { touched = true }
    }

    /// Tape sur la carte (hors annotation) : poser une étape, ou choisir une alternative. true = géré.
    private func tapped(_ coord: CLLocationCoordinate2D) -> Bool {
        guard let map else { return false }
        let pt = map.convert(coord, toPointTo: map)
        let c = core
        if model.pickOnMap && c.mode != .browse {
            model.pickOnMap = false
            Task { @MainActor in
                let found = await RoutingGeocode.reverse(coord)
                RoutingModel.shared.addStop(RoutingModel.stopPlace(name: found?.name ?? "Étape", coordinate: coord, detail: found?.detail))
            }
            return true
        }
        guard c.mode == .preview, c.routes.count > 1 else { return false }
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
            return true
        }
        return false
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
