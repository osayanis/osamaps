import Foundation
import CoreLocation
import Observation
import UIKit

/// Le cerveau de la mascotte (port de `engine.ts`) : points, niveaux, badges, accessoires,
/// statistiques de trajet, humeur en direct et petits messages. Tout est local (clé « osamaps.mascot.state »).
@MainActor
@Observable
final class MascotEngine {
    static let shared = MascotEngine()

    struct Settings: Codable, Equatable {
        var animations = true
        var talk = true
        /// Classement hebdo (pseudo + points de la semaine), opt-in.
        var leaderboard = false
    }

    struct Week: Codable, Equatable { var key = ""; var points = 0 }

    /// Ce qui est enregistré (mêmes champs que la version web).
    struct Saved: Codable {
        var points = 0
        var totalDistance = 0.0
        var trips = 0
        var badges: [String: Date] = [:]
        var equipped: [MascotAccessory] = []
        var history: [MascotTrip] = []
        var reports = 0
        var confirmed = 0
        var votes = 0
        var destinations: [String] = []
        var days: [String] = []
        var week = Week()
        var settings = Settings()
        var lastTalk = Date.distantPast

        init() {}
        // tolérant : un champ ajouté plus tard ne casse pas la lecture
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            points = (try? c.decode(Int.self, forKey: .points)) ?? 0
            totalDistance = (try? c.decode(Double.self, forKey: .totalDistance)) ?? 0
            trips = (try? c.decode(Int.self, forKey: .trips)) ?? 0
            badges = (try? c.decode([String: Date].self, forKey: .badges)) ?? [:]
            equipped = (try? c.decode([MascotAccessory].self, forKey: .equipped)) ?? []
            history = (try? c.decode([MascotTrip].self, forKey: .history)) ?? []
            reports = (try? c.decode(Int.self, forKey: .reports)) ?? 0
            confirmed = (try? c.decode(Int.self, forKey: .confirmed)) ?? 0
            votes = (try? c.decode(Int.self, forKey: .votes)) ?? 0
            destinations = (try? c.decode([String].self, forKey: .destinations)) ?? []
            days = (try? c.decode([String].self, forKey: .days)) ?? []
            week = (try? c.decode(Week.self, forKey: .week)) ?? Week()
            settings = (try? c.decode(Settings.self, forKey: .settings)) ?? Settings()
            lastTalk = (try? c.decode(Date.self, forKey: .lastTalk)) ?? .distantPast
        }
    }

    enum Mood: Equatable { case calm, curious, excited, busy, happy, worried, sad, sleepy }
    enum Arms: Equatable { case rest, up, wave }

    /// État en direct (non enregistré).
    struct Live: Equatable {
        var mood: Mood = .calm
        var arms: Arms = .rest
        var hop = 0
        var sleeping = false
        var moving = false
    }

    private(set) var saved: Saved
    private(set) var live = Live()
    /// Trajet en cours (nil hors conduite).
    @ObservationIgnored private var trip: Tracker?

    struct Tracker {
        var start: Date
        var distance = 0.0
        var moving = 0.0
        var maxSpeed = 0.0
        var stops = 0
        var stoppedSince: Date?
        var countedStop = false
        var last: (coord: CLLocationCoordinate2D, time: Date)?
        var earned = 0
        var destination: String?
        var destKey: String?
        var pauseTold = false
        var startLevel: Int
    }

    // MARK: - Lecture

    var level: MascotData.LevelInfo { MascotData.level(of: saved.points) }
    var settings: Settings { saved.settings }
    var weekPoints: Int { saved.week.key == Self.weekKey() ? saved.week.points : 0 }

    /// Accessoires portés ET encore débloqués.
    var worn: [MascotAccessory] { saved.equipped.filter(isUnlocked) }

    func isUnlocked(_ id: MascotAccessory) -> Bool {
        guard let a = MascotData.accessory(id) else { return false }
        if let b = a.badge { return saved.badges[b] != nil }
        return level.level >= (a.level ?? 99)
    }

    /// Animations : réglage de la mascotte ET « Réduire les animations » du système.
    var animated: Bool { saved.settings.animations && !UIAccessibility.isReduceMotionEnabled }

    // MARK: - Écriture

    private init() {
        saved = Store.load("mascot.state", default: Saved())
    }

    private func persist() { Store.save("mascot.state", saved) }

    private func patch(_ f: (inout Saved) -> Void) {
        f(&saved)
        persist()
    }

    private func setLive(_ f: (inout Live) -> Void) {
        var l = live
        f(&l)
        if l != live { live = l }
    }

    /// Met / enlève un accessoire (un seul par emplacement).
    func toggleAccessory(_ id: MascotAccessory) {
        guard isUnlocked(id), let def = MascotData.accessory(id) else { return }
        patch { s in
            if s.equipped.contains(id) { s.equipped.removeAll { $0 == id } }
            else { s.equipped = s.equipped.filter { MascotData.accessory($0)?.spot != def.spot } + [id] }
        }
    }

    func setSetting(_ f: (inout Settings) -> Void) {
        patch { f(&$0.settings) }
    }

    // MARK: - Semaine, jours

    /// Semaine ISO 8601 en UTC (« 2026-W45 »), comme le serveur.
    static func weekKey(_ d: Date = .now) -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!       // comme le serveur (sinon le dimanche soir ne compte pas)
        let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return String(format: "%d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    private static func dayKey(_ d: Date = .now) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    // MARK: - Points, badges

    private var driving: Bool { Core.shared.mode == .drive }
    @ObservationIgnored private var pendingLevelToast: String?
    @ObservationIgnored private var badgeCheckLater = false

    /// Ajoute des points ; renvoie le nouveau niveau s'il a changé.
    @discardableResult
    func addPoints(_ n: Int) -> MascotTrip.LevelUp? {
        guard n > 0 else { return nil }
        let before = level.level
        let wk = Self.weekKey()
        patch { s in
            s.week = s.week.key == wk ? Week(key: wk, points: s.week.points + n) : Week(key: wk, points: n)
            s.points += n
        }
        trip?.earned += n
        let after = level
        if after.level > before {
            let text = "Niveau \(after.level) : \(after.name) !"
            if driving { pendingLevelToast = text } else { say(text, tone: .good, force: true) }
            return .init(level: after.level, name: after.name)
        }
        return nil
    }

    /// Vérifie les badges ; renvoie les nouveaux.
    @discardableResult
    private func checkBadges(trip t: MascotTrip? = nil) -> [String] {
        var got = Set(saved.badges.keys)
        var earned: [String] = []
        func grant(_ id: String, _ cond: Bool) { if cond && !got.contains(id) { earned.append(id); got.insert(id) } }
        let km = saved.totalDistance / 1000
        grant("premier-trajet", saved.trips >= 1)
        grant("10-trajets", saved.trips >= 10)
        grant("100-km", km >= 100)
        grant("1000-km", km >= 1000)
        grant("signaleur", saved.reports >= 10)
        grant("confirme", saved.confirmed >= 10)
        grant("entraide", saved.votes >= 10)
        grant("explorateur", saved.destinations.count >= 10)
        grant("fidele", saved.days.count >= 7)
        if let t {
            let h0 = Calendar.current.component(.hour, from: t.start), h1 = Calendar.current.component(.hour, from: t.end)
            func night(_ h: Int) -> Bool { h >= 22 || h < 5 }
            grant("marathon", t.distance >= 100_000)
            grant("nuit", t.distance >= 1000 && (night(h0) || night(h1)))
            grant("matinal", t.distance >= 1000 && h0 >= 5 && h0 < 7)
        }
        if !earned.isEmpty {
            patch { s in for id in earned { s.badges[id] = .now } }
            addPoints(earned.count * MascotData.badgePoints)
            if t == nil { for id in earned { say("Nouveau badge : \(MascotData.badge(id)?.name ?? id) !", tone: .good, force: true) } }
        }
        return earned
    }

    /// Points venus d'un autre module (`.pointsEarn`), avec les raisons du module reports :
    /// « Ton signalement est confirmé » (contient aussi « signal » : confirm d'abord),
    /// « Vote : toujours là / plus là », « Signalement : Police »…
    private func earn(_ amount: Int, reason r: String) {
        let n = max(0, min(MascotData.maxEvent, amount))
        if r.range(of: "confirm", options: .caseInsensitive) != nil { patch { $0.confirmed += 1 } }
        else if r.range(of: "^vote", options: [.regularExpression, .caseInsensitive]) != nil { patch { $0.votes += 1 } }
        else if r.range(of: "signal|report", options: [.regularExpression, .caseInsensitive]) != nil { patch { $0.reports += 1 } }
        addPoints(n)
        if !driving { checkBadges() } else { badgeCheckLater = true }
    }

    // MARK: - Humeur en direct

    @ObservationIgnored private var moodTask: Task<Void, Never>?

    func react(_ mood: Mood, _ arms: Arms, seconds: Double) {
        moodTask?.cancel()
        setLive { $0.mood = mood; $0.arms = arms; $0.hop += 1; $0.sleeping = false }
        moodTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.setLive { $0.mood = .calm; $0.arms = .rest }
        }
    }

    /// Un petit coucou (appui sur la mascotte).
    func poke() {
        lastMove = .now
        react(.happy, .wave, seconds: 1.4)
    }

    // MARK: - La mascotte parle (rarement)

    private static let cooldown: TimeInterval = 20 * 60
    private static let hello = ["Bonne route !", "C'est parti, bonne route !", "En route ! Je surveille la carte."]

    func say(_ text: String, tone: Toast.Tone = .info, force: Bool = false) {
        guard saved.settings.talk else { return }
        let now = Date.now
        if !force && now.timeIntervalSince(saved.lastTalk) < Self.cooldown { return }
        patch { $0.lastTalk = now }
        emit(.toast(Toast(text: text, icon: "mascot", tone: tone)))
    }

    // MARK: - Statistiques de trajet

    /// Simulateur accéléré (-sim 90 -speedup 6) : durées remises à l'échelle pour des stats cohérentes.
    private let speedup: Double = {
        let d = UserDefaults.standard
        guard d.object(forKey: "sim") != nil else { return 1 }
        return max(1, d.double(forKey: "speedup"))
    }()

    private func startTrip() {
        let dest = Core.shared.destination
        trip = Tracker(start: .now, destination: dest?.name,
                       destKey: dest.map { String(format: "%.2f,%.2f", $0.lng, $0.lat) },
                       startLevel: level.level)
        // seulement avant de rouler, une fois de temps en temps
        let sp = Core.shared.position?.speed ?? 0
        if sp < 2 && Double.random(in: 0..<1) < 0.6 { say(Self.hello.randomElement()!) }
    }

    /// Une nouvelle position pendant la conduite.
    private func track(_ p: Position) {
        guard var t = trip else { return }
        let now = p.time
        if let last = t.last {
            let dt = now.timeIntervalSince(last.time)
            let d = Geo.distance(last.coord, p.coordinate)
            if dt > 0 {
                let computed = d / dt / speedup
                // vrais sauts GPS ignorés : téléportation (> 2 km d'un coup) ou vitesse absurde avec un fix imprécis
                let imprecise = p.accuracy == nil || p.accuracy! > 30
                if d > 2000 || (computed > 70 && d > 50 && imprecise) {
                    t.last = (p.coordinate, now); trip = t; return
                }
                var speed = p.speed ?? computed
                if speed > 70 { speed = min(computed, 70) }
                t.distance += d
                if speed > 1.2 {
                    t.moving += dt * speedup
                    t.stoppedSince = nil
                    t.countedStop = false
                } else if t.distance > 100 {
                    if t.stoppedSince == nil { t.stoppedSince = now }
                    if !t.countedStop, let s = t.stoppedSince, now.timeIntervalSince(s) * speedup > 20 { t.stops += 1; t.countedStop = true }
                }
                t.maxSpeed = max(t.maxSpeed, min(speed, 70))
            }
        }
        t.last = (p.coordinate, now)
        // pause conseillée après 2 h de route (une fois)
        if !t.pauseTold && now.timeIntervalSince(t.start) * speedup > 2 * 3600 {
            t.pauseTold = true
            say("Ça fait deux heures que tu roules : pense à faire une pause.", force: true)
        }
        trip = t
    }

    @ObservationIgnored private var arrivedName: String?

    private func endTrip(arrived: Bool) -> MascotTrip? {
        guard let t = trip else { return nil }
        trip = nil
        let end = max(Date.now, t.last?.time ?? .distantPast)
        let duration = max(1, end.timeIntervalSince(t.start) * speedup)
        if !arrived && t.distance < 300 { return nil }          // fausse alerte : on n'enregistre rien

        let pointsBefore = saved.points
        let day = Self.dayKey()
        patch { s in
            if !s.days.contains(day) { s.days = Array((s.days + [day]).suffix(60)) }
            if arrived, let k = t.destKey, !s.destinations.contains(k) { s.destinations = Array((s.destinations + [k]).suffix(200)) }
            s.totalDistance += t.distance
            if arrived { s.trips += 1 }
        }
        let earnedBefore = t.earned
        var levelUp = addPoints(Int(t.distance / 1000) * MascotData.perKm + (arrived ? MascotData.arrived : 0))
        var trip = MascotTrip(id: String(Int(t.start.timeIntervalSince1970 * 1000)), start: t.start, end: end,
                              distance: t.distance, duration: duration, moving: t.moving,
                              avgKmh: t.distance / duration * 3.6, maxKmh: t.maxSpeed * 3.6, stops: t.stops,
                              points: 0, arrived: arrived, destination: arrivedName ?? t.destination, badges: [])
        trip.badges = checkBadges(trip: trip)
        let lvl = level
        // niveau gagné pendant le trajet (signalements, km, badges) : affiché dans le résumé
        if lvl.level > t.startLevel { levelUp = .init(level: lvl.level, name: lvl.name) }
        trip.levelUp = levelUp
        if levelUp != nil && arrived { pendingLevelToast = nil }   // le résumé le dit déjà
        // points du trajet = km + arrivée + badges + ce que les autres modules ont donné pendant le trajet
        trip.points = earnedBefore + (saved.points - pointsBefore)
        patch { s in s.history = Array(([trip] + s.history).prefix(20)) }
        arrivedName = nil
        return trip
    }

    @ObservationIgnored private var finishing = false

    private func finish(arrived: Bool) {
        guard !finishing, trip != nil else { return }
        finishing = true
        defer { finishing = false }
        if let t = endTrip(arrived: arrived), t.arrived {
            // laisse les autres modules fermer leurs panneaux, puis ouvre le résumé
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                Core.shared.openPanel("trip-summary", data: t)
            }
        }
    }

    /// Pour les tests : un faux trajet terminé de `km` kilomètres.
    func demoTrip(km: Double = 12.4, minutes: Double = 17, destination: String = "Vichy") {
        let start = Date.now.addingTimeInterval(-minutes * 60)
        trip = Tracker(start: start, distance: km * 1000, moving: minutes * 52, maxSpeed: 24.7, stops: 2,
                       destination: destination, destKey: "demo-\(destination)", pauseTold: true, startLevel: level.level)
        arrivedName = destination
        react(.happy, .up, seconds: 4)
        finish(arrived: true)
    }

    // MARK: - Sommeil : à l'arrêt prolongé

    @ObservationIgnored private var lastMove = Date.now
    @ObservationIgnored private var lastCoord: CLLocationCoordinate2D?
    private static let sleepAfter: TimeInterval = 60

    private func watchMovement(_ p: Position) {
        let moved = lastCoord.map { Geo.distance($0, p.coordinate) > 4 } ?? false
        let fast = (p.speed ?? 0) > 0.8
        if moved || fast {
            lastMove = .now
            if live.sleeping { setLive { $0.sleeping = false; $0.mood = .calm } }
        }
        lastCoord = p.coordinate
        let moving = fast || moved
        if moving != live.moving { setLive { $0.moving = moving } }
    }

    func sleepNow() { setLive { $0.sleeping = true; $0.mood = .sleepy; $0.arms = .rest } }

    // MARK: - Démarrage

    @ObservationIgnored private var token: BusToken?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastMode: Mode = .browse

    func start() {
        guard token == nil else { return }
        lastMode = Core.shared.mode
        token = Bus.shared.on { [weak self] e in self?.handle(e) }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.live.sleeping, Date.now.timeIntervalSince(self.lastMove) > Self.sleepAfter else { return }
                self.sleepNow()
            }
        }
        observeMode()
        runLaunchScript()
    }

    /// Tests dans le Simulateur sans dépendre des liens : argument de lancement
    /// `-mascotTest "reset;points=800;wear=casquette;wait=2;profile"` (étapes séparées par « ; »).
    private func runLaunchScript() {
        guard let script = UserDefaults.standard.string(forKey: "mascotTest"), !script.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            for step in script.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                let parts = step.split(separator: "=", maxSplits: 1).map(String.init)
                let cmd = parts[0], arg = parts.count > 1 ? parts[1] : ""
                switch cmd {
                case "wait": try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
                case "profile": Core.shared.openPanel("profile")
                case "settings": Core.shared.settingsOpen = true
                case "points": handleTestLink("osamaps://mascot/points?n=\(arg)")
                case "wear": handleTestLink("osamaps://mascot/wear?id=\(arg)")
                case "demo-trip": handleTestLink("osamaps://mascot/demo-trip?name=\(arg.isEmpty ? "Vichy" : arg)")
                default: handleTestLink("osamaps://mascot/\(cmd)")
                }
            }
        }
    }

    private func handle(_ e: BusEvent) {
        switch e {
        case .driveStart:
            startTrip()
            lastMove = .now
            setLive { $0.sleeping = false }
        case .driveAlert:
            react(.excited, .rest, seconds: 1.6)
        case .driveArrived(let name):
            arrivedName = name.isEmpty ? nil : name
            react(.happy, .up, seconds: 4)
            // certains modules n'émettent pas driveStop juste après l'arrivée : on clôt ici
            finish(arrived: true)
        case .driveStop(let arrived):
            finish(arrived: arrived)
            Task { try? await Task.sleep(for: .seconds(1.5)); _ = await MascotBoard.sync() }
        case .geoTick(let p):
            watchMovement(p)
            if trip != nil { track(p) }
        case .pointsEarn(let amount, let reason):
            earn(amount, reason: reason)
        case .custom(let name, let payload) where name == "url":
            handleTestLink(payload["url"] ?? "")
        default:
            break
        }
    }

    /// Fin de conduite sans évènement driveStop (sécurité) + messages retenus pendant la conduite.
    private func observeMode() {
        withObservationTracking { _ = Core.shared.mode } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let mode = Core.shared.mode
                if self.lastMode == .drive && mode != .drive {
                    if self.trip != nil { self.finish(arrived: false) }
                    if let t = self.pendingLevelToast { self.say(t, tone: .good, force: true); self.pendingLevelToast = nil }
                    if self.badgeCheckLater { self.badgeCheckLater = false; self.checkBadges() }
                }
                self.lastMode = mode
                self.observeMode()
            }
        }
    }

    /// Liens de test : osamaps://mascot/demo-trip | sleep | poke | points?n=500 | wear?id=casquette | reset
    private func handleTestLink(_ s: String) {
        guard let u = URLComponents(string: s), u.host == "mascot" else { return }
        let q = Dictionary((u.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        switch u.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "demo-trip": demoTrip(km: Double(q["km"] ?? "") ?? 12.4, destination: q["name"] ?? "Vichy")
        case "sleep": sleepNow()
        case "poke": poke()
        case "alert": react(.excited, .rest, seconds: 1.6)
        case "points": addPoints(Int(q["n"] ?? "") ?? 100); if !driving { checkBadges() }
        case "wear": if let a = MascotAccessory(rawValue: q["id"] ?? "") { toggleAccessory(a) }
        case "reset": saved = Saved(); persist()
        default: break
        }
    }
}
