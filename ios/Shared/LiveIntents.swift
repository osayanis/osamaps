import AppIntents

// Boutons des Live Activities (iOS 17 : Button(intent:)).
// Un LiveActivityIntent s'exécute dans le processus de l'APP (réveillée en arrière-plan si besoin) :
// la déclaration est ici (compilée dans l'app ET l'extension), `perform()` est écrit deux fois :
//   - app       : OsaMaps/Features/Guidance/GuidanceLive.swift (le vrai travail : Bus, guidage)
//   - extension : OsaMapsLive/LiveIntentsStubs.swift (jamais appelé, requis pour compiler)

/// « Arrêter » le guidage depuis l'écran verrouillé ou la Dynamic Island.
struct LiveStopIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Arrêter le guidage"
    static let isDiscoverable = false
    init() {}
}

/// Couper / remettre la voix du guidage.
struct LiveVoiceIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Couper ou remettre la voix"
    static let isDiscoverable = false
    init() {}
}

/// Musique : « toggle », « next », « previous » → Bus `.custom(name: "music:command", payload: ["action": …])`.
struct LiveMusicIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Commander la musique"
    static let isDiscoverable = false

    @Parameter(title: "Action")
    var action: String

    init() {}
    init(action: String) { self.action = action }
}
