import AVFoundation

/// Synthèse vocale française. Baisse le volume de la musique pendant l'annonce (ducking),
/// fonctionne écran verrouillé (mode arrière-plan « audio »). Respecte `Prefs.shared.voice`.
@MainActor
final class Voice: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Voice()
    private let synth = AVSpeechSynthesizer()
    private lazy var voice: AVSpeechSynthesisVoice? = {
        let fr = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "fr-FR" }
        return fr.first { $0.quality == .premium } ?? fr.first { $0.quality == .enhanced } ?? AVSpeechSynthesisVoice(language: "fr-FR")
    }()

    private override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, priority: Bool = false) {
        guard Prefs.shared.voice else { return }
        if priority { synth.stopSpeaking(at: .immediate) }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? s.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.synth.isSpeaking { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        }
    }
}
