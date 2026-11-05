import MapKit
import UIKit
import Observation

/// Calques de la carte (port de `SafetyLayers.tsx`) :
///  - périmètres ZFE (trait discret en pointillés), visibles quand la vue couvre moins de ~3° ;
///  - zones de danger « façon Waze » : rien en vue large, une icône discrète par zone (au MILIEU du tronçon,
///    regroupées par MapKit quand elles se chevauchent) à moyenne échelle, et de près le tronçon surligné sur
///    la route. Seules les tuiles visibles sont chargées ;
///  - portions de l'itinéraire en zone de danger (aperçu et conduite).
/// Jamais la position d'un radar : le serveur ne l'envoie pas (l'appareil est entre 15 et 85 % du tronçon).
final class SafetyZfePolygon: MKPolygon {}
final class SafetyRouteZoneLine: MKPolyline {}

@MainActor
final class SafetyMapController {
    static let shared = SafetyMapController()
    /// Au-delà (latitude, en degrés : ~250 km), la vue est trop large : pas de zones (comme Waze).
    static let maxSpan = 2.4

    private weak var map: MKMapView?
    private var zfeOverlays: [SafetyZfePolygon] = []
    private var zfeShown = false
    private var zfeLoading = false
    private let segments = SafetySegmentsOverlay()
    private var segmentsShown = false
    private var shown: [String: SafetyZoneAnnotation] = [:]
    private var zonesTask: Task<Void, Never>?
    private var regionWork: DispatchWorkItem?
    private var routeOverlays: [SafetyRouteZoneLine] = []

    private init() {}

    var layer: MapLayer {
        MapLayer(id: "safety", zIndex: 60,
                 attach: { map in SafetyMapController.shared.attach(map) },
                 renderer: { overlay in SafetyMapController.renderer(overlay) },
                 annotationView: { map, annotation in
                     if annotation is SafetyZoneAnnotation {
                         return map.dequeueReusableAnnotationView(withIdentifier: SafetyZoneView.reuse, for: annotation)
                     }
                     if let c = annotation as? MKClusterAnnotation, c.memberAnnotations.first is SafetyZoneAnnotation {
                         return map.dequeueReusableAnnotationView(withIdentifier: SafetyZoneClusterView.reuse, for: annotation)
                     }
                     return nil
                 },
                 didSelect: { map, annotation in SafetyMapController.shared.select(map, annotation) },
                 regionDidChange: { map in SafetyMapController.shared.regionChanged(map) })
    }

    private func attach(_ map: MKMapView) {
        self.map = map
        map.register(SafetyZoneView.self, forAnnotationViewWithReuseIdentifier: SafetyZoneView.reuse)
        map.register(SafetyZoneClusterView.self, forAnnotationViewWithReuseIdentifier: SafetyZoneClusterView.reuse)
        observe()
        refresh()
    }

    /// Redessine quand l'analyse, le mode ou les réglages changent.
    private func observe() {
        withObservationTracking {
            let e = SafetyEngine.shared, s = SafetySettings.shared
            _ = e.dangers; _ = e.routeId; _ = Core.shared.mode; _ = s.dangerZones; _ = s.zfe
        } onChange: {
            Task { @MainActor in
                SafetyMapController.shared.refresh()
                SafetyMapController.shared.observe()
            }
        }
    }

    private func refresh() {
        guard let map else { return }
        drawRouteZones(map)
        updateZfe(map)
        updateZones(map)
    }

    private func regionChanged(_ map: MKMapView) {
        updateZfe(map)
        // en conduite la caméra bouge sans arrêt : on regroupe les mises à jour
        regionWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { SafetyMapController.shared.updateZones(map) } }
        regionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func select(_ map: MKMapView, _ annotation: MKAnnotation) -> Bool {
        if let a = annotation as? SafetyZoneAnnotation {
            Haptic.play("light")
            emit(.toast(Toast(text: "Zone de danger sur \(Geo.formatDistance(a.length)) : reste attentif",
                              icon: "exclamationmark.triangle.fill", tone: .warn)))
            return true
        }
        if let c = annotation as? MKClusterAnnotation, c.memberAnnotations.first is SafetyZoneAnnotation {
            MapHub.fit(c.memberAnnotations.map(\.coordinate))
            return true
        }
        return false
    }

    // MARK: ZFE

    private func updateZfe(_ map: MKMapView) {
        let want = SafetySettings.shared.zfe && map.region.span.latitudeDelta < 3
        if want && zfeOverlays.isEmpty && !zfeLoading {
            zfeLoading = true
            Task {
                defer { zfeLoading = false }
                guard let r = try? await SafetyData.zfe() else { return }
                zfeOverlays = r.features.flatMap(Self.polygons)
                updateZfe(map)
            }
            return
        }
        if want && !zfeShown && !zfeOverlays.isEmpty {
            map.addOverlays(zfeOverlays, level: .aboveRoads)
            zfeShown = true
        } else if !want && zfeShown {
            map.removeOverlays(zfeOverlays)
            zfeShown = false
        }
    }

    private static func polygons(_ f: SafetyZfeFeature) -> [SafetyZfePolygon] {
        f.geometry.coordinates.compactMap { poly in
            guard let outer = poly.first, outer.count >= 3 else { return nil }
            let ring = { (r: [[Double]]) in r.filter { $0.count >= 2 }.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) } }
            let holes = poly.dropFirst().map { r -> MKPolygon in
                let c = ring(r)
                return MKPolygon(coordinates: c, count: c.count)
            }
            let c = ring(outer)
            let p = SafetyZfePolygon(coordinates: c, count: c.count, interiorPolygons: holes)
            p.title = f.properties.name
            return p
        }
    }

    // MARK: Zones de danger (tuiles visibles)

    private func updateZones(_ map: MKMapView) {
        let want = SafetySettings.shared.dangerZones
        if want != segmentsShown {
            if want { map.addOverlay(segments, level: .aboveRoads) } else { map.removeOverlay(segments) }
            segmentsShown = want
        }
        let region = map.region
        guard want, region.span.latitudeDelta < Self.maxSpan, region.span.latitudeDelta > 0 else {
            zonesTask?.cancel()
            syncAnnotations(map, [])
            return
        }
        // la vue + une marge d'un quart de chaque côté (déplacement sans trou)
        let c = region.center, s = region.span
        let w = c.longitude - s.longitudeDelta * 0.75, e = c.longitude + s.longitudeDelta * 0.75
        let so = c.latitude - s.latitudeDelta * 0.75, n = c.latitude + s.latitudeDelta * 0.75
        let keys = SafetyGeo.zoneTiles(w: w, s: so, e: e, n: n, limit: 24)
        let area = (w: w, s: so, e: e, n: n)
        apply(map, keys: keys, area: area) // tout de suite ce qui est en cache
        zonesTask?.cancel()
        zonesTask = Task {
            _ = await SafetyData.zoneTiles(keys)
            guard !Task.isCancelled else { return }
            apply(map, keys: keys, area: area)
        }
    }

    private func apply(_ map: MKMapView, keys: [String], area: (w: Double, s: Double, e: Double, n: Double)) {
        var zones: [SafetyZone] = []
        for k in keys { zones += SafetyData.cachedZones(k) ?? [] }
        if segments.add(zones) { (map.renderer(for: segments) as? SafetySegmentsRenderer)?.setNeedsDisplay() }
        let visible = zones.filter {
            $0.mid.longitude >= area.w && $0.mid.longitude <= area.e && $0.mid.latitude >= area.s && $0.mid.latitude <= area.n
        }
        syncAnnotations(map, visible)
    }

    /// Ajoute / retire les icônes pour coller aux zones voulues (MapKit les regroupe).
    private func syncAnnotations(_ map: MKMapView, _ zones: [SafetyZone]) {
        var want: [String: SafetyZone] = [:]
        for z in zones { want[z.id] = z }
        let gone = shown.filter { want[$0.key] == nil }
        if !gone.isEmpty {
            map.removeAnnotations(Array(gone.values))
            for k in gone.keys { shown[k] = nil }
        }
        let new = want.values.filter { shown[$0.id] == nil }.map(SafetyZoneAnnotation.init)
        if !new.isEmpty {
            for a in new { shown[a.id] = a }
            map.addAnnotations(new)
        }
    }

    // MARK: Itinéraire

    private func drawRouteZones(_ map: MKMapView) {
        map.removeOverlays(routeOverlays)
        routeOverlays = []
        let e = SafetyEngine.shared
        guard SafetySettings.shared.dangerZones, Core.shared.mode != .browse, !e.coords.isEmpty else { return }
        routeOverlays = e.dangers.map { z in
            let line = SafetyAnalysis.slice(e.coords, e.cum, from: z.start, to: z.end)
            return SafetyRouteZoneLine(coordinates: line, count: line.count)
        }
        map.addOverlays(routeOverlays, level: .aboveRoads)
    }

    // MARK: Rendus

    static func renderer(_ overlay: MKOverlay) -> MKOverlayRenderer? {
        let danger = UIColor(Osa.danger)
        switch overlay {
        case let o as SafetyZfePolygon:
            let r = MKPolygonRenderer(polygon: o)
            r.fillColor = UIColor.white.withAlphaComponent(0.035)
            r.strokeColor = UIColor.white.withAlphaComponent(0.4)
            r.lineWidth = 1.5
            r.lineDashPattern = [6, 4]
            return r
        case let o as SafetySegmentsOverlay:
            return SafetySegmentsRenderer(o, color: danger)
        case let o as SafetyRouteZoneLine:
            let r = MKPolylineRenderer(polyline: o)
            r.strokeColor = danger.withAlphaComponent(0.6)
            r.lineWidth = 12
            r.lineCap = .round
            r.lineJoin = .round
            return r
        default:
            return nil
        }
    }
}

// MARK: - Icônes

/// Icône d'une zone : au milieu du tronçon (jamais sur l'appareil).
final class SafetyZoneAnnotation: NSObject, MKAnnotation {
    let id: String
    let kind: String
    let length: Double
    let coordinate: CLLocationCoordinate2D
    var title: String? { "Zone de danger" }

    init(_ z: SafetyZone) {
        id = z.id; kind = z.kind; length = z.length; coordinate = z.mid
    }
}

@MainActor
enum SafetyZoneImages {
    static let size: CGFloat = 24

    /// Pastille sombre, liseré jaune, triangle « danger ».
    static let single: UIImage = badge(count: nil)

    private static var clusters: [String: UIImage] = [:]
    static func cluster(_ n: Int) -> UIImage {
        let text = n > 99 ? "99+" : "\(n)"
        if let i = clusters[text] { return i }
        let i = badge(count: text)
        clusters[text] = i
        return i
    }

    private static func badge(count: String?) -> UIImage {
        let d = size
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: UIColor.black]
        let textSize = (count as NSString?)?.size(withAttributes: attrs) ?? .zero
        let pillW = count == nil ? 0 : max(16, textSize.width + 8)
        let pillH: CGFloat = 16
        // la pastille du nombre déborde en haut à droite
        let total = CGSize(width: d + (count == nil ? 0 : pillW - 8), height: d + (count == nil ? 0 : 6))
        let origin = CGPoint(x: 0, y: total.height - d)
        let yellow = UIColor(Osa.danger)
        return UIGraphicsImageRenderer(size: total).image { ctx in
            let g = ctx.cgContext
            let circle = CGRect(origin: origin, size: CGSize(width: d, height: d)).insetBy(dx: 0.75, dy: 0.75)
            g.setFillColor(UIColor(red: 14 / 255, green: 14 / 255, blue: 20 / 255, alpha: 0.92).cgColor)
            g.fillEllipse(in: circle)
            g.setStrokeColor(yellow.withAlphaComponent(0.9).cgColor)
            g.setLineWidth(1.5)
            g.strokeEllipse(in: circle)
            let cfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                .applying(UIImage.SymbolConfiguration(paletteColors: [.black, yellow]))
            if let sym = UIImage(systemName: "exclamationmark.triangle.fill", withConfiguration: cfg) {
                let s = sym.size
                sym.draw(in: CGRect(x: origin.x + (d - s.width) / 2, y: origin.y + (d - s.height) / 2 - 0.5, width: s.width, height: s.height))
            }
            if let count {
                let pill = CGRect(x: total.width - pillW, y: 0, width: pillW, height: pillH)
                g.setFillColor(UIColor.white.cgColor)
                g.addPath(UIBezierPath(roundedRect: pill, cornerRadius: pillH / 2).cgPath)
                g.fillPath()
                (count as NSString).draw(at: CGPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2), withAttributes: attrs)
            }
        }
    }
}

final class SafetyZoneView: MKAnnotationView {
    static let reuse = "safety.zone"
    static let cluster = "safety-zone"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = Self.cluster
        collisionMode = .circle
        canShowCallout = false
        // discrètes : les signalements et la police passent devant
        displayPriority = MKFeatureDisplayPriority(rawValue: 600)
        zPriority = MKAnnotationViewZPriority(rawValue: 200)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        clusteringIdentifier = Self.cluster
        image = MainActor.assumeIsolated { SafetyZoneImages.single }
        accessibilityLabel = "Zone de danger"
        isAccessibilityElement = true
    }
}

final class SafetyZoneClusterView: MKAnnotationView {
    static let reuse = "safety.zone.cluster"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .circle
        canShowCallout = false
        displayPriority = MKFeatureDisplayPriority(rawValue: 650)
        zPriority = MKAnnotationViewZPriority(rawValue: 210)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        guard let c = annotation as? MKClusterAnnotation else { return }
        let n = c.memberAnnotations.count
        image = MainActor.assumeIsolated { SafetyZoneImages.cluster(n) }
        // l'icône (pas la pastille du nombre) est centrée sur le groupe
        centerOffset = CGPoint(x: (image?.size.width ?? 0) / 2 - SafetyZoneImages.size / 2,
                               y: -((image?.size.height ?? 0) / 2 - SafetyZoneImages.size / 2))
        accessibilityLabel = "\(n) zones de danger"
        isAccessibilityElement = true
    }
}

// MARK: - Tronçons surlignés

/// Tous les tronçons chargés en UN overlay (un MKPolyline par zone serait trop lourd en déplaçant la carte).
/// Complété au fil des tuiles chargées ; lu par le rendu sur les fils de MapKit (verrou).
final class SafetySegmentsOverlay: NSObject, MKOverlay, @unchecked Sendable {
    struct Item: Sendable {
        let rect: MKMapRect
        let lines: [[MKMapPoint]]
        /// Longueur en points de carte (pour ne dessiner que les tronçons assez longs à l'écran).
        let mapLength: Double
        /// Disque de repli : centre et rayon en points de carte.
        let disk: (center: MKMapPoint, r: Double)?
    }

    private let lock = NSLock()
    private var byId: [String: Item] = [:]
    private var list: [Item] = []
    let coordinate = CLLocationCoordinate2D(latitude: 46.6, longitude: 2.4)
    let boundingMapRect = MKMapRect.world

    var items: [Item] {
        lock.lock(); defer { lock.unlock() }
        return list
    }

    /// Ajoute les zones inconnues ; true si quelque chose a changé.
    func add(_ zones: [SafetyZone]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        for z in zones where byId[z.id] == nil {
            let ppm = MKMapPointsPerMeterAtLatitude(z.mid.latitude)
            let item: Item
            if let r = z.radius {
                let c = MKMapPoint(z.mid), rr = r * ppm
                item = Item(rect: MKMapRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr),
                            lines: [], mapLength: 2 * rr, disk: (c, rr))
            } else {
                let lines = z.lines.map { $0.map(MKMapPoint.init) }
                var rect = MKMapRect.null
                for l in lines { for p in l { rect = rect.union(MKMapRect(origin: p, size: MKMapSize(width: 0, height: 0))) } }
                item = Item(rect: rect, lines: lines, mapLength: z.length * ppm, disk: nil)
            }
            byId[z.id] = item
            changed = true
        }
        if changed { list = Array(byId.values) }
        return changed
    }
}

final class SafetySegmentsRenderer: MKOverlayRenderer, @unchecked Sendable {
    private let segments: SafetySegmentsOverlay
    private let stroke: CGColor
    private let diskFill: CGColor
    private let diskStroke: CGColor

    init(_ o: SafetySegmentsOverlay, color: UIColor) {
        segments = o
        stroke = color.withAlphaComponent(0.5).cgColor
        diskFill = color.withAlphaComponent(0.08).cgColor
        diskStroke = color.withAlphaComponent(0.6).cgColor
        super.init(overlay: o)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        let px = 1 / Double(zoomScale) // un point d'écran, en points de carte
        let width = 7 * px
        let minLength = 16 * px        // un tronçon plus court que ça à l'écran n'est pas dessiné (l'icône suffit)
        let area = mapRect.insetBy(dx: -width, dy: -width)
        let path = CGMutablePath()
        var disks: [CGRect] = []
        for it in segments.items where it.mapLength >= minLength && it.rect.intersects(area) {
            if let d = it.disk {
                let c = point(for: d.center)
                disks.append(CGRect(x: c.x - d.r, y: c.y - d.r, width: 2 * d.r, height: 2 * d.r))
                continue
            }
            for line in it.lines where line.count >= 2 {
                path.move(to: point(for: line[0]))
                for p in line.dropFirst() { path.addLine(to: point(for: p)) }
            }
        }
        if !path.isEmpty {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
        if !disks.isEmpty {
            ctx.setFillColor(diskFill)
            for d in disks { ctx.fillEllipse(in: d) }
            ctx.setStrokeColor(diskStroke)
            ctx.setLineWidth(1.5 * px)
            ctx.setLineDash(phase: 0, lengths: [4 * px, 4 * px])
            for d in disks { ctx.strokeEllipse(in: d) }
        }
    }
}
