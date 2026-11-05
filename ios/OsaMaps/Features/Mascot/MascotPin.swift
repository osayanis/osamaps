import SwiftUI
import MapKit
import Observation

/// « Ma position » sur la carte : la mascotte (debout, ou dans sa petite voiture quand on roule),
/// posée sur un halo de précision discret et un faisceau au sol orienté selon le cap.
/// Une seule annotation : sa vue héberge la mascotte SwiftUI (UIHostingController) et dessine le sol
/// (calques Core Animation, aplatis selon l'inclinaison de la caméra). Entre deux positions, tout est
/// interpolé à chaque image (CADisplayLink) : pas de saut.
final class MascotAnnotation: MKPointAnnotation {}

/// Ce que la vue SwiftUI du marqueur lit en plus du moteur : où regarde le visage.
@MainActor
@Observable
final class MascotPinModel {
    var look: CGSize = .zero
}

@MainActor
final class MascotPin: NSObject {
    static let shared = MascotPin()

    let annotation = MascotAnnotation()
    let model = MascotPinModel()
    private weak var map: MKMapView?
    private var view: MascotAnnotationView?
    private var added = false
    private var token: BusToken?
    private var link: CADisplayLink?

    /// Position affichée (interpolée).
    private var shown: CLLocationCoordinate2D?
    private var heading: Double?
    private var anim: (from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, h0: Double?, h1: Double?, t0: CFTimeInterval, dur: Double)?
    private var lastTick: Position?
    private var lastWall: CFTimeInterval = 0
    /// Dernier état de caméra vu (pour ne rien recalculer quand rien ne bouge).
    private var lastCam: (heading: Double, pitch: Double, dist: Double, lat: Double, lng: Double)?

    var layer: MapLayer {
        MapLayer(id: "mascot", zIndex: 1000,
                 attach: { [weak self] map in self?.attach(map) },
                 annotationView: { [weak self] _, a in
                     guard a is MascotAnnotation, let self else { return nil }
                     return self.makeView()
                 },
                 didSelect: { _, a in
                     guard a is MascotAnnotation else { return false }
                     if Core.shared.mode != .drive { MascotEngine.shared.poke(); Haptic.play("light") }
                     return true
                 },
                 regionDidChange: { [weak self] _ in self?.refreshGround(force: true) })
    }

    private func attach(_ map: MKMapView) {
        self.map = map
        token = Bus.shared.on { [weak self] e in
            if case .geoTick(let p) = e { self?.tick(p) }
        }
        if let p = Core.shared.position { tick(p) }
        let l = CADisplayLink(target: self, selector: #selector(frame(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 20)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func makeView() -> MascotAnnotationView {
        if let view { return view }
        let v = MascotAnnotationView(annotation: annotation, model: model)
        view = v
        refreshGround(force: true)
        return v
    }

    // MARK: - Nouvelle position

    private func tick(_ p: Position) {
        guard let map else { return }
        let now = CACurrentMediaTime()
        defer { lastTick = p; lastWall = now }
        guard let s = shown else {
            shown = p.coordinate
            heading = p.heading
            annotation.coordinate = p.coordinate
            if !added { map.addAnnotation(annotation); added = true }
            refreshGround(force: true)
            return
        }
        let far = abs(p.coordinate.latitude - s.latitude) > 0.05 || abs(p.coordinate.longitude - s.longitude) > 0.05
        if far || !MascotEngine.shared.animated {
            // grand saut (premier vrai fix GPS, lien de test) ou animations coupées : pas d'interpolation
            anim = nil
            shown = p.coordinate
            heading = p.heading ?? heading
            annotation.coordinate = p.coordinate
            refreshGround(force: true)
            return
        }
        // même durée que la caméra de MapView quand elle suit : la mascotte reste collée au centre
        let c = Core.shared
        let dur: Double
        if c.follow {
            let dt = lastTick.map { p.time.timeIntervalSince($0.time) } ?? 0.6
            dur = c.mode == .drive ? min(1, max(0.15, dt)) : 0.5
        } else {
            dur = max(0.2, min(1.2, lastWall > 0 ? now - lastWall : 1))
        }
        anim = (s, p.coordinate, heading, p.heading ?? heading, now, dur)
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }

    // MARK: - Chaque image

    @objc private func frame(_ l: CADisplayLink) {
        if let a = anim {
            let t = min(1, (CACurrentMediaTime() - a.t0) / a.dur)
            let c = CLLocationCoordinate2D(latitude: a.from.latitude + (a.to.latitude - a.from.latitude) * t,
                                           longitude: a.from.longitude + (a.to.longitude - a.from.longitude) * t)
            shown = c
            if let h1 = a.h1, let h0 = a.h0 {
                let d = (h1 - h0 + 540).truncatingRemainder(dividingBy: 360) - 180     // le plus court chemin
                heading = (h0 + d * min(1, t * 1.6) + 360).truncatingRemainder(dividingBy: 360)
            } else {
                heading = a.h1 ?? a.h0
            }
            annotation.coordinate = c
            if t >= 1 {
                anim = nil
                l.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 20)
            }
            refreshGround(force: true)
        } else {
            refreshGround(force: false)
        }
    }

    /// Faisceau (cap relatif à la carte, aplati selon l'inclinaison), halo (précision en points) et regard.
    private func refreshGround(force: Bool) {
        guard let map, let view, let s = shown else { return }
        let cam = map.camera
        let now = (cam.heading, Double(cam.pitch), cam.centerCoordinateDistance, cam.centerCoordinate.latitude, cam.centerCoordinate.longitude)
        if !force, let o = lastCam, o == now { return }
        lastCam = now

        let pitch = Double(cam.pitch) * .pi / 180
        var rel: Double?
        if let h = heading { rel = (h - cam.heading) * .pi / 180 }

        // mètres par point à l'endroit de la mascotte (horizontalement : non déformé par l'inclinaison)
        var radius: CGFloat = 0
        if let acc = Core.shared.position?.accuracy, acc > 0 {
            let pt = map.convert(s, toPointTo: map)
            let c2 = map.convert(CGPoint(x: pt.x + 40, y: pt.y), toCoordinateFrom: map)
            let mpp = Geo.distance(s, c2) / 40
            if mpp > 0 { radius = min(220, CGFloat(acc / mpp)) }
        }
        view.updateGround(rotation: rel, squash: max(0.2, cos(pitch)), haloRadius: radius > 22 ? radius : 0)

        let look: CGSize
        if let rel {
            look = CGSize(width: (sin(rel) * 10).rounded() / 10, height: (-cos(rel) * 0.7 * 10).rounded() / 10)
        } else {
            look = .zero
        }
        if look != model.look { model.look = look }
    }
}

/// La vue de l'annotation : zone tactile = la mascotte ; le sol déborde sans intercepter les touches.
final class MascotAnnotationView: MKAnnotationView {
    static let box: CGFloat = 56
    private let host: UIHostingController<MascotPinView>
    private let ground = CALayer()
    private let halo = CAShapeLayer()
    private let cone = CAGradientLayer()

    @MainActor
    init(annotation: MKAnnotation, model: MascotPinModel) {
        host = UIHostingController(rootView: MascotPinView(model: model))
        super.init(annotation: annotation, reuseIdentifier: "mascot")
        let b = Self.box
        frame = CGRect(x: 0, y: 0, width: b, height: b)
        centerOffset = CGPoint(x: 0, y: -b / 2)          // le bas de la vue = la position
        canShowCallout = false
        displayPriority = .required
        zPriority = .max
        selectedZPriority = .max
        collisionMode = .none
        clipsToBounds = false
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "Ma position"
        accessibilityTraits = .button

        ground.frame = CGRect(x: b / 2 - 100, y: b - 100, width: 200, height: 200)
        halo.fillColor = UIColor.white.withAlphaComponent(0.07).cgColor
        halo.strokeColor = UIColor.white.withAlphaComponent(0.18).cgColor
        halo.lineWidth = 1.5
        halo.frame = ground.bounds
        ground.addSublayer(halo)

        // faisceau : un secteur de ±32° qui s'estompe
        cone.type = .radial
        cone.frame = CGRect(x: 100 - 74, y: 100 - 74, width: 148, height: 148)
        cone.colors = [UIColor.white.withAlphaComponent(0.34).cgColor, UIColor.white.withAlphaComponent(0).cgColor]
        cone.locations = [0.25, 1]
        cone.startPoint = CGPoint(x: 0.5, y: 0.5)
        cone.endPoint = CGPoint(x: 1, y: 1)
        let sector = UIBezierPath()
        sector.move(to: CGPoint(x: 74, y: 74))
        sector.addArc(withCenter: CGPoint(x: 74, y: 74), radius: 74,
                      startAngle: (-90 - 32) * .pi / 180, endAngle: (-90 + 32) * .pi / 180, clockwise: true)
        sector.close()
        let mask = CAShapeLayer()
        mask.path = sector.cgPath
        cone.mask = mask
        cone.opacity = 0
        ground.addSublayer(cone)
        layer.addSublayer(ground)

        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.safeAreaRegions = []
        host.view.frame = CGRect(x: b / 2 - 60, y: b - 120, width: 120, height: 120)
        addSubview(host.view)
    }

    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func updateGround(rotation: Double?, squash: Double, haloRadius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ground.setAffineTransform(CGAffineTransform(rotationAngle: rotation ?? 0)
            .concatenating(CGAffineTransform(scaleX: 1, y: squash)))
        cone.opacity = rotation == nil ? 0 : 1
        if haloRadius > 0 {
            halo.path = UIBezierPath(ovalIn: CGRect(x: 100 - haloRadius, y: 100 - haloRadius, width: haloRadius * 2, height: haloRadius * 2)).cgPath
            halo.opacity = 1
        } else {
            halo.opacity = 0
        }
        CATransaction.commit()
    }
}

/// Le contenu SwiftUI du marqueur : le sol de la mascotte tombe exactement en bas du cadre (120 × 120).
struct MascotPinView: View {
    let model: MascotPinModel

    var body: some View {
        let m = MascotEngine.shared
        let live = m.live
        let driving = Core.shared.mode == .drive
        let size: CGFloat = driving ? 48 : 40
        // distance entre le bas du cadre de la mascotte et son ombre (cotes de MascotFigure)
        let ground = size * 0.92 * (0.675 - 0.56)
        ZStack(alignment: .topTrailing) {
            MascotFigure(mood: live.sleeping ? .sleepy : live.mood,
                         arms: live.arms,
                         look: live.sleeping ? CGSize(width: 0, height: 0.3) : model.look,
                         size: size,
                         hop: live.hop,
                         kart: driving || live.moving,
                         accessories: m.worn,
                         bounce: live.moving && !live.sleeping,
                         animated: m.settings.animations)
            if live.sleeping {
                MascotZzz(animated: m.animated).offset(x: 14, y: -16)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
        .offset(y: ground)
        .frame(width: 120, height: 120, alignment: .bottom)
        .animation(.easeOut(duration: 0.25), value: driving)
    }
}

/// « z z z » qui montent quand la mascotte dort (immobiles si les animations sont coupées).
struct MascotZzz: View {
    var animated: Bool

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1 / 15)) { tl in
                letters(t: tl.date.timeIntervalSinceReferenceDate)
            }
        } else {
            letters(t: nil)
        }
    }

    private func letters(t: Double?) -> some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(0..<3, id: \.self) { i in
                letter(i, phase: t.map { Self.phase($0, i) })
            }
        }
        .frame(width: 30, height: 34, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }

    private static func phase(_ t: Double, _ i: Int) -> Double {
        (t / 2.7 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
    }

    private func letter(_ i: Int, phase: Double?) -> some View {
        let p = CGFloat(phase ?? 0)
        let k = CGFloat(i)
        let opacity: Double
        if let phase { opacity = phase < 0.2 ? phase / 0.2 * 0.95 : 0.95 * (1 - (phase - 0.2) / 0.8) } else { opacity = 0.9 }
        let x: CGFloat = k * 8 + p * 6
        let y: CGFloat = 4 - k * 10 - p * 12
        return Text("z")
            .font(.system(size: 11 + k * 2, weight: .heavy))
            .foregroundStyle(.white)
            .shadow(color: Osa.bg, radius: 0.8)
            .shadow(color: Osa.bg, radius: 0.8)
            .offset(x: x, y: y)
            .opacity(opacity)
    }
}
