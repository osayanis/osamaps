import Foundation

/// Classement hebdo (opt-in, désactivé par défaut) : envoie seulement le pseudo et les points de la semaine
/// (`server/features/mascot.js`). L'identifiant d'appareil sert à ne compter qu'une ligne par personne ;
/// le serveur n'en garde qu'une empreinte et ne le renvoie jamais.
@MainActor
enum MascotBoard {
    struct Row: Codable, Hashable { var name: String; var points: Int; var me: Bool? }
    struct Board: Codable { var week: String; var top: [Row]; var rank: Int?; var total: Int }

    private struct Score: Encodable { var id: String; var name: String; var points: Int; var week: String }
    private struct Leave: Encodable { var id: String }
    private struct Ok: Decodable { var ok: Bool? }

    static func sync() async -> Board? {
        let m = MascotEngine.shared
        guard m.settings.leaderboard else { return nil }
        let body = Score(id: Identity.deviceId, name: Identity.nickname, points: m.weekPoints, week: MascotEngine.weekKey())
        return try? await API.post("mascot/score", body: body, as: Board.self)
    }

    static func leave() async {
        _ = try? await API.post("mascot/leave", body: Leave(id: Identity.deviceId), as: Ok.self)
    }
}
