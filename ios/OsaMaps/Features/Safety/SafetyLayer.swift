import MapKit
import UIKit
import Observation

/// Calques de la carte (port de `SafetyLayers.tsx`) :
///  - périmètres ZFE (trait discret en pointillés), visibles quand la vue couvre moins de ~3° ;
///  - disques des zones de danger en exploration (vue resserrée) ;
///  - portions de l'itinéraire en zone de danger (aperçu et conduite).
/// Jamais de marqueur ponctuel : on ne montre pas où est l'appareil.
final class SafetyZfePolygon: MKPolygon {}
final class SafetyZoneCircle: MKCircle {}
final class SafetyRouteZoneLine: MKPolyline {}

@MainActor
final class SafetyMapController {
    static let shared = SafetyMapController()

    private weak var map: MKMapView?
    private var zfeOverlays: [SafetyZfePolygon] = []
    private var zfeShown = false
    private var zoneOverlays: [SafetyZoneCircle] = []
    private var zoneKey = ""
    private var routeOverlays: [SafetyRouteZoneLine] = []
    private var zoneTimer: Timer?
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
        if Core.shared.mode != .browse || !SafetySettings.shared.dangerZones { clearZones(map) } else { scheduleZones(map) }
    }

    private func regionChanged(_ map: MKMapView) {
        updateZfe(map)
        if Core.shared.mode == .browse && SafetySettings.shared.dangerZones { scheduleZones(map) } else { clearZones(map) }
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

    // MARK: Zones de danger (exploration)

    private func scheduleZones(_ map: MKMapView) {
        zoneTimer?.invalidate()
        zoneTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
            Task { @MainActor in SafetyMapController.shared.loadZones() }
        }
    }

    private func loadZones() {
        guard let map, Core.shared.mode == .browse, SafetySettings.shared.dangerZones else { return }
        let r = map.region
        // vue resserrée seulement (≈ zoom 9 de la version web)
        guard r.span.latitudeDelta < 1.2 else { clearZones(map); return }
        let b = (w: r.center.longitude - r.span.longitudeDelta / 2, s: r.center.latitude - r.span.latitudeDelta / 2,
                 e: r.center.longitude + r.span.longitudeDelta / 2, n: r.center.latitude + r.span.latitudeDelta / 2)
        Task {
            guard let res = try? await SafetyData.zones(b), Core.shared.mode == .browse,
                  SafetySettings.shared.dangerZones else { return }
            let key = res.zones.map(\.id).sorted().joined(separator: ",")
            guard key != zoneKey else { return }
            map.removeOverlays(zoneOverlays)
            zoneOverlays = res.zones.map { SafetyZoneCircle(center: $0.center, radius: $0.r) }
            zoneKey = key
            map.addOverlays(zoneOverlays, level: .aboveRoads)
        }
    }

    private func clearZones(_ map: MKMapView) {
        zoneTimer?.invalidate()
        guard !zoneOverlays.isEmpty else { return }
        map.removeOverlays(zoneOverlays)
        zoneOverlays = []
        zoneKey = ""
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
        case let o as SafetyZoneCircle:
            let r = MKCircleRenderer(circle: o)
            r.fillColor = danger.withAlphaComponent(0.07)
            r.strokeColor = danger.withAlphaComponent(0.55)
            r.lineWidth = 1.2
            r.lineDashPattern = [4, 4]
            return r
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
