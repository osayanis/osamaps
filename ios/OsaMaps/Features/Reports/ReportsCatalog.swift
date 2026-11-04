import SwiftUI
import UIKit
import CoreLocation

/// Catalogue des signalements : types, sous-types, libellés, couleur d'état, pictogrammes.
/// Aligné avec `server/features/reports.js` (TYPES) et `web/src/features/reports/catalog.ts`.
/// Loi française : pas de « radar » — un contrôle s'appelle « Police ».
enum ReportsKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case police, accident, jam, hazard, works, closure, weather
    var id: String { rawValue }

    struct Sub: Identifiable, Hashable, Sendable {
        var id: String
        var label: String
        var title: String
    }

    var label: String {
        switch self {
        case .police: "Police"
        case .accident: "Accident"
        case .jam: "Bouchon"
        case .hazard: "Danger"
        case .works: "Travaux"
        case .closure: "Route fermée"
        case .weather: "Météo"
        }
    }

    /// Titre court pour l'alerte et la fiche quand aucun sous-type n'est précisé.
    var title: String {
        switch self {
        case .police: "Police signalée"
        case .accident: "Accident signalé"
        case .jam: "Bouchon signalé"
        case .hazard: "Danger signalé"
        case .works: "Travaux"
        case .closure: "Route fermée"
        case .weather: "Météo difficile"
        }
    }

    var subs: [Sub] {
        switch self {
        case .jam: [
            Sub(id: "moderate", label: "Modéré", title: "Ralentissement"),
            Sub(id: "heavy", label: "Dense", title: "Bouchon dense"),
            Sub(id: "standstill", label: "À l'arrêt", title: "Bouchon à l'arrêt"),
        ]
        case .hazard: [
            Sub(id: "object", label: "Objet", title: "Objet sur la route"),
            Sub(id: "vehicle", label: "Véhicule arrêté", title: "Véhicule arrêté"),
            Sub(id: "pothole", label: "Nid-de-poule", title: "Nid-de-poule"),
            Sub(id: "animal", label: "Animal", title: "Animal sur la route"),
            Sub(id: "pedestrian", label: "Piéton", title: "Piéton sur la route"),
        ]
        case .weather: [
            Sub(id: "ice", label: "Verglas", title: "Verglas signalé"),
            Sub(id: "fog", label: "Brouillard", title: "Brouillard"),
            Sub(id: "flood", label: "Inondation", title: "Route inondée"),
            Sub(id: "snow", label: "Neige", title: "Neige sur la route"),
        ]
        default: []
        }
    }

    /// Ton de l'alerte de conduite (le web dit « info » pour la police ; ici le ton dédié existe).
    var tone: DriveAlert.Tone {
        switch self {
        case .police: .police
        case .accident, .closure: .danger
        default: .warn
        }
    }

    /// Ordre d'empilement quand deux pastilles se chevauchent (le plus grave dessus).
    var rank: Int {
        switch self {
        case .closure: 7
        case .accident: 6
        case .police: 5
        case .hazard: 4
        case .weather: 3
        case .jam: 2
        case .works: 1
        }
    }

    func title(sub: String?) -> String { subs.first { $0.id == sub }?.title ?? title }

    /// Couleur d'état (un bouchon modéré est orange, les autres rouges).
    func color(sub: String?) -> Color {
        switch self {
        case .police: Osa.police
        case .accident, .closure: Osa.jam
        case .jam: sub == "moderate" ? Osa.slow : Osa.jam
        case .hazard, .weather: Osa.danger
        case .works: Osa.slow
        }
    }

    /// Les pastilles jaunes / orange portent un pictogramme noir (contraste), les autres blanc.
    func ink(sub: String?) -> Color {
        switch self {
        case .hazard, .weather, .works: .black
        case .jam: sub == "moderate" ? .black : .white
        default: .white
        }
    }

    /// Symbole SF : celui du sous-type s'il en a un, sinon celui du type.
    func symbol(sub: String?) -> String {
        switch sub {
        case "object": return "shippingbox.fill"
        case "vehicle": return "car.side.fill"
        case "pothole": return "circle.dashed.inset.filled"
        case "animal": return "pawprint.fill"
        case "pedestrian": return "figure.walk"
        case "ice": return "snowflake"
        case "fog": return "cloud.fog.fill"
        case "flood": return "water.waves"
        case "snow": return "cloud.snow.fill"
        default: break
        }
        switch self {
        case .police: return "checkmark.shield.fill"
        case .accident: return "car.side.rear.and.collision.and.car.side.front"
        case .jam: return "car.2.fill"
        case .hazard: return "exclamationmark.triangle.fill"
        case .works: return "cone.fill"
        case .closure: return "minus.circle.fill"
        case .weather: return "cloud.fill"
        }
    }
}

/// Un signalement tel que le serveur le publie (`pub()` dans reports.js). Dates en ms.
struct Report: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var type: ReportsKind
    var sub: String?
    var lng: Double
    var lat: Double
    var heading: Double?
    var createdAt: Double
    var updatedAt: Double
    var expiresAt: Double
    /// Pseudo de l'auteur ("" = anonyme).
    var by: String?
    var confirmations: Int
    var denials: Int

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    var title: String { type.title(sub: sub) }
    var alive: Bool { expiresAt > Reports.nowMs }
}

enum Reports {
    static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    /// « à l'instant », « il y a 12 min », « il y a 2 h », « il y a 3 j ».
    static func ago(_ t: Double, now: Double = nowMs) -> String {
        let min = Int(((now - t) / 60_000).rounded(.down))
        if min < 1 { return "à l'instant" }
        if min < 60 { return "il y a \(min) min" }
        let h = min / 60
        if h < 24 { return "il y a \(h) h" }
        return "il y a \(h / 24) j"
    }

    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }
}

/// Pastille ronde de couleur d'état avec le pictogramme du signalement.
struct ReportsDisc: View {
    var kind: ReportsKind
    var sub: String? = nil
    var size: CGFloat = 44

    var body: some View {
        Circle()
            .fill(kind.color(sub: sub))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: kind.symbol(sub: sub))
                    .font(.system(size: size * 0.44, weight: .bold))
                    .foregroundStyle(kind.ink(sub: sub))
            }
            .accessibilityHidden(true)
    }
}

/// Image de pastille pour la carte (UIKit), mise en cache par type/sous-type.
@MainActor
enum ReportsImages {
    static let size: CGFloat = 34
    private static var cache: [String: UIImage] = [:]

    static func disc(_ kind: ReportsKind, sub: String?) -> UIImage {
        let key = kind.rawValue + "-" + (sub ?? "")
        if let img = cache[key] { return img }
        let s = size
        let img = UIGraphicsImageRenderer(size: CGSize(width: s, height: s)).image { ctx in
            let g = ctx.cgContext
            g.setFillColor(UIColor(red: 10 / 255, green: 10 / 255, blue: 15 / 255, alpha: 0.92).cgColor)
            g.fillEllipse(in: CGRect(x: 0.5, y: 0.5, width: s - 1, height: s - 1))
            g.setFillColor(UIColor(kind.color(sub: sub)).cgColor)
            g.fillEllipse(in: CGRect(x: 2.5, y: 2.5, width: s - 5, height: s - 5))
            let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
            if let sym = UIImage(systemName: kind.symbol(sub: sub), withConfiguration: cfg)?
                .withTintColor(UIColor(kind.ink(sub: sub)), renderingMode: .alwaysOriginal) {
                // le symbole tient dans un carré de 18 pt, centré
                let box: CGFloat = 18
                let scale = min(box / sym.size.width, box / sym.size.height, 1)
                let w = sym.size.width * scale, h = sym.size.height * scale
                sym.draw(in: CGRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
            }
        }
        cache[key] = img
        return img
    }
}
