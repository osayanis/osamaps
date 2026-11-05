import MapKit
import UIKit
import SwiftUI

/// Une station sur la carte (annotation propre au module).
final class AlongAnnotation: NSObject, MKAnnotation {
    enum Style { case white, green, dim }
    let key: String
    let ref: AlongStationRef
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var label: String
    var style: Style
    /// Petit = plus important (la moins chère d'abord).
    var rank: Double

    init(key: String, ref: AlongStationRef, coordinate: CLLocationCoordinate2D, label: String, style: Style, rank: Double) {
        self.key = key; self.ref = ref; self.coordinate = coordinate; self.label = label; self.style = style; self.rank = rank
    }

    var title: String? { nil }
}

/// Pilule de prix (blanche ; verte pour la moins chère ; sombre si le prix est ancien) posée sur un petit point.
final class AlongPillView: MKAnnotationView {
    static let reuse = "along.pill"
    private let pill = UIView()
    private let label = UILabel()
    private let dot = UIView()
    private let pillH: CGFloat = 24, gap: CGFloat = 3, dotD: CGFloat = 8

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        pill.layer.cornerRadius = pillH / 2
        pill.layer.cornerCurve = .continuous
        pill.layer.shadowColor = UIColor.black.cgColor
        pill.layer.shadowOpacity = 0.35
        pill.layer.shadowRadius = 4
        pill.layer.shadowOffset = CGSize(width: 0, height: 2)
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold)
        label.textAlignment = .center
        dot.layer.cornerRadius = dotD / 2
        dot.layer.borderWidth = 1.5
        dot.layer.borderColor = UIColor.black.withAlphaComponent(0.75).cgColor
        addSubview(dot)
        addSubview(pill)
        pill.addSubview(label)
        collisionMode = .rectangle
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        guard let a = annotation as? AlongAnnotation else { return }
        label.text = a.label
        let fill: UIColor, text: UIColor
        switch a.style {
        case .green: fill = UIColor(Osa.ok); text = .black
        case .white: fill = UIColor.white.withAlphaComponent(0.96); text = .black
        case .dim: fill = UIColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 0.92); text = UIColor.white.withAlphaComponent(0.85)
        }
        pill.backgroundColor = fill
        pill.layer.borderWidth = a.style == .dim ? 1 : 0
        pill.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        label.textColor = text
        dot.backgroundColor = a.style == .dim ? UIColor(white: 0.63, alpha: 1) : fill.withAlphaComponent(1)

        let w = ceil(label.intrinsicContentSize.width) + 16
        let h = pillH + gap + dotD
        frame = CGRect(x: 0, y: 0, width: w, height: h)
        pill.frame = CGRect(x: 0, y: 0, width: w, height: pillH)
        label.frame = pill.bounds
        dot.frame = CGRect(x: (w - dotD) / 2, y: pillH + gap, width: dotD, height: dotD)
        // le centre du point tombe sur la coordonnée
        centerOffset = CGPoint(x: 0, y: -(h / 2 - dotD / 2))
        // MapKit masque les étiquettes qui se chevauchent : les moins chères gagnent
        // le tri à l'écran est fait par AlongLayer.declutter (MapKit ne masque pas ces vues de façon fiable) ;
        // en cas de chevauchement résiduel, la moins chère passe dessus
        displayPriority = .required
        zPriority = MKAnnotationViewZPriority(rawValue: Float(max(1, min(999, 999 - a.rank))))
        accessibilityLabel = a.label
        isAccessibilityElement = true
    }
}

/// Calque « Sur le trajet » : étiquettes de prix (ou de puissance) ; en exploration autour de la carte,
/// en aperçu / conduite le long du trajet.
@MainActor
enum AlongLayer {
    private static var shown: [String: AlongAnnotation] = [:]
    private static var zoomOK = true
    private static weak var map: MKMapView?
    private static var lastRefresh = Date.distantPast
    private static let pillFont = UIFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold)

    /// Garde, de la plus importante (la moins chère) à la moins importante, les étiquettes qui ne
    /// recouvrent pas une étiquette déjà gardée ; celles hors de l'écran attendent le prochain mouvement.
    private static func declutter(_ all: [String: AlongAnnotation], in map: MKMapView) -> [String: AlongAnnotation] {
        let area = map.bounds.insetBy(dx: -120, dy: -120)
        var kept: [CGRect] = []
        var out: [String: AlongAnnotation] = [:]
        for a in all.values.sorted(by: { ($0.rank, $0.key) < ($1.rank, $1.key) }) {
            let p = map.convert(a.coordinate, toPointTo: map)
            guard p.x.isFinite, p.y.isFinite, area.contains(p) else { continue }
            let w = ceil((a.label as NSString).size(withAttributes: [.font: pillFont]).width) + 16
            // pilule (24) + écart (3) au-dessus du point (8) centré sur la coordonnée
            let r = CGRect(x: p.x - w / 2, y: p.y - 31, width: w, height: 35).insetBy(dx: -3, dy: -2)
            if kept.contains(where: { $0.intersects(r) }) { continue }
            kept.append(r)
            out[a.key] = a
            if out.count >= 150 { break }
        }
        return out
    }

    /// En exploration, on n'affiche les prix qu'à partir d'un zoom de quartier (~ zoom 11).
    static func zoomedIn(_ r: MKCoordinateRegion) -> Bool { r.span.longitudeDelta <= 0.3 }

    static var layer: MapLayer {
        MapLayer(id: "along", zIndex: 30, attach: { map in
            Self.map = map
            let core = Core.shared, model = AlongModel.shared, prefs = AlongPrefs.shared
            alongObserve({
                _ = core.mode; _ = model.nearbyFuel; _ = model.nearbyEv; _ = model.route
                _ = prefs.energy; _ = prefs.showStations
            }) { refresh() }
            zoomOK = zoomedIn(map.region)
            refresh()
            model.loadNearby(map)
        }, renderer: { overlay in
            #if DEBUG
            if let o = overlay as? AlongDebugRoute {
                let r = MKPolylineRenderer(polyline: o)
                r.strokeColor = UIColor(Osa.police).withAlphaComponent(0.85)
                r.lineWidth = 6
                r.lineCap = .round
                return r
            }
            #endif
            return nil
        }, annotationView: { map, annotation in
            guard annotation is AlongAnnotation else { return nil }
            let v = map.dequeueReusableAnnotationView(withIdentifier: AlongPillView.reuse) as? AlongPillView
                ?? AlongPillView(annotation: annotation, reuseIdentifier: AlongPillView.reuse)
            v.annotation = annotation
            return v
        }, didSelect: { _, annotation in
            guard let a = annotation as? AlongAnnotation else { return false }
            Haptic.play("light")
            Core.shared.openPanel("along.station", data: a.ref)
            return true
        }, regionDidChange: { map in
            zoomOK = zoomedIn(map.region)
            // en conduite la caméra bouge sans cesse : au plus 2 recalculs par seconde
            if Core.shared.mode != .drive || Date.now.timeIntervalSince(lastRefresh) > 0.5 { refresh() }
            if Core.shared.mode == .browse { AlongModel.shared.loadNearby(map) }
        })
    }

    /// Recalcule les annotations voulues et ne touche qu'à celles qui changent (pas de clignotement).
    static func refresh() {
        guard let map else { return }
        lastRefresh = .now
        let want = declutter(desired(), in: map)
        var remove: [AlongAnnotation] = []
        for (k, a) in shown {
            if let w = want[k], w.label == a.label, w.style == a.style, w.ref == a.ref { continue }
            remove.append(a)
            shown[k] = nil
        }
        if !remove.isEmpty { map.removeAnnotations(remove) }
        let add = want.filter { shown[$0.key] == nil }.map(\.value)
        for a in add { shown[a.key] = a }
        if !add.isEmpty { map.addAnnotations(add) }
    }

    private static func desired() -> [String: AlongAnnotation] {
        let core = Core.shared, model = AlongModel.shared, prefs = AlongPrefs.shared
        guard prefs.showStations else { return [:] }
        let energy = prefs.energy
        var out: [String: AlongAnnotation] = [:]
        if core.mode == .browse {
            guard zoomOK else { return [:] }
            if energy.isEV { model.nearbyEv.forEach { add(ev: $0, into: &out) } } else { addFuel(model.nearbyFuel, energy, into: &out) }
        } else {
            guard let r = model.route, r.status == .ready, r.energy == energy, r.routeId == core.route?.id else { return [:] }
            if energy.isEV { r.ev.forEach { add(ev: $0, into: &out) } } else { addFuel(r.fuel, energy, into: &out) }
        }
        return out
    }

    private static func addFuel(_ list: [AlongFuelStation], _ e: AlongEnergy, into out: inout [String: AlongAnnotation]) {
        let cheap = AlongFormat.cheapestIds(list, e)
        let now = Date.now
        for s in list {
            guard let pr = s.price(e) else { continue }
            let short = s.isShort(e)
            let ok = AlongFormat.isFresh(pr.maj, now: now) && !short
            let style: AlongAnnotation.Style = cheap.contains(s.id) ? .green : ok ? .white : .dim
            // rang : la moins chère, puis les prix frais (moins cher d'abord), puis les anciens
            let rank = style == .green ? 0 : ok ? 100 + pr.p * 100 : 700 + pr.p * 10
            let key = "fuel:\(s.id)"
            out[key] = AlongAnnotation(key: key, ref: .fuel(s), coordinate: s.coordinate,
                                       label: short ? "Rupture" : AlongFormat.price3(pr.p), style: style, rank: rank)
        }
    }

    private static func add(ev s: AlongEvStation, into out: inout [String: AlongAnnotation]) {
        let key = "ev:\(s.id)"
        out[key] = AlongAnnotation(key: key, ref: .ev(s), coordinate: s.coordinate,
                                   label: s.kw > 0 ? "\(Int(s.kw)) kW" : "Borne",
                                   style: s.kw >= 50 ? .white : .dim, rank: 400 - min(350, s.kw))
    }
}
