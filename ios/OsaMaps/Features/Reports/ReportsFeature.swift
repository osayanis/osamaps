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
        #if DEBUG
        reportsDebugLaunch()
        #endif
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

#if DEBUG
/// Tests visuels sans lien (Debug seulement) : argument de lancement
///   -reportsOpen reports | pick:<kind> | detail:<id> | drive-ask:<id> | settings
@MainActor
private func reportsDebugLaunch() {
    guard let arg = UserDefaults.standard.string(forKey: "reportsOpen") else { return }
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(3))
        let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "reports": ReportsPanels.openOwn(ReportsPanels.panel)
        case "pick": reportsQuickReport(kind: value, sub: nil)
        case "detail": ReportsPanels.openOwn(ReportsPanels.detail, reportId: value)
        case "drive-ask":
            Core.shared.mode = .drive
            ReportsStore.shared.setAsk(.init(id: value, at: .now))
        case "drive":
            Core.shared.mode = .drive
        case "settings": Core.shared.settingsOpen = true
        case "pick-detail":
            // envoi complet (5 s) puis fiche de MON dernier signalement, dans la même session
            reportsQuickReport(kind: value, sub: nil)
            try? await Task.sleep(for: .seconds(8))
            let store = ReportsStore.shared
            if let id = store.mine.max(by: { $0.value < $1.value })?.key {
                ReportsPanels.openOwn(ReportsPanels.detail, reportId: id)
            }
        case "drive-route":
            // itinéraire droit vers le nord (3,3 km) depuis la position simulée ; journalise les alertes
            let start = Core.shared.position?.coordinate ?? Location.defaultCenter
            let coords = (0...30).map { Coord(lat: start.latitude + Double($0) * 0.001, lng: start.longitude) }
            let route = Route(id: "reports-test", coords: coords, distance: 3300, duration: 200, maneuvers: [])
            Bus.shared.on { e in
                var line: String?
                if case .driveAlert(let a) = e { line = "alerte : \(a.text) | \(Int(a.distance)) m | \(a.tone.rawValue) | \(a.id)" }
                if case .pointsEarn(let n, let r) = e { line = "points : \(n) \(r)" }
                guard let line else { return }
                let s = ReportsStore.shared
                let full = line + (s.ask.map { " | ask=\($0.id)" } ?? "")
                NSLog("OsaMaps reports-test %@", full)
                if let f = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("reports-test.log") {
                    let old = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
                    try? (old + full + "\n").write(to: f, atomically: true, encoding: .utf8)
                }
            }
            Core.shared.routes = [route]; Core.shared.activeRoute = 0
            Core.shared.mode = .drive; Core.shared.follow = true
            emit(.driveStart(routeId: route.id))
            // trace de « Toujours là ? » (proposé après le passage)
            Task { @MainActor in
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if let a = ReportsStore.shared.ask { emit(.custom(name: "reports:test-ask", payload: ["id": a.id])); NSLog("OsaMaps reports-test ask %@", a.id)
                        if let f = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("reports-test.log") {
                            let old = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
                            try? (old + "ask : \(a.id)\n").write(to: f, atomically: true, encoding: .utf8)
                        }
                        break
                    }
                }
            }
        case "vote-detail":
            // vote « toujours là » puis fiche (doit afficher « Merci, c'est noté »)
            try? await Task.sleep(for: .seconds(2))
            await ReportsStore.shared.vote(value, .still)
            ReportsPanels.openOwn(ReportsPanels.detail, reportId: value)
        default: break
        }
    }
}
#endif
