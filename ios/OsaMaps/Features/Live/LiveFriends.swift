import Foundation
import ActivityKit

/// Live Activity « un ami arrive » : quand on suit le trajet partagé d'un ami (osamaps://suivre/JETON),
/// l'écran verrouillé et la Dynamic Island montrent son heure d'arrivée et la distance qui lui reste,
/// puis « Léa est là » (Dynamic Island ouverte en grand) à son arrivée.
/// Alimentée par l'évènement `.custom("friends:trip", …)` (voir LiveFeature.swift) que le module friends doit émettre.
@MainActor
final class LiveFriends {
    static let shared = LiveFriends()

    private var activity: Activity<FriendActivityAttributes>?
    private var last: FriendActivityAttributes.ContentState?
    private var lastAt = Date.distantPast
    private var firstRemaining: Double?
    private var token: BusToken?
    private var sendChain: Task<Void, Never>?

    private init() {}

    func start() {
        guard token == nil else { return }
        // une activité d'ami restée d'une session précédente : le suivi n'existe plus
        for old in Activity<FriendActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        token = Bus.shared.on { [weak self] e in
            MainActor.assumeIsolated {
                guard case .custom(let name, let p) = e else { return }
                if name == "friends:trip" { self?.apply(p) }
                #if DEBUG
                if name == "url", let s = p["url"], let url = URL(string: s), url.host() == "live-friend" { self?.test(url) }
                #endif
            }
        }
    }

    private func apply(_ p: [String: String]) {
        let state = p["state"] ?? "live"
        let tok = p["token"] ?? "ami"
        if state == "ended" { end(arrived: false); return }
        let name = (p["name"] ?? "").isEmpty ? "Ton ami" : p["name"]!
        let etaRaw = Double(p["eta"] ?? "")
        let eta = etaRaw.map { Date(timeIntervalSince1970: $0 > 100_000_000_000 ? $0 / 1000 : $0) }
        let remaining = Double(p["remaining"] ?? "")

        if let a = activity, a.attributes.token != tok { end(arrived: false) }
        if activity == nil { firstRemaining = nil }
        if let r = remaining, r > (firstRemaining ?? 0) { firstRemaining = r }

        var s = FriendActivityAttributes.ContentState(destination: (p["dest"] ?? "").isEmpty ? "sa destination" : p["dest"]!,
                                                      eta: eta, remaining: remaining)
        if let r = remaining, let f = firstRemaining, f > 0 { s.progress = min(1, max(0, 1 - r / f)) }
        s.arrived = state == "arrived"
        s.stale = p["stale"] == "1"
        if s.arrived { s.progress = 1 }

        guard let activity else {
            guard !s.arrived, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            do {
                activity = try Activity.request(attributes: FriendActivityAttributes(name: name, token: tok),
                                                content: ActivityContent(state: s, staleDate: Date().addingTimeInterval(600)), pushType: nil)
                last = s
                lastAt = Date()
                NSLog("OsaMaps live : Activity.request OK (ami %@)", name)
            } catch {
                NSLog("OsaMaps live : Activity.request (ami) a échoué : %@", String(describing: error))
            }
            return
        }
        let justArrived = s.arrived && last?.arrived != true
        // une position toutes les 2 s environ : on met à jour au plus toutes les 10 s (sauf changement d'état)
        guard s != last, justArrived || last?.stale != s.stale || Date().timeIntervalSince(lastAt) >= 10 else { return }
        last = s
        lastAt = Date()
        let content = ActivityContent(state: s, staleDate: Date().addingTimeInterval(600))
        let prev = sendChain
        if justArrived {
            let alert = AlertConfiguration(title: LocalizedStringResource(stringLiteral: "\(name) est là"),
                                           body: LocalizedStringResource(stringLiteral: s.destination), sound: .default)
            sendChain = Task {
                await prev?.value
                await activity.update(content, alertConfiguration: alert)
                NSLog("OsaMaps live : notification « %@ est là »", name)
                // l'activité reste visible 10 min puis disparaît
                await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(600)))
            }
            self.activity = nil
        } else {
            sendChain = Task { await prev?.value; await activity.update(content) }
        }
    }

    private func end(arrived: Bool) {
        guard let a = activity else { return }
        activity = nil
        last = nil
        let prev = sendChain
        sendChain = Task { await prev?.value; await a.end(nil, dismissalPolicy: .immediate) }
    }

    #if DEBUG
    /// osamaps://live-friend?name=Léa&dest=Gare%20de%20Vichy&in=600&remaining=4200&state=live
    private func test(_ url: URL) {
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                           uniquingKeysWith: { a, _ in a })
        var p = q
        p["token"] = q["token"] ?? "test"
        if let s = Double(q["in"] ?? "") { p["eta"] = String(Date().addingTimeInterval(s).timeIntervalSince1970) }
        apply(p)
    }
    #endif
}
