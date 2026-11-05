import MapKit
import UIKit
import Observation

/// Pastille numérotée d'un résultat de catégorie.
final class SearchResultAnnotation: MKPointAnnotation {
    var result: SearchResult
    var index: Int
    var selected: Bool
    init(_ r: SearchResult, index: Int, selected: Bool) {
        result = r; self.index = index; self.selected = selected
        super.init()
        coordinate = r.coordinate
        title = r.name
    }
}

/// Épingle du lieu dont la fiche est ouverte.
final class SearchPinAnnotation: MKPointAnnotation {
    var symbol: String
    init(_ c: CLLocationCoordinate2D, symbol: String, name: String) {
        self.symbol = symbol
        super.init()
        coordinate = c
        title = name
    }
}

/// Lieu enregistré (maison, travail, voiture, favori) : discret, toujours visible en exploration.
final class SearchSavedAnnotation: MKPointAnnotation {
    var saved: SearchSaved
    var symbol: String
    init(_ s: SearchSaved, symbol: String, label: String) {
        saved = s; self.symbol = symbol
        super.init()
        coordinate = s.coordinate
        title = label
    }
}

/// Calque de carte du module : marqueurs, appui long, sélection, zone visible.
@MainActor
enum SearchMapLayer {
    private static var signature = ""
    private static weak var map: MKMapView?

    static var layer: MapLayer {
        MapLayer(id: "search", zIndex: 60,
                 attach: { map in
                     Self.map = map
                     observe()
                 },
                 annotationView: { map, a in view(map, a) },
                 didSelect: { _, a in select(a) },
                 regionDidChange: { map in
                     let s = SearchState.shared
                     guard s.category != nil else { return }
                     s.mapCenter = map.centerCoordinate
                     let r = map.region
                     s.mapSpan = r.span.longitudeDelta * 111_000 * cos(r.center.latitude * .pi / 180)
                 },
                 longPress: { c in longPress(c) })
    }

    // MARK: synchronisation (Observation, sans Combine)

    private static func observe() {
        withObservationTracking {
            sync()
        } onChange: {
            Task { @MainActor in observe() }
        }
    }

    private static func sync() {
        let core = Core.shared
        let s = SearchState.shared
        let browse = core.mode == .browse
        let panel = core.panel
        _ = core.panelVersion
        let selected = panel == "place" ? SearchPlaceData.from(core.panelData) : nil
        let results = browse ? (s.category?.results ?? []) : []
        var saved: [(SearchSaved, String, String)] = []
        if browse {
            if let h = s.home { saved.append((h, "house.fill", "Maison")) }
            if let w = s.work { saved.append((w, "briefcase.fill", "Travail")) }
            if let c = s.car { saved.append((c, "car.fill", "Ma voiture")) }
            for f in s.favorites { saved.append((f, "star.fill", f.name)) }
        }

        func same(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
            abs(a.latitude - b.latitude) < 1e-6 && abs(a.longitude - b.longitude) < 1e-6
        }
        let selInList = selected.map { sel in results.contains { same($0.coordinate, sel.coordinate) } } ?? false
        let sig = [
            results.map { "\($0.id)" }.joined(separator: ","),
            selected.map { "\($0.saved.lat),\($0.saved.lng),\($0.saved.kind ?? "")" } ?? "-",
            saved.map { "\($0.0.id)@\($0.0.lat),\($0.0.lng)" }.joined(separator: ","),
            browse ? "b" : "x",
        ].joined(separator: "|")
        guard let map, sig != signature else { return }
        signature = sig

        map.removeAnnotations(map.annotations.filter { $0 is SearchResultAnnotation || $0 is SearchPinAnnotation || $0 is SearchSavedAnnotation })
        var add: [MKAnnotation] = []
        for (p, symbol, label) in saved {
            // un lieu enregistré sous l'épingle ouverte : l'épingle suffit
            if let sel = selected, Geo.distance(sel.coordinate, p.coordinate) < 5 { continue }
            add.append(SearchSavedAnnotation(p, symbol: symbol, label: label))
        }
        for (i, r) in results.enumerated() {
            add.append(SearchResultAnnotation(r, index: i + 1, selected: selected.map { same($0.coordinate, r.coordinate) } ?? false))
        }
        if browse, let sel = selected, !selInList {
            let symbol = sel.saved.kind == "car" ? "car.fill" : SearchFormat.symbol(sel.saved.kind)
            add.append(SearchPinAnnotation(sel.coordinate, symbol: symbol, name: sel.saved.name))
        }
        map.addAnnotations(add)
    }

    // MARK: rendus

    private static func view(_ map: MKMapView, _ a: MKAnnotation) -> MKAnnotationView? {
        switch a {
        case let r as SearchResultAnnotation:
            let v = map.dequeueReusableAnnotationView(withIdentifier: "search.result") ?? MKAnnotationView(annotation: r, reuseIdentifier: "search.result")
            v.annotation = r
            v.image = SearchMarkers.number(r.index, selected: r.selected)
            v.centerOffset = .zero
            v.displayPriority = .required
            v.zPriority = r.selected ? .max : .defaultSelected
            v.collisionMode = .circle
            v.canShowCallout = false
            v.accessibilityLabel = "\(r.index). \(r.result.name)"
            return v
        case let p as SearchPinAnnotation:
            let v = map.dequeueReusableAnnotationView(withIdentifier: "search.pin") ?? MKAnnotationView(annotation: p, reuseIdentifier: "search.pin")
            v.annotation = p
            let img = SearchMarkers.pin(p.symbol)
            v.image = img
            v.centerOffset = CGPoint(x: 0, y: -img.size.height / 2 + 2)
            v.displayPriority = .required
            v.zPriority = .max
            v.canShowCallout = false
            v.accessibilityLabel = p.title ?? "Lieu"
            appear(v)
            return v
        case let s as SearchSavedAnnotation:
            let v = map.dequeueReusableAnnotationView(withIdentifier: "search.saved") ?? MKAnnotationView(annotation: s, reuseIdentifier: "search.saved")
            v.annotation = s
            v.image = SearchMarkers.saved(s.symbol, small: s.symbol == "star.fill")
            v.centerOffset = .zero
            v.displayPriority = .defaultHigh
            v.zPriority = .defaultUnselected
            v.collisionMode = .circle
            v.canShowCallout = false
            v.accessibilityLabel = s.title ?? "Lieu enregistré"
            return v
        default:
            return nil
        }
    }

    /// Petite entrée de l'épingle (≤ 250 ms, rien si « Réduire les animations »).
    private static func appear(_ v: MKAnnotationView) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        v.transform = CGAffineTransform(scaleX: 0.6, y: 0.6).translatedBy(x: 0, y: 12)
        v.alpha = 0
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            v.transform = .identity
            v.alpha = 1
        }
    }

    // MARK: interactions

    private static func select(_ a: MKAnnotation) -> Bool {
        let s = SearchState.shared
        switch a {
        case let r as SearchResultAnnotation:
            Haptic.play("light")
            s.openPlace(SearchPlaceData(saved: r.result.saved, from: .list, needsAddress: r.result.detail.isEmpty))
            return true
        case let p as SearchSavedAnnotation:
            Haptic.play("light")
            s.openPlace(SearchPlaceData(saved: p.saved, from: .home, needsAddress: p.saved.detail == nil))
            return true
        case is SearchPinAnnotation:
            return true
        default:
            return false
        }
    }

    /// Appui long : en mode « choisir », termine le choix ; sinon ouvre la fiche du point.
    private static func longPress(_ c: CLLocationCoordinate2D) -> Bool {
        let core = Core.shared
        let s = SearchState.shared
        guard core.mode == .browse else { return false }
        Haptic.play("medium")
        if s.picking != nil {
            Task { @MainActor in
                let a = await SearchGeocoder.reverse(c)
                s.completePick(SearchSaved(id: SearchFormat.pointId(c.latitude, c.longitude), name: a?.name ?? "Point choisi",
                                           detail: a.flatMap { $0.detail.isEmpty ? nil : $0.detail }, coordinate: c, kind: "address"))
            }
            return true
        }
        s.focused = false
        s.openPlace(SearchPlaceData(saved: SearchSaved(id: SearchFormat.pointId(c.latitude, c.longitude), name: "Point sur la carte",
                                                       coordinate: c, kind: "map"),
                                    from: .map, needsAddress: true))
        return true
    }
}

/// Images des marqueurs (dessinées une fois, mises en cache).
@MainActor
enum SearchMarkers {
    private static var cache: [String: UIImage] = [:]

    private static func cached(_ key: String, _ make: () -> UIImage) -> UIImage {
        if let i = cache[key] { return i }
        let i = make()
        cache[key] = i
        return i
    }

    private static func symbolImage(_ name: String, size: CGFloat, color: UIColor) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))?
            .withTintColor(color, renderingMode: .alwaysOriginal)
    }

    /// Pastille blanche numérotée (plus grande si sélectionnée).
    static func number(_ n: Int, selected: Bool) -> UIImage {
        cached("n\(n)\(selected)") {
            let d: CGFloat = selected ? 36 : 28
            let pad: CGFloat = 6
            let size = CGSize(width: d + pad * 2, height: d + pad * 2)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let g = ctx.cgContext
                let rect = CGRect(x: pad, y: pad, width: d, height: d)
                g.setShadow(offset: CGSize(width: 0, height: 2), blur: 5, color: UIColor.black.withAlphaComponent(0.45).cgColor)
                g.setFillColor(selected ? UIColor.white.cgColor : UIColor(white: 0.97, alpha: 1).cgColor)
                g.fillEllipse(in: rect)
                g.setShadow(offset: .zero, blur: 0)
                if selected {
                    g.setStrokeColor(UIColor.black.withAlphaComponent(0.85).cgColor)
                    g.setLineWidth(2.5)
                    g.strokeEllipse(in: rect.insetBy(dx: 3.5, dy: 3.5))
                }
                let text = "\(n)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: selected ? 15 : 13, weight: .bold),
                    .foregroundColor: UIColor.black,
                ]
                let ts = text.size(withAttributes: attrs)
                text.draw(at: CGPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2), withAttributes: attrs)
            }
        }
    }

    /// Épingle blanche (goutte) avec le symbole du lieu en noir.
    static func pin(_ symbol: String) -> UIImage {
        cached("p\(symbol)") {
            let w: CGFloat = 40, head: CGFloat = 40, tail: CGFloat = 10, pad: CGFloat = 8
            let size = CGSize(width: w + pad * 2, height: head + tail + pad * 2)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let g = ctx.cgContext
                let circle = CGRect(x: pad, y: pad, width: w, height: head)
                let path = UIBezierPath(ovalIn: circle)
                let tip = CGPoint(x: circle.midX, y: circle.maxY + tail)
                let tri = UIBezierPath()
                tri.move(to: CGPoint(x: circle.midX - 9, y: circle.maxY - 5))
                tri.addLine(to: tip)
                tri.addLine(to: CGPoint(x: circle.midX + 9, y: circle.maxY - 5))
                tri.close()
                path.append(tri)
                g.setShadow(offset: CGSize(width: 0, height: 3), blur: 7, color: UIColor.black.withAlphaComponent(0.5).cgColor)
                UIColor.white.setFill()
                path.fill()
                g.setShadow(offset: .zero, blur: 0)
                // un point sans type : un simple rond noir (une épingle dans l'épingle serait redondante)
                let glyph = symbol == "mappin" ? "circle.fill" : symbol
                if let img = symbolImage(glyph, size: symbol == "mappin" ? 11 : 17, color: .black) {
                    img.draw(at: CGPoint(x: circle.midX - img.size.width / 2, y: circle.midY - img.size.height / 2))
                }
            }
        }
    }

    /// Rond sombre discret avec le symbole en blanc.
    static func saved(_ symbol: String, small: Bool) -> UIImage {
        cached("s\(symbol)\(small)") {
            let d: CGFloat = small ? 24 : 30, pad: CGFloat = 5
            let size = CGSize(width: d + pad * 2, height: d + pad * 2)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let g = ctx.cgContext
                let rect = CGRect(x: pad, y: pad, width: d, height: d)
                g.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.5).cgColor)
                g.setFillColor(UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 0.92).cgColor)
                g.fillEllipse(in: rect)
                g.setShadow(offset: .zero, blur: 0)
                g.setStrokeColor(UIColor.white.withAlphaComponent(0.55).cgColor)
                g.setLineWidth(1.5)
                g.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
                if let img = symbolImage(symbol, size: small ? 10 : 13, color: .white) {
                    img.draw(at: CGPoint(x: rect.midX - img.size.width / 2, y: rect.midY - img.size.height / 2))
                }
            }
        }
    }
}
