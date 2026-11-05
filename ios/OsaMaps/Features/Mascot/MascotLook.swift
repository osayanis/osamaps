import SwiftUI
import Observation

/// L'apparence choisie de la mascotte (éditeur « Ma mascotte »). Même format JSON que la version web
/// (`web/src/features/mascot/look.ts`) et que le serveur (`/mascot/look`) : des identifiants courts en texte.
struct MascotLook: Codable, Equatable, Sendable {
    var body: Body = .creme
    var hat: Hat = .none
    var glasses: Glasses = .none
    var face: Face = .doux
    var neck: Neck = .none
    var ride: Ride = .nuit
    var name: String = MascotLook.defaultName

    static let defaultName = "Osa"
    static let maxName = 16
    static let standard = MascotLook()

    /// Le nom affiché (jamais vide).
    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? Self.defaultName : n
    }

    // MARK: Couleur du corps

    enum Body: String, Codable, CaseIterable, Sendable {
        case creme, nuage, peche, bonbon, citron, menthe, ciel, lavande

        var label: String {
            switch self {
            case .creme: "Crème"
            case .nuage: "Nuage"
            case .peche: "Pêche"
            case .bonbon: "Bonbon"
            case .citron: "Citron"
            case .menthe: "Menthe"
            case .ciel: "Ciel"
            case .lavande: "Lavande"
            }
        }

        /// Clair (éclairage), ombre (bords, bras), bas des pieds.
        var tones: (light: Color, shade: Color, low: Color) {
            switch self {
            case .creme: (.mascotHex(0xFEFDF7), .mascotHex(0xD6CEC2), .mascotHex(0xB3AB9E))
            case .nuage: (.mascotHex(0xF5F7FB), .mascotHex(0xC3CAD6), .mascotHex(0xA1A9B7))
            case .peche: (.mascotHex(0xFFEDE2), .mascotHex(0xF1B79C), .mascotHex(0xD3987D))
            case .bonbon: (.mascotHex(0xFFEAF0), .mascotHex(0xEFADC0), .mascotHex(0xD08FA2))
            case .citron: (.mascotHex(0xFFF8D6), .mascotHex(0xE9CF78), .mascotHex(0xC9B05C))
            case .menthe: (.mascotHex(0xE6F8EE), .mascotHex(0xA3DABC), .mascotHex(0x84BC9E))
            case .ciel: (.mascotHex(0xE6F2FF), .mascotHex(0xA2C6EC), .mascotHex(0x84A8CE))
            case .lavande: (.mascotHex(0xF0EBFF), .mascotHex(0xBEB0EC), .mascotHex(0xA092CE))
            }
        }
    }

    // MARK: Tête

    enum Hat: String, Codable, CaseIterable, Sendable {
        case none, casquette, bonnet, beret, chapeau, chantier, couronne

        var label: String {
            switch self {
            case .none: "Rien"
            case .casquette: "Casquette"
            case .bonnet: "Bonnet"
            case .beret: "Béret"
            case .chapeau: "Chapeau"
            case .chantier: "Casque"
            case .couronne: "Couronne"
            }
        }

        /// Niveau à atteindre (la couronne reste une récompense), nil = libre.
        var level: Int? { self == .couronne ? 4 : nil }
    }

    // MARK: Lunettes

    enum Glasses: String, Codable, CaseIterable, Sendable {
        case none, soleil, rondes, aviateur, carrees

        var label: String {
            switch self {
            case .none: "Aucune"
            case .soleil: "Soleil"
            case .rondes: "Rondes"
            case .aviateur: "Aviateur"
            case .carrees: "Carrées"
            }
        }
    }

    // MARK: Visage (expression au repos ; les émotions du moment passent par-dessus)

    enum Face: String, Codable, CaseIterable, Sendable {
        case doux, rieur, malin, timide, cool

        var label: String {
            switch self {
            case .doux: "Doux"
            case .rieur: "Rieur"
            case .malin: "Malin"
            case .timide: "Timide"
            case .cool: "Détendu"
            }
        }
    }

    // MARK: Cou

    enum Neck: String, Codable, CaseIterable, Sendable {
        case none, noeud, echarpe, bandana, cravate, medaille

        var label: String {
            switch self {
            case .none: "Rien"
            case .noeud: "Nœud pap'"
            case .echarpe: "Écharpe"
            case .bandana: "Bandana"
            case .cravate: "Cravate"
            case .medaille: "Médaille"
            }
        }
    }

    // MARK: Couleur du véhicule

    enum Ride: String, Codable, CaseIterable, Sendable {
        case nuit, glacier, rouge, orange, soleil, sapin, ocean, prune

        var label: String {
            switch self {
            case .nuit: "Nuit"
            case .glacier: "Glacier"
            case .rouge: "Rouge"
            case .orange: "Orange"
            case .soleil: "Soleil"
            case .sapin: "Sapin"
            case .ocean: "Océan"
            case .prune: "Prune"
            }
        }

        var color: Color {
            switch self {
            case .nuit: .mascotHex(0x1B1D24)
            case .glacier: .mascotHex(0xE9EBF0)
            case .rouge: .mascotHex(0xD63B42)
            case .orange: .mascotHex(0xEE7F2D)
            case .soleil: .mascotHex(0xF1C232)
            case .sapin: .mascotHex(0x2C9461)
            case .ocean: .mascotHex(0x2E68D2)
            case .prune: .mascotHex(0x7656D2)
            }
        }

        /// Teinte claire : détails sombres au lieu de blancs.
        var isLight: Bool { self == .glacier || self == .soleil }
    }

    // MARK: Lecture tolérante (une valeur inconnue venue d'une version plus récente ne casse rien)

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func read<T: RawRepresentable>(_ k: CodingKeys, _ def: T) -> T where T.RawValue == String {
            (try? c.decode(String.self, forKey: k)).flatMap(T.init(rawValue:)) ?? def
        }
        body = read(.body, .creme)
        hat = read(.hat, .none)
        glasses = read(.glasses, .none)
        face = read(.face, .doux)
        neck = read(.neck, .none)
        ride = read(.ride, .nuit)
        name = String(((try? c.decode(String.self, forKey: .name)) ?? Self.defaultName).prefix(Self.maxName))
    }
}

extension Color {
    static func mascotHex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255).opacity(a)
    }
}

/// L'apparence enregistrée (clé « osamaps.mascot.look »), lue partout où la mascotte apparaît.
@MainActor
@Observable
final class MascotLookStore {
    static let shared = MascotLookStore()

    private(set) var look: MascotLook

    private init() {
        if let saved: MascotLook = Store.load("mascot.look", default: nil) {
            look = saved
        } else {
            // première fois : on reprend les anciens accessoires portés (avant l'éditeur)
            var l = MascotLook()
            for a in Store.load("mascot.state", default: MascotEngine.Saved()).equipped {
                switch a {
                case .casquette: l.hat = .casquette
                case .bonnet: l.hat = .bonnet
                case .couronne: l.hat = .couronne
                case .lunettes: l.glasses = .soleil
                case .echarpe: l.neck = .echarpe
                case .noeud: l.neck = .noeud
                }
            }
            look = l
        }
    }

    /// Ce qu'on dessine : la couronne n'apparaît que si elle est encore débloquée.
    var shown: MascotLook {
        var l = look
        if !isUnlocked(l.hat) { l.hat = .none }
        return l
    }

    func isUnlocked(_ hat: MascotLook.Hat) -> Bool {
        guard let need = hat.level else { return true }
        return MascotEngine.shared.level.level >= need
    }

    func update(_ f: (inout MascotLook) -> Void) {
        var l = look
        f(&l)
        l.name = String(l.name.prefix(MascotLook.maxName))
        guard l != look else { return }
        look = l
        Store.save("mascot.look", l)
        MascotLookSync.schedule()
    }

    /// Tout au hasard (sauf le nom), en évitant de retomber sur la même tenue.
    func randomize() {
        let before = look
        var l = look
        repeat {
            l.body = MascotLook.Body.allCases.randomElement()!
            l.hat = MascotLook.Hat.allCases.filter(isUnlocked).randomElement()!
            l.glasses = Double.random(in: 0..<1) < 0.35 ? .none : MascotLook.Glasses.allCases.randomElement()!
            l.face = MascotLook.Face.allCases.randomElement()!
            l.neck = MascotLook.Neck.allCases.randomElement()!
            l.ride = MascotLook.Ride.allCases.randomElement()!
        } while l == before
        update { $0 = l }
    }

    func reset() { update { $0 = MascotLook(name: $0.name) } }
}

private extension MascotLook {
    init(name: String) { self.init(); self.name = name }
}

/// Envoie l'apparence au serveur (`POST /mascot/look`) pour que les amis puissent la voir.
/// Seulement : identifiant d'appareil (empreinte côté serveur), code ami, apparence. Regroupé (1,5 s).
@MainActor
enum MascotLookSync {
    private static var task: Task<Void, Never>?
    private struct Body: Encodable { var id: String; var code: String; var look: MascotLook }
    private struct Ok: Decodable { var ok: Bool? }

    static func schedule() {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            let body = Body(id: Identity.deviceId, code: Identity.friendCode, look: MascotLookStore.shared.look)
            _ = try? await API.post("mascot/look", body: body, as: Ok.self)
        }
    }
}
