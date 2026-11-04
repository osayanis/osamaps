import UIKit
import Observation

/// Mode « passager » : si le véhicule roule (> 15 km/h) et qu'on commence à taper (le clavier s'ouvre,
/// n'importe où dans l'app), on demande une fois par trajet « Tu es passager ? ».
/// Les modules n'ont RIEN à faire pour profiter de cette protection de base : le clavier est surveillé.
///
/// UTILITAIRE POUR LES AUTRES MODULES (sans appeler ce dossier directement) — par le Bus :
///
///     // demander (token = identifiant libre, pour reconnaître SA réponse)
///     emit(.custom(name: "safety:passenger-check", payload: ["token": "search-1"]))
///     // écouter la réponse
///     Bus.shared.on { e in
///         if case .custom("safety:passenger-answer", let p) = e, p["token"] == "search-1" {
///             p["answer"]  // "stopped" | "passenger" | "driver"
///         }
///     }
///
/// Réponses : "stopped" (à l'arrêt ou < 15 km/h, ou réglage désactivé : rien à demander, réponse immédiate),
/// "passenger" (l'utilisateur confirme qu'il est passager pour ce trajet), "driver" (il conduit : mieux vaut
/// ne pas ouvrir de saisie). La question n'est posée qu'une fois par trajet ; ensuite la réponse mémorisée est
/// renvoyée tout de suite. Sans réponse au bout de ~1 s (module safety absent), considérer « stopped ».
/// Nouveau trajet = début de navigation, ou arrêt de plus de 5 minutes.
@MainActor
@Observable
final class SafetyPassenger {
    static let shared = SafetyPassenger()

    enum Answer: String, Sendable { case stopped, passenger, driver }

    /// La question est affichée (overlay).
    private(set) var open = false

    @ObservationIgnored private var answer: Answer?
    @ObservationIgnored private var waiters: [(Answer) -> Void] = []
    @ObservationIgnored private var stoppedSince: Date?
    @ObservationIgnored private var lastMode: Mode = .browse
    @ObservationIgnored private var tokens: [BusToken] = []
    @ObservationIgnored private var keyboardObserver: NSObjectProtocol?
    @ObservationIgnored private var asking = false

    private static let speedMin = 15 / 3.6

    private init() {}

    private var moving: Bool { (Core.shared.position?.speed ?? 0) > Self.speedMin }

    /// Pose la question si besoin (une fois par trajet). Utilisable aussi via le Bus (voir en-tête).
    func check() async -> Answer {
        guard SafetySettings.shared.passenger, moving else { return .stopped }
        if let answer { return answer }
        return await withCheckedContinuation { cont in
            waiters.append { cont.resume(returning: $0) }
            open = true
            Haptic.play("light")
        }
    }

    /// Appelé par l'overlay.
    func reply(_ r: Answer) {
        answer = r
        open = false
        let w = waiters
        waiters = []
        for f in w { f(r) }
    }

    private func resetTrip() { answer = nil }

    func start() {
        guard tokens.isEmpty else { return }
        lastMode = Core.shared.mode
        tokens.append(Bus.shared.on { [weak self] e in
            guard let self else { return }
            switch e {
            case .custom(name: "safety:passenger-check", let payload):
                let token = payload["token"] ?? ""
                Task {
                    let r = await self.check()
                    emit(.custom(name: "safety:passenger-answer", payload: ["token": token, "answer": r.rawValue]))
                }
            case .driveStart:
                self.resetTrip()
            case .geoTick(let p):
                if Core.shared.mode == .drive && self.lastMode != .drive { self.resetTrip() }
                self.lastMode = Core.shared.mode
                if (p.speed ?? 0) < 1 {
                    if self.stoppedSince == nil { self.stoppedSince = Date() }
                    if let s = self.stoppedSince, Date().timeIntervalSince(s) > 300 { self.resetTrip() }
                } else {
                    self.stoppedSince = nil
                }
            default: break
            }
        })
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in SafetyPassenger.shared.keyboardWillShow() }
        }
    }

    /// Le clavier s'ouvre : si l'on roule et qu'on ne sait pas encore qui tape, on suspend la saisie et on demande.
    private func keyboardWillShow() {
        guard !asking, SafetySettings.shared.passenger, moving else { return }
        // déjà répondu pendant ce trajet : « passager » → on laisse taper ; « conducteur » → on ne harcèle pas
        guard answer == nil else { return }
        let field = UIResponder.safetyCurrentFirstResponder()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        asking = true
        Task {
            let r = await check()
            asking = false
            switch r {
            case .passenger:
                field?.becomeFirstResponder()
            case .driver:
                emit(.toast(Toast(text: "D'accord, garde les yeux sur la route : la saisie attendra l'arrêt.", icon: "car.fill", tone: .info)))
            case .stopped:
                field?.becomeFirstResponder()
            }
        }
    }
}

extension UIResponder {
    private static weak var safetyFound: UIResponder?

    /// Le champ qui a le focus clavier (astuce classique : action envoyée au premier répondeur).
    static func safetyCurrentFirstResponder() -> UIResponder? {
        safetyFound = nil
        UIApplication.shared.sendAction(#selector(safetyCaptureFirstResponder), to: nil, from: nil, for: nil)
        return safetyFound
    }

    @objc private func safetyCaptureFirstResponder() { UIResponder.safetyFound = self }
}
