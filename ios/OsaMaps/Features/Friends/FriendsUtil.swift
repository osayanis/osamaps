import Foundation
import CoreLocation
import UIKit

/// Petits utilitaires du module Amis (port de `util.tsx`).
enum FriendsUtil {
    /// « YB » pour « Yanis B. », « ? » sans pseudo.
    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: \.isWhitespace)
        guard let first = parts.first?.first else { return "?" }
        if parts.count == 1 { return String(first).uppercased() }
        return (String(first) + String(parts[1].first ?? Character(""))).uppercased()
    }

    /// « 18 h 42 » depuis un horodatage en ms.
    static func clock(_ ms: Double) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: ms / 1000))
        return String(format: "%d h %02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// « 482 913 ».
    static func prettyCode(_ c: String) -> String {
        guard c.count == 6 else { return c }
        return "\(c.prefix(3)) \(c.suffix(3))"
    }

    /// Ligne de statut : « En route vers Vichy · arrivée 18 h 42 », « En ligne », …
    static func statusLine(_ f: FriendsFriend) -> String {
        if let d = f.loc?.drive {
            let to = d.to.map { "En route vers \($0)" } ?? "En route"
            return d.eta.map { "\(to) · arrivée \(clock($0))" } ?? to
        }
        if f.loc != nil { return f.online ? "En ligne · position partagée" : "Position partagée" }
        return f.online ? "En ligne" : "Hors ligne"
    }

    /// Point milieu sur le grand cercle.
    static func midpoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let r = Double.pi / 180
        let l1 = a.longitude * r, p1 = a.latitude * r, l2 = b.longitude * r, p2 = b.latitude * r
        let bx = cos(p2) * cos(l2 - l1), by = cos(p2) * sin(l2 - l1)
        let p = atan2(sin(p1) + sin(p2), sqrt((cos(p1) + bx) * (cos(p1) + bx) + by * by))
        let l = l1 + atan2(by, cos(p1) + bx)
        return .init(latitude: p / r, longitude: l / r)
    }

    /// Nom d'un point par géocodage inverse IGN (« Saint-Pourçain-sur-Sioule »).
    static func reverseName(_ c: CLLocationCoordinate2D) async -> String? {
        var u = URLComponents(url: External.geocodeFr.appendingPathComponent("reverse"), resolvingAgainstBaseURL: false)!
        u.queryItems = [.init(name: "lat", value: String(c.latitude)), .init(name: "lon", value: String(c.longitude)),
                        .init(name: "limit", value: "1")]
        guard let url = u.url, let (data, resp) = try? await API.session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = ((j["features"] as? [[String: Any]])?.first)?["properties"] as? [String: Any]
        else { return nil }
        return props["city"] as? String ?? props["label"] as? String
    }

    /// Lien web public du site (même serveur que l'API) : https://osalabs.fr/maps/?ami=CODE.
    static func webLink(_ key: String, _ value: String) -> URL {
        var c = URLComponents(url: API.siteRoot.appendingPathComponent("maps/"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: key, value: value)]
        return c.url!
    }

    /// Feuille de partage iOS, ouverte par programme (quand ShareLink n'est pas possible : après un appel réseau).
    @MainActor
    static func presentShare(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.keyWindow?.rootViewController ?? scene.windows.first?.rootViewController else { return }
        while let p = top.presentedViewController { top = p }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 1, height: 1)
        top.present(vc, animated: true)
    }
}
