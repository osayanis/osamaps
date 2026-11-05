import MapKit
import UIKit
import Observation

/// Calques de la carte (port de `SafetyLayers.tsx`) :
///  - périmètres ZFE (trait discret en pointillés), visibles quand la vue couvre moins de ~3° ;
///  - zones de danger de toute la France, dans tous les modes et à tous les zooms (pastille quand
///    la zone est trop petite à l'écran, disque sinon) ;
///  - portions de l'itinéraire en zone de danger (aperçu et conduite).
/// Jamais la position d'un radar : les pastilles (vue large) sont le centre DÉCALÉ d'une zone.
final class SafetyZfePolygon: MKPolygon {}
final class SafetyRouteZoneLine: MKPolyline {}

@MainActor
final class SafetyMapController {
    static let shared = SafetyMapController()

    private weak var map: MKMapView?
    private var zfeOverlays: [SafetyZfePolygon] = []
    private var zfeShown = false
    private var zonesOverlay: SafetyZonesOverlay?
    private var zonesShown = false
    private var zonesLoading = false
    private var routeOverlays: [SafetyRouteZoneLine] = []
    private var zfeLoading = false

    private init() {}

    var layer: MapLayer {
        MapLayer(id: "safety", zIndex: 60,
                 attach: { map in SafetyMapController.shared.attach(map) },
                 renderer: { overlay in SafetyMapController.renderer(overlay) },
                 regionDidChange: { map in SafetyMapController.shared.regionChanged(map) })
    }

    private func attach(_ map: MKMapView) {
        self.map = map
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

    // MARK: Zones de danger (toute la France)

    private func updateZones(_ map: MKMapView) {
        let want = SafetySettings.shared.dangerZones
        if want, zonesOverlay == nil {
            guard !zonesLoading else { return }
            zonesLoading = true
            Task {
                let zones = await SafetyData.allZones()
                zonesLoading = false
                guard !zones.isEmpty else { return }
                zonesOverlay = SafetyZonesOverlay(zones)
                updateZones(map)
            }
            return
        }
        guard let o = zonesOverlay else { return }
        if want && !zonesShown { map.addOverlay(o, level: .aboveRoads); zonesShown = true }
        else if !want && zonesShown { map.removeOverlay(o); zonesShown = false }
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
        case let o as SafetyZonesOverlay:
            return SafetyZonesRenderer(o, color: danger)
        case let o as SafetyRouteZoneLine:
            let r = MKPolylineRenderer(polyline: o)
            r.strokeColor = danger.withAlphaComponent(0.5)
            r.lineWidth = 12
            r.lineCap = .round
            r.lineJoin = .round
            return r
        default:
            return nil
        }
    }
}

/// Toutes les zones de danger en UN overlay (≈ 3 300 disques) : un MKCircle par zone serait trop lourd.
/// Données immuables, lues par le rendu sur les fils de MapKit.
final class SafetyZonesOverlay: NSObject, MKOverlay, @unchecked Sendable {
    let points: [MKMapPoint]
    /// Rayons en points de carte (dépendent de la latitude).
    let radii: [Double]
    let maxRadius: Double
    let coordinate = CLLocationCoordinate2D(latitude: 46.6, longitude: 2.4)
    let boundingMapRect = MKMapRect.world

    init(_ zones: [SafetyZone]) {
        points = zones.map { MKMapPoint($0.center) }
        radii = zones.map { $0.r * MKMapPointsPerMeterAtLatitude($0.lat) }
        maxRadius = radii.max() ?? 0
    }
}

final class SafetyZonesRenderer: MKOverlayRenderer, @unchecked Sendable {
    private let zones: SafetyZonesOverlay
    private let color: CGColor
    private let dotFill: CGColor
    private let diskFill: CGColor
    private let diskStroke: CGColor
    private let dotStroke = UIColor.black.withAlphaComponent(0.55).cgColor

    init(_ o: SafetyZonesOverlay, color: UIColor) {
        zones = o
        self.color = color.cgColor
        dotFill = color.withAlphaComponent(0.85).cgColor
        diskFill = color.withAlphaComponent(0.1).cgColor
        diskStroke = color.withAlphaComponent(0.75).cgColor
        super.init(overlay: o)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        let px = 1 / Double(zoomScale) // un point d'écran, en points de carte
        let dotR = 3.5 * px            // une zone plus petite que ça devient une pastille
        let pad = max(zones.maxRadius, dotR) + 2 * px
        let area = mapRect.insetBy(dx: -pad, dy: -pad)
        var dots: [CGRect] = [], disks: [CGRect] = []
        for (i, p) in zones.points.enumerated() where area.contains(p) {
            let r = zones.radii[i]
            if r < dotR * 2 {
                dots.append(CGRect(x: p.x - dotR, y: p.y - dotR, width: 2 * dotR, height: 2 * dotR))
            } else {
                disks.append(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
        }
        if !disks.isEmpty {
            ctx.setFillColor(diskFill)
            for d in disks { ctx.fillEllipse(in: d) }
            ctx.setStrokeColor(diskStroke)
            ctx.setLineWidth(1.5 * px)
            ctx.setLineDash(phase: 0, lengths: [4 * px, 4 * px])
            for d in disks { ctx.strokeEllipse(in: d) }
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if !dots.isEmpty {
            ctx.setFillColor(dotFill)
            ctx.setStrokeColor(dotStroke)
            ctx.setLineWidth(1 * px)
            for d in dots { ctx.fillEllipse(in: d); ctx.strokeEllipse(in: d) }
        }
    }
}
