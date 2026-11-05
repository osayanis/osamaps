import Foundation

/// Données fixes de la mascotte : niveaux, badges, barème de points (l'apparence : MascotLook.swift)
/// (identiques à `web/src/features/mascot/data.ts`).
enum MascotData {
    struct Level { var min: Int; var name: String }

    static let levels: [Level] = [
        .init(min: 0, name: "Apprenti du volant"),
        .init(min: 100, name: "Rouleur du dimanche"),
        .init(min: 300, name: "Copilote fiable"),
        .init(min: 700, name: "As du rond-point"),
        .init(min: 1500, name: "Routier sympa"),
        .init(min: 3000, name: "Éclaireur des routes"),
        .init(min: 6000, name: "Légende de la nationale"),
        .init(min: 12000, name: "Maître des cartes"),
    ]

    struct LevelInfo { var level: Int; var name: String; var min: Int; var next: Int?; var progress: Double }

    static func level(of points: Int) -> LevelInfo {
        var i = 0
        while i + 1 < levels.count && points >= levels[i + 1].min { i += 1 }
        let cur = levels[i]
        let next = i + 1 < levels.count ? levels[i + 1] : nil
        let progress = next.map { Double(points - cur.min) / Double($0.min - cur.min) } ?? 1
        return .init(level: i + 1, name: cur.name, min: cur.min, next: next?.min, progress: max(0, min(1, progress)))
    }

    struct Badge: Identifiable { var id: String; var name: String; var hint: String; var symbol: String }

    /// 12 badges (SF Symbols à la place des icônes SVG du web).
    static let badges: [Badge] = [
        .init(id: "premier-trajet", name: "Premier trajet", hint: "Arriver au bout d'un premier trajet", symbol: "flag.fill"),
        .init(id: "10-trajets", name: "Habitué", hint: "Terminer 10 trajets", symbol: "steeringwheel"),
        .init(id: "100-km", name: "100 km", hint: "Rouler 100 km au total", symbol: "gauge.with.dots.needle.67percent"),
        .init(id: "1000-km", name: "Grand voyageur", hint: "Rouler 1 000 km au total", symbol: "globe.europe.africa.fill"),
        .init(id: "marathon", name: "Long courrier", hint: "Un trajet de plus de 100 km", symbol: "road.lanes"),
        .init(id: "nuit", name: "Conducteur de nuit", hint: "Rouler entre 22 h et 5 h", symbol: "moon.fill"),
        .init(id: "matinal", name: "Lève-tôt", hint: "Partir entre 5 h et 7 h", symbol: "sunrise.fill"),
        .init(id: "signaleur", name: "Vigie", hint: "Faire 10 signalements", symbol: "megaphone.fill"),
        .init(id: "confirme", name: "Œil de lynx", hint: "10 signalements confirmés", symbol: "checkmark.seal.fill"),
        .init(id: "entraide", name: "Entraide", hint: "Voter sur 10 signalements", symbol: "hand.thumbsup.fill"),
        .init(id: "explorateur", name: "Explorateur", hint: "Aller vers 10 destinations différentes", symbol: "safari.fill"),
        .init(id: "fidele", name: "Fidèle", hint: "Rouler 7 jours différents", symbol: "calendar"),
    ]

    static func badge(_ id: String) -> Badge? { badges.first { $0.id == id } }

    /// Barème.
    static let perKm = 1
    static let arrived = 20
    static let badgePoints = 50
    /// Plafond d'un seul `.pointsEarn` venu d'un autre module.
    static let maxEvent = 200

    /// « 12 500 »
    static func nf(_ n: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func kmh(_ v: Double) -> String { "\(Int(v.rounded())) km/h" }
}

/// Anciens accessoires (avant l'éditeur d'apparence) : gardés pour relire les anciennes sauvegardes.
enum MascotAccessory: String, Codable, CaseIterable, Sendable {
    case casquette, bonnet, couronne, lunettes, echarpe, noeud
}

/// Un trajet terminé (historique : les 20 derniers ; données du panneau "trip-summary").
struct MascotTrip: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var start: Date
    var end: Date
    /// mètres
    var distance: Double
    /// secondes (départ → arrivée)
    var duration: Double
    /// secondes en mouvement
    var moving: Double
    var avgKmh: Double
    var maxKmh: Double
    var stops: Int
    var points: Int
    var arrived: Bool
    var destination: String?
    var badges: [String]
    var levelUp: LevelUp?

    struct LevelUp: Codable, Equatable, Sendable { var level: Int; var name: String }
}
