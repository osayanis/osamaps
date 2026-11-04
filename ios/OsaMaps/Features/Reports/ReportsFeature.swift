import SwiftUI

/// Signalements de la communauté : bouton Signaler (rail), panneaux « reports » / « report-detail »
/// (sheet), marqueurs (calque de carte), « Toujours là ? » (hud), réglages.
/// Serveur : server/features/reports.js. Référence : web/src/features/reports/.
///
/// Lien de test en plus : osamaps://report?id=<id> → ouvre la fiche d'un signalement.
@MainActor
let reportsFeature = Feature(
    id: "reports",
    name: "Signalements",
    slots: [
        SlotEntry(.rail, order: 20) { ReportsButton() },
        SlotEntry(.sheet, order: 30) { ReportsSheet() },
        SlotEntry(.hud, order: 80) { ReportsAskCard() },
        SlotEntry(.settings, order: 40) { ReportsSettingsSection() },
    ],
    mapLayers: [ReportsLayer.layer],
    start: {
        ReportsStore.shared.connectRealtime()
        ReportsWatch.start()
        Bus.shared.on { event in
            guard case .custom(name: let name, payload: let p) = event else { return }
            switch name {
            case "url":
                guard let s = p["url"], let c = URLComponents(string: s) else { return }
                let q = c.queryItems ?? []
                if c.host == "report", let id = q.first(where: { $0.name == "id" })?.value {
                    ReportsPanels.openOwn(ReportsPanels.detail, reportId: id)
                } else if c.host == "signaler", let k = q.first(where: { $0.name == "kind" })?.value {
                    reportsQuickReport(kind: k, sub: q.first(where: { $0.name == "sub" })?.value)
                }
            case "shell:report":
                // Siri / raccourci (module shell) : kind = police|accident|jam|hazard|works|closure|weather
                reportsQuickReport(kind: p["kind"] ?? "", sub: p["sub"])
            default: break
            }
        }
    }
)

/// Signalement rapide (Siri, raccourci, lien osamaps://signaler?kind=police) : ouvre le panneau
/// pré-rempli, avec le compte à rebours de 5 s annulable (jamais d'envoi sans délai d'annulation).
/// Accepte l'id du type ou son libellé français (« bouchon », « travaux »…). Au lancement à froid,
/// attend la position jusqu'à 6 s.
@MainActor
func reportsQuickReport(kind: String, sub: String?) {
    let key = kind.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
    let aliases: [String: ReportsKind] = [
        "bouchon": .jam, "embouteillage": .jam, "danger": .hazard, "travaux": .works,
        "route fermee": .closure, "fermeture": .closure, "meteo": .weather,
        "controle": .police, "gendarmerie": .police,
    ]
    guard let k = ReportsKind(rawValue: key) ?? aliases[key]
            ?? ReportsKind.allCases.first(where: { $0.label.lowercased().folding(options: .diacriticInsensitive, locale: nil) == key }) else {
        emit(.toast(Toast(text: "Type de signalement inconnu", icon: "exclamationmark.triangle", tone: .warn)))
        return
    }
    Task { @MainActor in
        for _ in 0..<30 where Core.shared.position == nil { try? await Task.sleep(for: .milliseconds(200)) }
        if Core.shared.panel != ReportsPanels.panel { ReportsPanels.openOwn(ReportsPanels.panel) }
        let store = ReportsStore.shared
        store.pick(k)
        if let sub, k.subs.contains(where: { $0.id == sub }), store.pending != nil { store.toggleSub(sub) }
    }
}
