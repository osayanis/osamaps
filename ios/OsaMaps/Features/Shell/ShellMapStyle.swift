import UIKit
import MapKit
import Observation

/// Applique `Prefs.mapStyle` au MKMapView :
///   auto  → clair entre le lever et le coucher du soleil (calculés pour la position), sombre sinon
///   dark / light → forcé
/// On change `overrideUserInterfaceStyle` et l'emphase de la configuration existante (muted la nuit,
/// default le jour) sans recréer la configuration : les réglages des autres modules (trafic, POI) restent.
/// Émet `.custom(name: "shell:mapTheme", payload: ["theme": "light" | "dark"])` à chaque changement.
@MainActor
final class ShellMapStyle {
    static let shared = ShellMapStyle()
    private weak var map: MKMapView?
    private var applied: String?
    private var timer: Timer?

    /// Le thème courant de la carte ("light" | "dark").
    private(set) var theme = "dark"

    func attach(_ map: MKMapView) {
        self.map = map
        apply(animated: false)
        observe()
        timer?.invalidate()
        // en auto, on réévalue chaque minute (lever/coucher du soleil en pleine conduite)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in ShellMapStyle.shared.apply(animated: true) }
        }
    }

    private func observe() {
        withObservationTracking { _ = Prefs.shared.mapStyle } onChange: {
            Task { @MainActor in
                ShellMapStyle.shared.apply(animated: true)
                ShellMapStyle.shared.observe()
            }
        }
    }

    /// Le thème voulu maintenant, selon le réglage, l'heure et la position.
    static func wanted(_ style: String, at date: Date = .now) -> String {
        if style == "light" || style == "dark" { return style }
        let c = Core.shared.position?.coordinate ?? Location.defaultCenter
        return ShellSun.isDaytime(date, lat: c.latitude, lng: c.longitude) ? "light" : "dark"
    }

    func apply(animated: Bool) {
        guard let map else { return }
        let t = Self.wanted(Prefs.shared.mapStyle)
        guard t != applied else { return }
        applied = t
        theme = t
        let change = {
            map.overrideUserInterfaceStyle = t == "light" ? .light : .dark
            if let cfg = map.preferredConfiguration as? MKStandardMapConfiguration {
                cfg.emphasisStyle = t == "light" ? .default : .muted
                map.preferredConfiguration = cfg
            }
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: map, duration: 0.3, options: [.transitionCrossDissolve, .allowUserInteraction], animations: change)
        } else {
            change()
        }
        Bus.shared.emit(.custom(name: "shell:mapTheme", payload: ["theme": t]))
    }
}

/// Lever / coucher du soleil calculés localement (algorithme NOAA simplifié, précision ~1 min),
/// même calcul que `web/src/features/shell/sun.ts`. Aucun appel réseau.
enum ShellSun {
    private static let rad = Double.pi / 180

    /// Heures de lever et de coucher pour le jour de `date`, ou nil (nuit / jour polaire).
    static func times(_ date: Date, lat: Double, lng: Double) -> (sunrise: Date, sunset: Date)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day = cal.startOfDay(for: date).timeIntervalSince1970
        let jd = day / 86400 + 2440587.5
        let n = (jd - 2451545.0 + 0.0008 - lng / 360).rounded()
        let jStar = n - lng / 360                                  // midi solaire moyen
        let M = (357.5291 + 0.98560028 * jStar).truncatingRemainder(dividingBy: 360)
        let C = 1.9148 * sin(M * rad) + 0.02 * sin(2 * M * rad) + 0.0003 * sin(3 * M * rad)
        let lambda = (M + C + 180 + 102.9372).truncatingRemainder(dividingBy: 360)
        let jTransit = 2451545.0 + jStar + 0.0053 * sin(M * rad) - 0.0069 * sin(2 * lambda * rad)
        let decl = asin(sin(lambda * rad) * sin(23.4397 * rad))
        // -0.833° : réfraction + rayon du disque solaire
        let cosH = (sin(-0.833 * rad) - sin(lat * rad) * sin(decl)) / (cos(lat * rad) * cos(decl))
        guard cosH >= -1, cosH <= 1 else { return nil }
        let H = acos(cosH) / rad
        func toDate(_ j: Double) -> Date { Date(timeIntervalSince1970: (j - 2440587.5) * 86400) }
        return (toDate(jTransit - H / 360), toDate(jTransit + H / 360))
    }

    /// Fait-il jour à `now` à cette position ? (nuit polaire → false, jour polaire → true)
    static func isDaytime(_ now: Date, lat: Double, lng: Double) -> Bool {
        guard let t = times(now, lat: lat, lng: lng) else {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let m = cal.component(.month, from: now) - 1
            let summerNorth = m >= 3 && m <= 8
            return lat >= 0 ? summerNorth : !summerNorth
        }
        return now >= t.sunrise && now < t.sunset
    }
}
