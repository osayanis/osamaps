import Foundation
import ActivityKit
import AppIntents

/// Live Activity de guidage (écran verrouillé + Dynamic Island, affichée par l'extension OsaMapsLive).
/// Démarrée au début de la conduite, mise à jour avec un débit raisonnable, terminée à l'arrivée ou à l'arrêt.
/// Tout est local (compte Apple gratuit : pas de push APNs) : l'app tourne en arrière-plan pendant la conduite.
///
/// Le moteur fournit l'état de base (manœuvre, distances, alerte en cours) ; GuidanceLive y ajoute :
///   - les notifications brèves : la Dynamic Island s'ouvre en grand (AlertConfiguration) pour une alerte
///     (`.driveAlert`), un recalcul (`.driveRerouted`), un nouveau retard (`.trafficDelay`), l'arrivée ;
///     regroupées (0,7 s), au plus une toutes les 15 s et 8 par 10 min, une seule fois par alerte ;
///   - le retard trafic, le morceau en cours (`music:now`), l'état de la voix.
/// Écoute le Bus dès le lancement (`listen()`, appelé par le module live) pour connaître la musique avant le départ.
@MainActor
final class GuidanceLive {
    static let shared = GuidanceLive()
    typealias State = NavActivityAttributes.ContentState

    private var activity: Activity<NavActivityAttributes>?
    /// Dernier état fourni par le moteur (sans les ajouts Live).
    private var base: State?
    /// Dernier état envoyé.
    private var last: State?
    private var lastAt = Date.distantPast
    /// Les mises à jour partent dans l'ordre.
    private var sendChain: Task<Void, Never>?
    private var token: BusToken?

    // — notifications —
    private struct Banner {
        var kind: String
        var title: String
        var detail: String?
        var tone: String
        var symbol: String
        var short: String?
        var until: Date
        /// Alerte : distance à la réception et reste du trajet à ce moment-là (pour le décompte).
        var distance0: Double?
        var remaining0: Double?
        /// Le détail se termine par « arrivée à HH:MM » (recalcul, retard).
        var withETA = false
    }
    private var banner: Banner?
    /// La prochaine mise à jour ouvre la Dynamic Island en grand.
    private var wantsAlert = false
    private var alertTimes: [Date] = []
    private var notified: Set<String> = []
    private var incoming: [DriveAlert] = []
    private var groupTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var rerouteTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// Texte d'alerte (sans distance) → type, pour choisir le pictogramme de l'alerte affichée par le moteur.
    private var alertKinds: [String: String] = [:]
    private var traffic: (routeId: String, baseline: Double)?
    private var trafficSilentNext = false
    private var delay: Double = 0
    private var lastTrafficBanner = Date.distantPast
    private var lastTrafficAlert = Date.distantPast
    private var lastReroute = Date.distantPast
    private var music: (title: String, artist: String?, source: String?, playing: Bool)?

    private static let minGap: TimeInterval = 15
    private static let maxPerWindow = 8
    private static let window: TimeInterval = 600

    private init() {}

    // MARK: - branchement

    func listen() {
        guard token == nil else { return }
        token = Bus.shared.on { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }
    }

    private func handle(_ e: BusEvent) {
        switch e {
        case .driveAlert(let a): onAlert(a)
        case .driveRerouted(let id): onReroute(id)
        case .trafficDelay(let id, let d, _): onTraffic(id, d)
        case .driveArrived(let name): onArrived(name)
        case .custom(name: "music:now", let p): onMusic(p)
        default: break
        }
    }

    // MARK: - cycle de vie (appelé par GuidanceEngine)

    func start(destination: String, state: State) {
        listen()
        // une activité restée d'une session précédente (app tuée) ou du trajet d'avant : on la retire
        activity = nil
        endAll()
        resetTrip()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("OsaMaps live : Live Activities désactivées dans les Réglages")
            return
        }
        base = state
        let s = decorate(state)
        do {
            activity = try Activity.request(attributes: NavActivityAttributes(destinationName: destination),
                                            content: ActivityContent(state: s, staleDate: Date().addingTimeInterval(180)),
                                            pushType: nil)
            last = s
            lastAt = Date()
            NSLog("OsaMaps live : Activity.request OK (%@) → %@", activity?.id ?? "?", destination)
        } catch {
            activity = nil
            NSLog("OsaMaps live : Activity.request a échoué : %@", String(describing: error))
        }
    }

    /// Mise à jour : tout de suite si la manœuvre, l'alerte, la notification ou la musique changent ; sinon au plus
    /// toutes les 2 s quand une distance affichée change, et toutes les 20 s pour l'heure d'arrivée.
    func update(_ s: State, force: Bool = false) {
        base = s
        push(force: force)
    }

    func end(final s: State?) {
        let a = activity
        activity = nil
        defer { resetTrip(); base = nil; last = nil }
        guard let a else { return }
        let content = s.map { ActivityContent(state: decorate($0), staleDate: nil) }
        let policy: ActivityUIDismissalPolicy = s?.arrived == true ? .after(Date().addingTimeInterval(90)) : .immediate
        let prev = sendChain
        sendChain = Task {
            await prev?.value
            await a.end(content, dismissalPolicy: policy)
            NSLog("OsaMaps live : Activity.end (%@)", s?.arrived == true ? "arrivée" : "arrêt")
        }
    }

    /// Termine toutes les activités de guidage (y compris une orpheline d'une session précédente).
    func endAll() {
        for old in Activity<NavActivityAttributes>.activities where old.id != activity?.id {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Réenvoie l'état (ex. la voix vient d'être coupée depuis la Live Activity).
    func refresh() { push(force: true) }

    private func resetTrip() {
        banner = nil
        wantsAlert = false
        incoming = []
        notified = []
        groupTask?.cancel(); groupTask = nil
        clearTask?.cancel(); rerouteTask?.cancel(); retryTask?.cancel()
        traffic = nil
        trafficSilentNext = false
        delay = 0
        alertKinds = [:]
    }

    // MARK: - envoi

    private func push(force: Bool) {
        guard let activity, let base else { return }
        let s = decorate(base)
        let now = Date()
        var send = force || wantsAlert || last == nil
        if !send, let l = last {
            let since = now.timeIntervalSince(lastAt)
            let keyChanged = Self.key(l) != Self.key(s)
            let distChanged = Self.labels(l) != Self.labels(s)
            send = keyChanged || (distChanged && since >= 2) || since >= 20
        }
        guard send, s != last || wantsAlert else { return }
        let alert = wantsAlert ? alertConfiguration(s) : nil
        wantsAlert = false
        last = s
        lastAt = now
        let content = ActivityContent(state: s, staleDate: now.addingTimeInterval(180))
        let prev = sendChain
        sendChain = Task {
            await prev?.value
            if let alert {
                await activity.update(content, alertConfiguration: alert)
                NSLog("OsaMaps live : notification « %@ » (Dynamic Island ouverte), état %@", s.bannerTitle ?? "", String(describing: activity.activityState))
            } else {
                await activity.update(content)
            }
        }
    }

    /// Ce qui doit partir tout de suite s'il change (les distances et l'heure sont ramenées à zéro).
    private static func key(_ s: State) -> State {
        var k = s
        k.distance = 0; k.remaining = 0; k.eta = .distantPast; k.progress = 0
        k.alertDistance = s.alertDistance == nil ? nil : 0
        k.bannerDistance = s.bannerDistance == nil ? nil : 0
        k.delay = (s.delay / 60).rounded()
        return k
    }

    /// Distances telles qu'affichées (inutile de réveiller l'écran pour 3 m).
    private static func labels(_ s: State) -> [String] {
        [LiveOsa.distance(s.distance), s.alertDistance.map(LiveOsa.alertDistance) ?? "", s.bannerDistance.map(LiveOsa.alertDistance) ?? "",
         LiveOsa.distance(s.remaining), "\(Int(s.eta.timeIntervalSince1970 / 60))"]
    }

    private func alertConfiguration(_ s: State) -> AlertConfiguration {
        let title = s.bannerTitle ?? s.alert ?? "OsaMaps"
        let body = [s.bannerTrailing, s.bannerDetail].compactMap { $0 }.joined(separator: " · ")
        // la voix annonce déjà l'alerte : son silencieux ; voix coupée → son du système
        let sound: AlertConfiguration.AlertSound = Prefs.shared.voice ? .named("LiveSilence.caf") : .default
        return AlertConfiguration(title: LocalizedStringResource(stringLiteral: title),
                                  body: LocalizedStringResource(stringLiteral: body.isEmpty ? "OsaMaps" : body), sound: sound)
    }

    /// L'état du moteur + les ajouts Live.
    private func decorate(_ base: State) -> State {
        var s = base
        let now = Date()
        if delay >= 60 && !s.arrived {
            s.delay = delay
            s.eta = s.eta.addingTimeInterval(delay)
        }
        if let a = s.alert { s.alertSymbol = Self.symbol(alertKinds[a] ?? "", tone: s.alertTone) }
        if let b = banner {
            if now < b.until || (b.kind == "arrival" && s.arrived) {
                s.bannerKind = b.kind
                s.bannerTitle = b.title
                s.bannerTone = b.tone
                s.bannerSymbol = b.symbol
                s.bannerShort = b.short
                s.bannerDetail = b.detail
                if b.withETA {
                    let eta = "arrivée à \(Self.clock(s.eta))"
                    s.bannerDetail = b.detail.map { "\($0) · \(eta)" } ?? eta.prefix(1).uppercased() + eta.dropFirst()
                }
                if let d0 = b.distance0, let r0 = b.remaining0 {
                    s.bannerDistance = max(0, d0 - max(0, r0 - base.remaining))
                }
            } else {
                banner = nil
            }
        }
        if let m = music {
            s.musicTitle = m.title
            s.musicArtist = m.artist
            s.musicSource = m.source
            s.musicPlaying = m.playing
        }
        s.voiceOn = Prefs.shared.voice
        return s
    }

    // MARK: - notifications

    private func show(_ b: Banner, expand: Bool) {
        banner = b
        let now = Date()
        alertTimes = alertTimes.filter { now.timeIntervalSince($0) < Self.window }
        let lastAlert = alertTimes.last ?? .distantPast
        if expand { retryTask?.cancel() }
        let gap = now.timeIntervalSince(lastAlert)
        if expand, b.kind == "arrival" || (gap >= Self.minGap && alertTimes.count < Self.maxPerWindow) {
            wantsAlert = true
            alertTimes.append(now)
        } else if expand, alertTimes.count < Self.maxPerWindow, b.kind != "arrival" {
            // trop tôt après la précédente : on la garde et on l'ouvre dès que l'écart est passé (si elle tient encore)
            let wait = Self.minGap - gap + 0.1
            NSLog("OsaMaps live : notification « %@ » reportée de %.0f s", b.title, wait)
            retryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled, self.activity != nil else { return }
                var again = b
                again.until = Date().addingTimeInterval(b.kind == "alert" ? 8 : 6)
                // alerte déjà dépassée ou presque : inutile
                if let d0 = again.distance0, let r0 = again.remaining0, let r = self.base?.remaining, d0 - (r0 - r) < 150 { return }
                self.show(again, expand: true)
            }
        } else {
            NSLog("OsaMaps live : notification « %@ » sans ouvrir la Dynamic Island", b.title)
        }
        clearTask?.cancel()
        if b.kind != "arrival" {
            let delay = b.until.timeIntervalSince(now) + 0.2
            clearTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.push(force: true)
            }
        }
        // juste après le traitement en cours (le moteur peut être en train de pousser le même évènement)
        Task { @MainActor [weak self] in
            guard let self, self.wantsAlert || self.banner != nil else { return }
            self.push(force: true)
        }
    }

    private func onAlert(_ a: DriveAlert) {
        let text = GuidancePhrases.stripDistance(a.text)
        alertKinds[text.isEmpty ? "Attention" : text] = a.kind
        guard activity != nil, !a.id.isEmpty, !notified.contains(a.id) else { return }
        notified.insert(a.id)
        if a.kind == "traffic" { lastTrafficAlert = Date() }
        incoming.append(a)
        // regroupement : les alertes qui arrivent ensemble (0,7 s) font une seule notification
        guard groupTask == nil else { return }
        groupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled else { return }
            self.groupTask = nil
            self.flushAlerts()
        }
    }

    private static func rank(_ t: String) -> Int {
        switch t { case "danger": 0; case "police": 1; case "warn": 2; default: 3 }
    }

    private func flushAlerts() {
        let list = incoming.sorted {
            let (ta, tb) = (Self.tone($0), Self.tone($1))
            return Self.rank(ta) != Self.rank(tb) ? Self.rank(ta) < Self.rank(tb) : $0.distance < $1.distance
        }
        incoming = []
        guard let first = list.first, let base else { return }
        let text = GuidancePhrases.stripDistance(first.text)
        let others = list.count - 1
        let tone = Self.tone(first)
        show(Banner(kind: "alert", title: text.isEmpty ? "Attention" : text,
                    detail: others > 0 ? "+\(others) autre\(others > 1 ? "s" : "") alerte\(others > 1 ? "s" : "") devant" : nil,
                    tone: tone, symbol: Self.symbol(first.kind, tone: tone), until: Date().addingTimeInterval(9),
                    distance0: first.distance > 0 ? first.distance : nil, remaining0: first.distance > 0 ? base.remaining : nil),
             // les informations (pause, carburant…) restent discrètes
             expand: list.contains { Self.tone($0) != "info" })
    }

    private func onReroute(_ routeId: String) {
        traffic = nil
        trafficSilentNext = true
        guard activity != nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastReroute) >= 45 else { return }
        lastReroute = now
        rerouteTask?.cancel()
        // le moteur prend le nouvel itinéraire à la position suivante : on attend la nouvelle heure d'arrivée
        rerouteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled, self.activity != nil else { return }
            self.show(Banner(kind: "reroute", title: "Nouvel itinéraire", detail: nil, tone: "info", symbol: "arrow.triangle.branch",
                             short: nil, until: Date().addingTimeInterval(7), withETA: true), expand: true)
        }
    }

    private func onTraffic(_ routeId: String, _ d: Double) {
        let changed = (delay / 60).rounded() != (d / 60).rounded()
        delay = d
        guard activity != nil else { return }
        guard let t = traffic, t.routeId == routeId else {
            traffic = (routeId, d)
            if d >= 300 && !trafficSilentNext { trafficBanner(total: d, increase: nil) }
            trafficSilentNext = false
            if changed { push(force: false) }
            return
        }
        if d - t.baseline >= 180 {
            traffic?.baseline = d
            trafficBanner(total: d, increase: d - t.baseline)
        } else if d < t.baseline - 180 {
            traffic?.baseline = d
        }
        if changed { push(force: false) }
    }

    private func trafficBanner(total: Double, increase: Double?) {
        let now = Date()
        // pas deux fois de suite, ni juste après l'alerte « Bouchon dans 1,2 km » du module trafic
        guard now.timeIntervalSince(lastTrafficBanner) >= 120, now.timeIntervalSince(lastTrafficAlert) >= 60 else { return }
        lastTrafficBanner = now
        // titre court (une ligne dans l'île) ; l'heure d'arrivée est déjà sur la ligne du bas
        show(Banner(kind: "traffic", title: increase == nil ? "Trafic" : "Ralentissement",
                    detail: increase == nil ? "Retard sur le trajet" : "\(LiveOsa.delay(total)) au total",
                    tone: total >= 900 ? "danger" : "slow", symbol: "car.2.fill", short: LiveOsa.delay(increase ?? total),
                    until: now.addingTimeInterval(8)), expand: true)
    }

    private func onArrived(_ name: String) {
        guard activity != nil else { return }
        show(Banner(kind: "arrival", title: "Vous voilà à destination", detail: name, tone: "ok", symbol: "flag.checkered",
                    short: nil, until: Date().addingTimeInterval(600)), expand: true)
    }

    private func onMusic(_ p: [String: String]) {
        let title = (p["title"] ?? "").trimmingCharacters(in: .whitespaces)
        music = title.isEmpty ? nil : (title, p["artist"].flatMap { $0.isEmpty ? nil : $0 }, p["source"], p["playing"] == "1")
        push(force: false)
    }

    /// Bouton lecture / pause : l'icône change tout de suite (le module musique confirmera par « music:now »).
    fileprivate func musicCommand(_ action: String) {
        if action == "toggle", music != nil { music?.playing.toggle(); push(force: true) }
        emit(.custom(name: "music:command", payload: ["action": action]))
    }

    // MARK: - pictogrammes

    private static func tone(_ a: DriveAlert) -> String {
        GuidancePhrases.match("police|gendarm", a.kind) != nil ? "police" : a.tone.rawValue
    }

    /// Même choix que le HUD (GuidanceAlertRow), plus les alertes des modules safety / along.
    static func symbol(_ kind: String, tone: String?) -> String {
        let k = kind.lowercased()
        func has(_ p: String) -> Bool { GuidancePhrases.match(p, k) != nil }
        if has("police|gendarm|control") || (k.isEmpty && tone == "police") { return "light.beacon.max.fill" }
        if has("jam|traffic|bouchon|trafic|slow") { return "car.2.fill" }
        if has("camera|radar|speed") { return "camera.fill" }
        if has("closure|closed|ferm|block") { return "minus.circle.fill" }
        if has("work|travaux|construction") { return "cone.fill" }
        if has("fog|brouillard") { return "cloud.fog.fill" }
        if has("ice|verglas|snow|neige") { return "snowflake" }
        if has("weather|meteo|météo|rain|pluie") { return "cloud.rain.fill" }
        if has("accident|crash") { return "car.side.rear.and.collision.and.car.side.front" }
        if has("zfe") { return "leaf.fill" }
        if has("school|ecole|école") { return "figure.walk" }
        if has("level-crossing|rail") { return "tram.fill" }
        if has("fuel|carbur") { return "fuelpump.fill" }
        if has("^ev$|charge") { return "bolt.fill" }
        if has("night|fatigue") { return "moon.fill" }
        if has("pause") { return "cup.and.saucer.fill" }
        return "exclamationmark.triangle.fill"
    }

    private static let clockFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func clock(_ d: Date) -> String { clockFormat.string(from: d) }
}

// MARK: - Boutons de la Live Activity (exécutés dans l'app ; déclarés dans Shared/LiveIntents.swift)

extension LiveStopIntent {
    @MainActor
    func perform() async throws -> some IntentResult {
        NSLog("OsaMaps live : bouton Arrêter")
        GuidanceEngine.shared.stopGuidance()
        GuidanceLive.shared.endAll()
        return .result()
    }
}

extension LiveVoiceIntent {
    @MainActor
    func perform() async throws -> some IntentResult {
        GuidanceEngine.shared.toggleVoice()
        NSLog("OsaMaps live : voix %@", Prefs.shared.voice ? "remise" : "coupée")
        GuidanceLive.shared.refresh()
        return .result()
    }
}

extension LiveMusicIntent {
    @MainActor
    func perform() async throws -> some IntentResult {
        let a = ["toggle", "next", "previous"].contains(action) ? action : "toggle"
        NSLog("OsaMaps live : musique %@", a)
        GuidanceLive.shared.musicCommand(a)
        return .result()
    }
}
