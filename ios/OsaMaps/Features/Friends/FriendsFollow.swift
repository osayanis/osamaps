import SwiftUI
import MapKit
import Observation

/// Vue native « suivre un trajet » ouverte par osamaps://suivre/JETON : la voiture de l'ami avance en direct,
/// le tracé restant, l'heure d'arrivée, puis « Léa est arrivée ». Aucune identité demandée (le jeton suffit).
/// Panneau du bas : "friends-follow".
@MainActor
@Observable
final class FriendsFollow {
    static let shared = FriendsFollow()

    enum State { case loading, live, arrived, ended, error }

    var token: String?
    var state: State = .loading
    var trip: FriendsTripView?
    var message: String?
    /// La caméra cadre le trajet tant que l'utilisateur ne bouge pas la carte.
    var autoCam = true

    @ObservationIgnored private var tokens: [BusToken] = []
    @ObservationIgnored private var subscribed = false

    private init() {}

    func open(_ t: String) {
        if let old = token, old != t { Socket.shared.emit("friends:trip:unwatch", ["token": old]) }
        token = t
        state = .loading
        trip = nil
        message = nil
        autoCam = true
        FriendsFollowLayer.clear()
        subscribe()
        Core.shared.openPanel("friends-follow", data: t)
        watch()
    }

    func close() {
        if let t = token { Socket.shared.emit("friends:trip:unwatch", ["token": t]) }
        token = nil
        trip = nil
        FriendsFollowLayer.clear()
        if Core.shared.panel == "friends-follow" { Core.shared.openPanel(nil) }
    }

    func recenter() {
        autoCam = true
        FriendsFollowLayer.draw(fit: true)
    }

    private func subscribe() {
        guard !subscribed else { return }
        subscribed = true
        let s = Socket.shared
        tokens.append(s.onConnect { [weak self] in self?.watch() })
        tokens.append(s.on("friends:trip:update") { [weak self] a in self?.merge(a.first) })
        tokens.append(s.on("friends:trip:arrived") { [weak self] a in
            guard let self, self.matches(a.first) else { return }
            self.merge(a.first)
            self.state = .arrived
            emit(.toast(Toast(text: "\(self.trip?.name ?? "Ton ami") est bien arrivé", icon: "checkmark.circle.fill", tone: .good)))
            emit(.haptic("success"))
        })
        tokens.append(s.on("friends:trip:ended") { [weak self] a in
            guard let self, let j = a.first as? [String: Any], j["token"] as? String == self.token else { return }
            let why = j["why"] as? String
            self.state = .ended
            self.message = why == "expired" ? "Le lien a expiré." : "Le partage du trajet est terminé."
        })
    }

    private func matches(_ json: Any?) -> Bool {
        token != nil && (json as? [String: Any])?["token"] as? String == token
    }

    private func watch() {
        guard let t = token else { return }
        Socket.shared.emit("friends:trip:watch", ["token": t]) { [weak self] args in
            Task { @MainActor in
                guard let self, self.token == t else { return }
                let r = args.first as? [String: Any]
                guard r?["ok"] as? Bool == true, let tj = r?["trip"] else {
                    self.state = .error
                    self.message = r?["error"] as? String ?? "Ce lien de suivi a expiré."
                    return
                }
                self.trip = FriendsTripView.merge(nil, tj)
                self.state = self.trip?.arrivedAt != nil ? .arrived : .live
                FriendsFollowLayer.draw(fit: true)
            }
        }
    }

    private func merge(_ json: Any?) {
        guard matches(json) else { return }
        trip = FriendsTripView.merge(trip, json)
        FriendsFollowLayer.draw(fit: autoCam)
    }

    /// Le reste du tracé, depuis la voiture.
    var remainingLine: [CLLocationCoordinate2D] {
        guard let t = trip, t.arrivedAt == nil else { return [] }
        guard let p = t.pos, t.coords.count >= 2, let snap = Geo.snap(p, to: t.coords) else { return t.coords }
        return [p] + t.coords.dropFirst(snap.index + 1)
    }
}

// MARK: - Carte

final class FriendsFollowLine: MKPolyline { var casing = false }
final class FriendsFollowCar: MKPointAnnotation { var heading: Double = 0; var arrived = false }
final class FriendsFollowDest: MKPointAnnotation {}

@MainActor
enum FriendsFollowLayer {
    private static weak var map: MKMapView?
    private static var lines: [FriendsFollowLine] = []
    private static var car: FriendsFollowCar?
    private static var dest: FriendsFollowDest?
    /// Moment du dernier cadrage automatique (pour reconnaître un geste de l'utilisateur).
    private static var fittingUntil = Date.distantPast

    static var layer: MapLayer {
        MapLayer(
            id: "friends-follow",
            zIndex: 150,
            attach: { m in map = m },
            renderer: { o in
                guard let l = o as? FriendsFollowLine else { return nil }
                let r = MKPolylineRenderer(polyline: l)
                r.strokeColor = l.casing ? UIColor.black.withAlphaComponent(0.5) : .white
                r.lineWidth = l.casing ? 10 : 6
                r.lineCap = .round
                r.lineJoin = .round
                return r
            },
            annotationView: { m, a in
                if let c = a as? FriendsFollowCar {
                    let v = m.dequeueReusableAnnotationView(withIdentifier: "friends.follow.car") ?? MKAnnotationView(annotation: c, reuseIdentifier: "friends.follow.car")
                    v.annotation = c
                    v.image = carImage(arrived: c.arrived)
                    v.transform = rotation(c, m)
                    v.displayPriority = .required
                    return v
                }
                if let d = a as? FriendsFollowDest {
                    let v = (m.dequeueReusableAnnotationView(withIdentifier: "friends.follow.dest") as? MKMarkerAnnotationView)
                        ?? MKMarkerAnnotationView(annotation: d, reuseIdentifier: "friends.follow.dest")
                    v.annotation = d
                    v.markerTintColor = .white
                    v.glyphImage = UIImage(systemName: "flag.checkered")
                    v.glyphTintColor = .black
                    v.displayPriority = .required
                    v.titleVisibility = .hidden
                    return v
                }
                return nil
            },
            regionDidChange: { m in
                if let c = car { m.view(for: c)?.transform = rotation(c, m) }
                // la carte a bougé sans nous : l'utilisateur regarde ailleurs, on arrête de recadrer
                if FriendsFollow.shared.token != nil, Date() > fittingUntil, !Core.shared.follow { FriendsFollow.shared.autoCam = false }
            }
        )
    }

    static func clear() {
        guard let map else { return }
        map.removeOverlays(lines)
        lines = []
        if let car { map.removeAnnotation(car) }
        if let dest { map.removeAnnotation(dest) }
        car = nil; dest = nil
    }

    static func draw(fit: Bool) {
        guard let map, let t = FriendsFollow.shared.trip else { return }
        let line = FriendsFollow.shared.remainingLine
        map.removeOverlays(lines)
        lines = []
        if line.count > 1 {
            let casing = FriendsFollowLine(coordinates: line, count: line.count); casing.casing = true
            let main = FriendsFollowLine(coordinates: line, count: line.count)
            lines = [casing, main]
            map.addOverlays(lines, level: .aboveRoads)
        }
        if dest == nil {
            let d = FriendsFollowDest(); d.coordinate = t.dest; d.title = t.destName
            dest = d
            map.addAnnotation(d)
        }
        if t.arrivedAt != nil, let d = dest { map.removeAnnotation(d); dest = nil }
        if let p = t.pos ?? (t.arrivedAt != nil ? t.dest : nil) {
            if let c = car {
                let from = c.coordinate
                c.heading = t.heading ?? (Geo.distance(from, p) > 2 ? Geo.bearing(from, p) : c.heading)
                let arrivedChanged = c.arrived != (t.arrivedAt != nil)
                c.arrived = t.arrivedAt != nil
                let reduce = UIAccessibility.isReduceMotionEnabled
                UIView.animate(withDuration: reduce ? 0 : 1.9, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
                    c.coordinate = p
                    map.view(for: c)?.transform = rotation(c, map)
                }
                if arrivedChanged { map.view(for: c)?.image = carImage(arrived: c.arrived) }
            } else {
                let c = FriendsFollowCar()
                c.coordinate = p
                c.heading = t.heading ?? 0
                c.arrived = t.arrivedAt != nil
                car = c
                map.addAnnotation(c)
            }
        }
        if fit {
            var pts = line + [t.dest]
            if let p = t.pos { pts.append(p) }
            // un seul point (ou tous confondus, à l'arrivée) : on cadre un quartier, pas un immeuble
            let lats = pts.map(\.latitude), lngs = pts.map(\.longitude)
            if (lats.max()! - lats.min()!) < 0.004 && (lngs.max()! - lngs.min()!) < 0.004 {
                let c = pts[0]
                pts = [.init(latitude: c.latitude - 0.006, longitude: c.longitude - 0.006), .init(latitude: c.latitude + 0.006, longitude: c.longitude + 0.006)]
            }
            fittingUntil = Date().addingTimeInterval(2.5)
            MapHub.fit(pts, animated: true, extraTop: 20)
        }
    }

    /// La flèche suit le cap ; la coche d'arrivée reste droite.
    private static func rotation(_ c: FriendsFollowCar, _ m: MKMapView) -> CGAffineTransform {
        c.arrived ? .identity : CGAffineTransform(rotationAngle: CGFloat((c.heading - m.camera.heading) * .pi / 180))
    }

    /// Flèche blanche cerclée (vert quand il est arrivé).
    private static func carImage(arrived: Bool) -> UIImage {
        let size = CGSize(width: 40, height: 40)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            c.setShadow(offset: CGSize(width: 0, height: 3), blur: 8, color: UIColor.black.withAlphaComponent(0.5).cgColor)
            UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 1).setFill()
            c.fillEllipse(in: CGRect(x: 4, y: 4, width: 32, height: 32))
            c.setShadow(offset: .zero, blur: 0)
            let fill = arrived ? UIColor(red: 0.204, green: 0.78, blue: 0.349, alpha: 1) : UIColor.white
            fill.setFill()
            if arrived {
                if let check = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .heavy))?
                    .withTintColor(fill, renderingMode: .alwaysOriginal) {
                    let sz = check.size
                    check.draw(in: CGRect(x: 20 - sz.width / 2, y: 20 - sz.height / 2, width: sz.width, height: sz.height))
                }
            } else {
                let p = UIBezierPath()
                p.move(to: CGPoint(x: 20, y: 9))
                p.addLine(to: CGPoint(x: 28, y: 30))
                p.addLine(to: CGPoint(x: 20, y: 25.5))
                p.addLine(to: CGPoint(x: 12, y: 30))
                p.close()
                p.fill()
            }
        }
    }
}

// MARK: - Panneau

struct FriendsFollowSheet: View {
    @State private var follow = FriendsFollow.shared

    var body: some View {
        let trip = follow.trip
        let name = trip?.name ?? "Ton ami"
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                FriendsLiveDot(on: follow.state == .live && !stale)
                Text(follow.state == .loading ? "Chargement du trajet…" : trip != nil ? "Trajet de \(name)" : "Suivi de trajet")
                    .font(.osa(15, .bold)).foregroundStyle(Osa.text)
                if follow.state == .live {
                    Text("en direct").font(.osa(12, .bold)).foregroundStyle(Osa.ok)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Osa.ok.opacity(0.14), in: Capsule())
                }
                Spacer()
                if !follow.autoCam && trip != nil {
                    Button { follow.recenter() } label: { Image(systemName: "scope") }
                        .buttonStyle(OsaRoundStyle(size: 40))
                        .accessibilityLabel("Recentrer sur le trajet")
                }
                FriendsCloseButton { follow.close() }
            }

            switch follow.state {
            case .loading:
                Text("Connexion…").font(.osa(14, .medium)).foregroundStyle(Osa.dim)
            case .error:
                Text("Lien indisponible").font(.osa(20, .bold)).foregroundStyle(Osa.text)
                Text(follow.message ?? "").font(.osa(14, .medium)).foregroundStyle(Osa.dim)
            case .live, .arrived, .ended:
                if let trip {
                    if follow.state == .arrived || trip.arrivedAt != nil {
                        HStack(spacing: 14) {
                            Image(systemName: "checkmark").font(.system(size: 20, weight: .bold)).foregroundStyle(.black)
                                .frame(width: 44, height: 44).background(Osa.ok, in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(name) est arrivé").font(.osa(20, .bold)).foregroundStyle(Osa.text)
                                Text("À \(trip.destName)\(trip.arrivedAt.map { " · \(FriendsUtil.clock($0))" } ?? "")")
                                    .font(.osa(14, .medium)).foregroundStyle(Osa.dim)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("\(name) est en route vers", systemImage: "car.fill")
                                .font(.osa(13, .semibold)).foregroundStyle(Osa.dim)
                            Text(trip.destName).font(.osa(22, .bold)).foregroundStyle(Osa.text).lineLimit(2)
                        }
                        HStack(spacing: 10) {
                            stat("Arrivée", trip.eta.map(FriendsUtil.clock) ?? "—")
                            stat("Reste", trip.remaining.map(Geo.formatDistance) ?? "—")
                        }
                        if stale {
                            Text("Dernière position il y a \(Int((Date().timeIntervalSince1970 * 1000 - trip.updated) / 60_000)) min")
                                .font(.osa(13, .medium)).foregroundStyle(Osa.dim)
                        }
                    }
                    if follow.state == .ended, let m = follow.message {
                        Text(m).font(.osa(14, .medium)).foregroundStyle(Osa.dim)
                    }
                    Text("Lecture seule · expire 30 min après l'arrivée").font(.osa(12, .medium)).foregroundStyle(Osa.faint)
                }
            }
        }
        .padding(18)
        .osaGlass()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }

    private var stale: Bool {
        guard let t = follow.trip, t.arrivedAt == nil else { return false }
        return Date().timeIntervalSince1970 * 1000 - t.updated > 90_000
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.osa(12, .semibold)).foregroundStyle(Osa.faint)
            Text(value).font(.osa(22, .bold)).foregroundStyle(Osa.text).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .osaCard(Osa.radiusS + 4)
    }
}
