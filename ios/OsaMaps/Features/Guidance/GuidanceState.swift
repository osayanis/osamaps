import Foundation
import Observation
import AVFoundation

/// Alerte affichée dans le HUD (reçue via `.driveAlert`).
struct GuidanceAlert: Identifiable, Equatable {
    var id: String
    var kind: String
    var text: String
    var tone: DriveAlert.Tone
    /// Distance annoncée à la réception (m) et compteur kilométrique à ce moment-là.
    var baseDistance: Double
    var baseOdo: Double
    /// Distance restante (m), recalculée à chaque position.
    var remaining: Double
    var receivedAt: Date

    /// Police / gendarmerie : bleu, quel que soit le ton envoyé.
    var displayTone: DriveAlert.Tone {
        GuidancePhrases.match("police|gendarm", kind) != nil ? .police : tone
    }
}

struct GuidanceArrival: Equatable {
    var name: String
    /// "left" / "right" / nil.
    var side: String?
    var tripTime: Double
    var tripDistance: Double
}

/// État du guidage (propre au module, lu par le HUD, la barre du bas et la Live Activity).
@MainActor
@Observable
final class GuidanceState {
    static let shared = GuidanceState()

    /// Une conduite est en cours (démarrée par le moteur).
    var active = false
    var routeId: String?
    /// Distance parcourue sur le tracé (m).
    var along = 0.0
    /// Prochaine manœuvre et distance jusqu'à elle (m).
    var nextIndex = 1
    var distToNext = 0.0
    /// Seuil « maintenant » courant (m) : en dessous, la carte de manœuvre passe en blanc.
    var nowThreshold = 30.0
    var recalculating = false
    var arrived: GuidanceArrival?
    var speedKmh: Int?
    var limitKmh: Int?
    var speeding = false
    var alerts: [GuidanceAlert] = []
    var overview = false

    func reset() {
        active = false; routeId = nil; along = 0; nextIndex = 1; distToNext = 0; nowThreshold = 30
        recalculating = false; arrived = nil; limitKmh = nil; speeding = false; alerts = []; overview = false
    }

    private init() {}
}

/// Réglages propres au guidage (Store « guidance.prefs ») ; voix et tolérance sont dans `Prefs`.
@MainActor
@Observable
final class GuidancePrefs {
    static let shared = GuidancePrefs()

    private struct Saved: Codable { var speedBeep = true; var speedVoice = false }

    /// Petit bip une fois par dépassement de la limite (+ tolérance).
    var speedBeep: Bool { didSet { save() } }
    /// Dire la nouvelle limitation quand elle change.
    var speedVoice: Bool { didSet { save() } }

    private init() {
        let s = Store.load("guidance.prefs", default: Saved())
        speedBeep = s.speedBeep
        speedVoice = s.speedVoice
    }

    private func save() { Store.save("guidance.prefs", Saved(speedBeep: speedBeep, speedVoice: speedVoice)) }
}

/// Petit bip discret à deux notes (comme la version web), synthétisé en mémoire : pas de fichier son.
@MainActor
enum GuidanceSound {
    private static var player: AVAudioPlayer?
    private static let wav: Data = makeBeep()

    static func beep() {
        let s = AVAudioSession.sharedInstance()
        // ne coupe pas la musique ; la voix (Voice) remet sa propre catégorie quand elle parle
        if s.category != .playback { try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers]) }
        try? s.setActive(true)
        player = try? AVAudioPlayer(data: wav)
        player?.volume = 0.9
        player?.play()
    }

    private static func makeBeep() -> Data {
        let rate = 44_100.0
        let total = Int(rate * 0.32)
        var samples = [Int16](repeating: 0, count: total)
        for (i, freq) in [(0, 880.0), (1, 1175.0)] {
            let start = Double(i) * 0.16
            for n in 0..<total {
                let t = Double(n) / rate - start
                guard t >= 0, t < 0.13 else { continue }
                let env = t < 0.015 ? t / 0.015 : exp(-(t - 0.015) * 60)
                let v = sin(2 * .pi * freq * t) * env * 0.45
                samples[n] = Int16(clamping: Int(Double(samples[n]) + v * 32_767))
            }
        }
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(total * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}
