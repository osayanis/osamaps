import MapKit
import UIKit
import SwiftUI

/// Marqueurs des amis qui partagent leur position : pastille à initiales, flèche de cap,
/// étiquette « Léa · 18 h 42 » quand il conduit. Toucher un marqueur ouvre la fiche de l'ami.
@MainActor
enum FriendsMapLayer {
    private static weak var map: MKMapView?
    private static var annotations: [String: FriendsAnnotation] = [:]

    static var layer: MapLayer {
        MapLayer(
            id: "friends",
            zIndex: 160,
            attach: { m in map = m; sync() },
            annotationView: { m, a in
                guard let a = a as? FriendsAnnotation else { return nil }
                let v = (m.dequeueReusableAnnotationView(withIdentifier: FriendsAnnotationView.reuse) as? FriendsAnnotationView)
                    ?? FriendsAnnotationView(annotation: a, reuseIdentifier: FriendsAnnotationView.reuse)
                v.annotation = a
                v.configure(a.friend, mapHeading: m.camera.heading)
                return v
            },
            didSelect: { _, a in
                guard let a = a as? FriendsAnnotation else { return false }
                Haptic.play("light")
                Core.shared.openPanel("friend", data: a.friend.pid)
                return true
            },
            regionDidChange: { m in
                // la carte a tourné : on réoriente les flèches de cap
                for a in annotations.values { (m.view(for: a) as? FriendsAnnotationView)?.configure(a.friend, mapHeading: m.camera.heading) }
            }
        )
    }

    /// Aligne les marqueurs sur `FriendsStore.friends` (appelé à chaque changement).
    static func sync() {
        guard let map else { return }
        let list = FriendsStore.shared.friends.filter { $0.loc != nil }
        let seen = Set(list.map(\.pid))
        for (pid, a) in annotations where !seen.contains(pid) {
            map.removeAnnotation(a)
            annotations[pid] = nil
        }
        for f in list {
            guard let loc = f.loc else { continue }
            if let a = annotations[f.pid] {
                a.friend = f
                if a.coordinate.latitude != loc.lat || a.coordinate.longitude != loc.lng {
                    let reduce = UIAccessibility.isReduceMotionEnabled
                    UIView.animate(withDuration: reduce ? 0 : 0.8, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                        a.coordinate = loc.coordinate
                    }
                }
                (map.view(for: a) as? FriendsAnnotationView)?.configure(f, mapHeading: map.camera.heading)
            } else {
                let a = FriendsAnnotation(friend: f)
                annotations[f.pid] = a
                map.addAnnotation(a)
            }
        }
    }
}

final class FriendsAnnotation: MKPointAnnotation {
    var friend: FriendsFriend
    init(friend: FriendsFriend) {
        self.friend = friend
        super.init()
        coordinate = friend.loc?.coordinate ?? .init()
        title = nil
    }
}

final class FriendsAnnotationView: MKAnnotationView {
    static let reuse = "friends.marker"

    private let cap = CAShapeLayer()
    private let capHolder = UIView()
    private let dot = UILabel()
    private let label = FriendsPaddedLabel()
    /// La mascotte personnalisée de l'ami par-dessus le rond (module mascot) ; vide tant qu'elle n'est pas connue.
    private let face = UIHostingController(rootView: FriendsMarkerFace(pid: ""))

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        clipsToBounds = false
        canShowCallout = false
        displayPriority = .required
        collisionMode = .circle

        capHolder.frame = bounds.insetBy(dx: -8, dy: -8)
        capHolder.isUserInteractionEnabled = false
        let s = capHolder.bounds.width
        let path = UIBezierPath()
        path.move(to: CGPoint(x: s / 2, y: 0.5))
        path.addLine(to: CGPoint(x: s / 2 + 6.5, y: 9))
        path.addLine(to: CGPoint(x: s / 2 - 6.5, y: 9))
        path.close()
        cap.path = path.cgPath
        capHolder.layer.addSublayer(cap)
        addSubview(capHolder)

        dot.frame = CGRect(x: 4, y: 4, width: 36, height: 36)
        dot.textAlignment = .center
        dot.font = .systemFont(ofSize: 13, weight: .heavy)
        dot.textColor = .black
        dot.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        dot.layer.cornerRadius = 18
        dot.layer.masksToBounds = true
        dot.layer.borderWidth = 2.5
        addSubview(dot)
        face.view.frame = dot.frame.insetBy(dx: 2.5, dy: 2.5)
        face.view.backgroundColor = .clear
        face.view.isUserInteractionEnabled = false
        face.safeAreaRegions = []
        addSubview(face.view)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 7
        layer.shadowOffset = CGSize(width: 0, height: 4)

        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.95)
        label.backgroundColor = UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 0.85)
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.layer.borderWidth = 1
        label.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ f: FriendsFriend, mapHeading: Double) {
        let loc = f.loc
        let driving = loc?.drive != nil
        let ok = UIColor(red: 0.204, green: 0.78, blue: 0.349, alpha: 1)
        dot.text = MascotFriendLooks.shared.look(f.pid) == nil ? FriendsUtil.initials(f.name) : nil
        if face.rootView.pid != f.pid { face.rootView = FriendsMarkerFace(pid: f.pid) }
        dot.layer.borderColor = (driving ? ok : UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 1)).cgColor
        cap.fillColor = (driving ? ok : .white).cgColor
        if let h = loc?.heading, (loc?.speed ?? 0) > 0.5 {
            capHolder.isHidden = false
            capHolder.transform = CGAffineTransform(rotationAngle: CGFloat((h - mapHeading) * .pi / 180))
        } else {
            capHolder.isHidden = true
        }
        let text = loc?.drive?.eta.map { "\(f.name) · \(FriendsUtil.clock($0))" } ?? f.name
        label.text = text
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: (bounds.width - size.width) / 2, y: 56, width: size.width, height: size.height)
        accessibilityLabel = "\(f.name), \(FriendsUtil.statusLine(f))"
    }
}

/// Contenu SwiftUI du marqueur : la tête de la mascotte de l'ami (rien tant qu'elle n'est pas connue).
struct FriendsMarkerFace: View {
    var pid: String
    var body: some View {
        if !pid.isEmpty {
            // fond opaque : cache les initiales du rond si la mascotte arrive après coup
            MascotFriendFace(pid: pid, size: 31) { Color.clear }
                .background(Circle().fill(MascotFriendLooks.shared.looks[pid] == nil ? .clear : Color(white: 0.93)))
        }
    }
}

/// UILabel avec marges intérieures (étiquette en pilule).
final class FriendsPaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
}
