import Foundation
import ActivityKit

/// Live Activity de guidage (écran verrouillé + Dynamic Island, affichée par l'extension OsaMapsLive).
/// Démarrée au début de la conduite, mise à jour avec un débit raisonnable, terminée à l'arrivée ou à l'arrêt.
@MainActor
final class GuidanceLive {
    static let shared = GuidanceLive()
    typealias State = NavActivityAttributes.ContentState

    private var activity: Activity<NavActivityAttributes>?
    private var last: State?
    private var lastAt = Date.distantPast

    private init() {}

    func start(destination: String, state: State) {
        // une activité restée d'une session précédente (app tuée) : on la retire
        for old in Activity<NavActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        activity = nil
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(attributes: NavActivityAttributes(destinationName: destination),
                                            content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(180)),
                                            pushType: nil)
            last = state
            lastAt = Date()
        } catch {
            activity = nil
        }
    }

    /// Mise à jour : tout de suite si la manœuvre, l'alerte ou l'état changent ; sinon au plus toutes les 2 s
    /// quand la distance affichée change, et toutes les 20 s pour l'heure d'arrivée.
    func update(_ s: State, force: Bool = false) {
        guard let activity else { return }
        let now = Date()
        let since = now.timeIntervalSince(lastAt)
        var send = force || last == nil
        if let l = last {
            let keyChanged = l.kind != s.kind || l.instruction != s.instruction || l.street != s.street || l.exit != s.exit
                || l.alert != s.alert || l.arrived != s.arrived || l.imminent != s.imminent
            let distChanged = Self.label(l.distance) != Self.label(s.distance)
                || (l.alertDistance.map(Self.label) != s.alertDistance.map(Self.label))
            send = send || keyChanged || (distChanged && since >= 2) || since >= 20
        }
        guard send, s != last else { return }
        last = s
        lastAt = now
        let content = ActivityContent(state: s, staleDate: now.addingTimeInterval(180))
        Task { await activity.update(content) }
    }

    func end(final s: State?) {
        guard let activity else { return }
        self.activity = nil
        last = nil
        let content = s.map { ActivityContent(state: $0, staleDate: nil) }
        let policy: ActivityUIDismissalPolicy = s?.arrived == true ? .after(Date().addingTimeInterval(90)) : .immediate
        Task { await activity.end(content, dismissalPolicy: policy) }
    }

    /// Même arrondi que l'affichage (inutile de réveiller l'écran pour 3 m).
    private static func label(_ m: Double) -> String { Geo.formatDistance(m) }
}
