import AppIntents
import Foundation

/// Siri et Raccourcis (App Intents). Les intents ouvrent l'app, attendent que les modules aient
/// démarré, puis passent par le Bus (jamais d'appel direct à un autre module) :
///   « Rentrer à la maison avec OsaMaps »  → lit `Store.load("search.home", default: Place?.none)`
///                                           (adresse Maison du module search) → `.placeGo(home)`
///   « Signaler la police avec OsaMaps »   → `.custom(name: "shell:report", payload: ["kind": "police"])`
///   « Signaler un accident avec OsaMaps » → idem avec kind accident | jam | hazard | works
///                                           (le module reports l'écoute : panneau pré-rempli, envoi après
///                                           5 s annulables). Loi française : jamais « radar » dans les phrases.
///   « Arrêter la navigation OsaMaps »     → `.driveStop(arrived: false)` + mode browse

/// Attend que l'app soit prête (modules démarrés + carte créée), au plus ~6 s.
@MainActor
enum ShellLaunch {
    static func ready() async {
        for _ in 0..<60 {
            if ShellState.shared.started && Core.shared.mapReady { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // les abonnements des modules se font dans start() : laisser un tour de boucle
        try? await Task.sleep(for: .milliseconds(150))
    }
}

struct ShellGoHomeIntent: AppIntent {
    static let title: LocalizedStringResource = "Rentrer à la maison"
    static let description = IntentDescription("Calcule l’itinéraire vers ton adresse Maison.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await ShellLaunch.ready()
        guard let home = Store.load("search.home", default: Place?.none) else {
            Bus.shared.emit(.toast(Toast(id: "shell-nohome", text: "Ajoute d’abord ton adresse Maison dans la recherche.", icon: "house", tone: .warn)))
            return .result(dialog: "Tu n’as pas encore d’adresse Maison dans OsaMaps.")
        }
        Core.shared.settingsOpen = false
        Core.shared.openPanel(nil)
        Bus.shared.emit(.placeGo(home))
        return .result(dialog: "Je calcule le trajet vers la maison.")
    }
}

struct ShellReportPoliceIntent: AppIntent {
    static let title: LocalizedStringResource = "Signaler la police"
    static let description = IntentDescription("Signale un contrôle de police à ta position.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await ShellLaunch.ready()
        Bus.shared.emit(.custom(name: "shell:report", payload: ["kind": "police"]))
        return .result(dialog: "Signalement de police prêt : il part dans 5 secondes, touche Annuler si besoin.")
    }
}

enum ShellReportKind: String, AppEnum {
    case police, accident, jam, hazard, works

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Signalement"
    static let caseDisplayRepresentations: [ShellReportKind: DisplayRepresentation] = [
        .police: DisplayRepresentation(title: "la police", synonyms: ["un contrôle", "la police"]),
        .accident: DisplayRepresentation(title: "un accident", synonyms: ["accident"]),
        .jam: DisplayRepresentation(title: "un bouchon", synonyms: ["bouchon", "un embouteillage"]),
        .hazard: DisplayRepresentation(title: "un danger", synonyms: ["danger", "un obstacle"]),
        .works: DisplayRepresentation(title: "des travaux", synonyms: ["travaux"]),
    ]
}

struct ShellReportIntent: AppIntent {
    static let title: LocalizedStringResource = "Signaler"
    static let description = IntentDescription("Signale un évènement sur la route à ta position.")
    static let openAppWhenRun = true

    @Parameter(title: "Quoi")
    var kind: ShellReportKind

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await ShellLaunch.ready()
        Bus.shared.emit(.custom(name: "shell:report", payload: ["kind": kind.rawValue]))
        return .result(dialog: "Signalement prêt : il part dans 5 secondes, touche Annuler si besoin.")
    }
}

struct ShellStopDriveIntent: AppIntent {
    static let title: LocalizedStringResource = "Arrêter la navigation"
    static let description = IntentDescription("Arrête le guidage en cours.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await ShellLaunch.ready()
        guard Core.shared.mode == .drive else { return .result(dialog: "Aucune navigation en cours.") }
        Bus.shared.emit(.driveStop(arrived: false))
        Core.shared.mode = .browse
        return .result(dialog: "Navigation arrêtée.")
    }
}

struct ShellShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShellGoHomeIntent(),
            phrases: [
                "Rentrer à la maison avec \(.applicationName)",
                "Rentrer chez moi avec \(.applicationName)",
                "\(.applicationName) maison",
            ],
            shortTitle: "Rentrer à la maison",
            systemImageName: "house.fill"
        )
        AppShortcut(
            intent: ShellReportPoliceIntent(),
            phrases: [
                "Signaler la police avec \(.applicationName)",
                "Signaler un contrôle avec \(.applicationName)",
            ],
            shortTitle: "Signaler la police",
            systemImageName: "light.beacon.max.fill"
        )
        AppShortcut(
            intent: ShellReportIntent(),
            phrases: [
                "Signaler \(\.$kind) avec \(.applicationName)",
                "Signaler \(\.$kind) sur \(.applicationName)",
            ],
            shortTitle: "Signaler",
            systemImageName: "exclamationmark.bubble.fill"
        )
        AppShortcut(
            intent: ShellStopDriveIntent(),
            phrases: [
                "Arrêter la navigation \(.applicationName)",
                "Arrêter le guidage \(.applicationName)",
            ],
            shortTitle: "Arrêter la navigation",
            systemImageName: "xmark.circle.fill"
        )
    }
}
