import MapKit
import UIKit

/// Annotation d'un signalement (sous-classe propre au module : on reconnaît nos objets).
final class ReportsAnnotation: NSObject, MKAnnotation {
    let id: String
    var kind: ReportsKind
    var sub: String?
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { kind.title(sub: sub) }

    init(_ r: Report) {
        id = r.id; kind = r.type; sub = r.sub; coordinate = r.coordinate
    }
}

/// Pastille ronde (couleur d'état + pictogramme) ; regroupée à faible zoom.
final class ReportsAnnotationView: MKAnnotationView {
    static let reuse = "reports.point"
    static let cluster = "reports"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = Self.cluster
        collisionMode = .circle
        canShowCallout = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        clusteringIdentifier = Self.cluster
        guard let a = annotation as? ReportsAnnotation else { return }
        image = MainActor.assumeIsolated { ReportsImages.disc(a.kind, sub: a.sub) }
        displayPriority = MKFeatureDisplayPriority(rawValue: 900 + Float(a.kind.rank))
        zPriority = MKAnnotationViewZPriority(rawValue: 500 + Float(a.kind.rank))
        accessibilityLabel = a.title
        isAccessibilityElement = true
    }
}

/// Groupe de signalements : disque sombre, liseré blanc, nombre.
final class ReportsClusterView: MKAnnotationView {
    static let reuse = "reports.cluster"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .circle
        canShowCallout = false
        displayPriority = .required
    }
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        guard let c = annotation as? MKClusterAnnotation else { return }
        let n = c.memberAnnotations.count
        let r: CGFloat = n >= 50 ? 22 : n >= 10 ? 18 : 15
        let s = r * 2
        let text = n > 999 ? "\(n / 1000)k" : "\(n)"
        image = UIGraphicsImageRenderer(size: CGSize(width: s, height: s)).image { ctx in
            let g = ctx.cgContext
            g.setFillColor(UIColor(red: 14 / 255, green: 14 / 255, blue: 20 / 255, alpha: 0.9).cgColor)
            g.fillEllipse(in: CGRect(x: 0.75, y: 0.75, width: s - 1.5, height: s - 1.5))
            g.setStrokeColor(UIColor.white.withAlphaComponent(0.55).cgColor)
            g.setLineWidth(1.5)
            g.strokeEllipse(in: CGRect(x: 0.75, y: 0.75, width: s - 1.5, height: s - 1.5))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: UIColor.white]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: CGPoint(x: (s - size.width) / 2, y: (s - size.height) / 2), withAttributes: attrs)
        }
        accessibilityLabel = "\(n) signalements"
        isAccessibilityElement = true
    }
}

/// Calque de carte : synchronise les annotations avec `ReportsStore.items`, charge la zone visible
/// (et rejoint ses tuiles temps réel), ouvre la fiche au toucher, zoome sur un groupe.
@MainActor
enum ReportsLayer {
    private static weak var map: MKMapView?
    private static var shown: [String: ReportsAnnotation] = [:]
    private static var syncScheduled = false
    private static var refreshScheduled = false

    static var layer: MapLayer {
        MapLayer(id: "reports", zIndex: 400,
                 attach: { map in
                     self.map = map
                     map.register(ReportsAnnotationView.self, forAnnotationViewWithReuseIdentifier: ReportsAnnotationView.reuse)
                     map.register(ReportsClusterView.self, forAnnotationViewWithReuseIdentifier: ReportsClusterView.reuse)
                     ReportsStore.shared.onItemsChange = { scheduleSync() }
                     sync()
                     refresh()
                 },
                 annotationView: { map, annotation in
                     if annotation is ReportsAnnotation {
                         return map.dequeueReusableAnnotationView(withIdentifier: ReportsAnnotationView.reuse, for: annotation)
                     }
                     if let c = annotation as? MKClusterAnnotation, c.memberAnnotations.first is ReportsAnnotation {
                         return map.dequeueReusableAnnotationView(withIdentifier: ReportsClusterView.reuse, for: annotation)
                     }
                     return nil
                 },
                 didSelect: { map, annotation in
                     if let a = annotation as? ReportsAnnotation {
                         Haptic.play("light")
                         ReportsPanels.openOwn(ReportsPanels.detail, reportId: a.id)
                         return true
                     }
                     if let c = annotation as? MKClusterAnnotation, c.memberAnnotations.first is ReportsAnnotation {
                         MapHub.fit(c.memberAnnotations.map(\.coordinate))
                         return true
                     }
                     return false
                 },
                 regionDidChange: { _ in refresh() })
    }

    private static func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        Task { @MainActor in
            syncScheduled = false
            sync()
        }
    }

    /// Ajoute / retire / remplace les annotations pour coller à l'état du module.
    static func sync() {
        guard let map else { return }
        let items = ReportsStore.shared.items.filter { $0.value.alive }
        var remove: [ReportsAnnotation] = []
        var add: [ReportsAnnotation] = []
        for (id, a) in shown {
            guard let r = items[id] else { remove.append(a); shown[id] = nil; continue }
            if r.type != a.kind || r.sub != a.sub {
                // type ou précision changés : on remplace (la vue se redessine)
                remove.append(a)
                let n = ReportsAnnotation(r); shown[id] = n; add.append(n)
            }
        }
        for (id, r) in items where shown[id] == nil {
            let n = ReportsAnnotation(r); shown[id] = n; add.append(n)
        }
        if !remove.isEmpty { map.removeAnnotations(remove) }
        if !add.isEmpty { map.addAnnotations(add) }
    }

    /// Zone visible → chargement + tuiles temps réel. Limitation (pas d'anti-rebond) : en conduite
    /// la caméra bouge en continu, un anti-rebond ne partirait jamais.
    static func refresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            refreshScheduled = false
            guard let map, map.bounds.width > 0 else { return }
            let region = MKCoordinateRegion(map.visibleMapRect)
            // trop dézoomé (≈ zoom 7) : on ne charge rien
            guard region.span.longitudeDelta < 4.5, region.span.latitudeDelta < 4.5 else { return }
            let w = region.center.longitude - region.span.longitudeDelta / 2
            let e = region.center.longitude + region.span.longitudeDelta / 2
            let s = region.center.latitude - region.span.latitudeDelta / 2
            let n = region.center.latitude + region.span.latitudeDelta / 2
            let px = (e - w) * 0.25, py = (n - s) * 0.25
            await ReportsStore.shared.watchArea(w: w - px, s: s - py, e: e + px, n: n + py, around: Core.shared.position?.coordinate)
        }
    }
}
