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
            guard case .custom(name: "url", payload: let p) = event,
                  let s = p["url"], let c = URLComponents(string: s), c.host == "report",
                  let id = c.queryItems?.first(where: { $0.name == "id" })?.value else { return }
            ReportsPanels.openOwn(ReportsPanels.detail, reportId: id)
        }
    }
)
