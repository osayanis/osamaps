import AppIntents

// Côté extension : jamais exécuté (un LiveActivityIntent tourne dans l'app), mais requis pour compiler.
// Le vrai `perform()` est dans OsaMaps/Features/Guidance/GuidanceLive.swift.

extension LiveStopIntent {
    func perform() async throws -> some IntentResult { .result() }
}

extension LiveVoiceIntent {
    func perform() async throws -> some IntentResult { .result() }
}

extension LiveMusicIntent {
    func perform() async throws -> some IntentResult { .result() }
}
