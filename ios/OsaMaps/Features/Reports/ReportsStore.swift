import Foundation
import CoreLocation
import Observation

/// État local du module : signalements connus (zone visible), les miens, mes votes, réglages,
/// envoi en attente (5 s annulables), question « Toujours là ? ».
/// Temps réel : on rejoint les tuiles z10 visibles (rooms socket « rpt:10/x/y » côté serveur).
@MainActor
@Observable
final class ReportsStore {
    static let shared = ReportsStore()

    enum Vote: String, Codable, Sendable { case still, gone }

    struct Settings: Codable, Equatable {
        /// Types dont on reçoit les alertes en conduite.
        var alerts: [String: Bool] = Dictionary(uniqueKeysWithValues: ReportsKind.allCases.map { ($0.rawValue, true) })
        /// Proposer « Toujours là ? » en passant à côté.
        var ask = true
        func alert(_ k: ReportsKind) -> Bool { alerts[k.rawValue] ?? true }
    }

    /// Signalement choisi, envoyé après `undoDelay` sauf annulation.
    struct Pending: Equatable {
        var kind: ReportsKind
        var sub: String?
        var coordinate: CLLocationCoordinate2D
        var heading: Double?
        var at: Date
        static func == (a: Pending, b: Pending) -> Bool { a.kind == b.kind && a.sub == b.sub && a.at == b.at }
    }

    /// Question « Toujours là ? » en cours (affichée dans le hud).
    struct Ask: Equatable { var id: String; var at: Date }

    static let undoDelay: TimeInterval = 5
    static let askDuration: TimeInterval = 9

    var items: [String: Report] = [:] { didSet { onItemsChange?() } }
    /// id → expiration (ms) : mes signalements.
    var mine: [String: Double] = Store.load("reports.mine", default: [:])
    /// id → vote : mes votes.
    var voted: [String: Vote] = Store.load("reports.voted", default: [:])
    var settings: Settings = Store.load("reports.settings", default: Settings()) {
        didSet { Store.save("reports.settings", settings) }
    }
    var pending: Pending?
    var ask: Ask?

    /// Prévenu à chaque changement de `items` (le calque de carte se resynchronise).
    @ObservationIgnored var onItemsChange: (() -> Void)?
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var askTask: Task<Void, Never>?
    @ObservationIgnored private var watched: [String] = []
    @ObservationIgnored private var loaded: (w: Double, s: Double, e: Double, n: Double, at: Date)?
    @ObservationIgnored private var tokens: [BusToken] = []
    @ObservationIgnored private var started = false

    private init() {}

    func upsert(_ r: Report) { if r.alive { items[r.id] = r } }

    func remove(_ id: String) {
        guard items[id] != nil else { return }
        items[id] = nil
        if ask?.id == id { setAsk(nil) }
    }

    // MARK: - Tuiles z10 (mêmes calculs que le serveur)

    private static let z = 10.0
    private static func tileX(_ lng: Double) -> Int { Int(((lng + 180) / 360 * pow(2, z)).rounded(.down)) }
    private static func tileY(_ lat: Double) -> Int {
        let r = max(-85, min(85, lat)) * .pi / 180
        return Int(((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * pow(2, z)).rounded(.down))
    }

    /// Tuiles couvrant une zone (30 max, les plus proches du centre d'abord).
    static func tiles(w: Double, s: Double, e: Double, n: Double) -> [String] {
        let x0 = tileX(w), x1 = tileX(e), y0 = tileY(n), y1 = tileY(s)
        let cx = Double(x0 + x1) / 2, cy = Double(y0 + y1) / 2
        var out: [(t: String, d: Double)] = []
        for x in x0...max(x0, x1) {
            for y in y0...max(y0, y1) {
                out.append(("10/\(x)/\(y)", pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2)))
            }
        }
        return out.sorted { $0.d < $1.d }.prefix(30).map(\.t)
    }

    // MARK: - Réseau

    /// Charge les signalements d'une zone et rejoint ses tuiles temps réel.
    func watchArea(w: Double, s: Double, e: Double, n: Double, around: CLLocationCoordinate2D?) async {
        var w = w, s = s, e = e, n = n
        // la position compte toujours (en conduite, la carte ne montre que la route devant)
        if let a = around {
            w = min(w, a.longitude - 0.03); e = max(e, a.longitude + 0.03)
            s = min(s, a.latitude - 0.02); n = max(n, a.latitude + 0.02)
        }
        // bornée à 4° (limite serveur), centrée
        let cx = (w + e) / 2, cy = (s + n) / 2
        w = max(-180, max(w, cx - 1.95)); e = min(180, min(e, cx + 1.95))
        s = max(-85, max(s, cy - 1.95)); n = min(85, min(n, cy + 1.95))

        let tiles = Self.tiles(w: w, s: s, e: e, n: n)
        if tiles != watched {
            watched = tiles
            Socket.shared.emit("reports:watch", ["tiles": tiles])
        }
        if let L = loaded, w >= L.w, e <= L.e, s >= L.s, n <= L.n, Date().timeIntervalSince(L.at) < 120 { return }
        // on charge un peu plus large que demandé, pour ne pas recharger à chaque déplacement
        let mx = min(0.5, (e - w) * 0.5), my = min(0.5, (n - s) * 0.5)
        w = max(-180, w - mx); e = min(180, e + mx); s = max(-85, s - my); n = min(85, n + my)
        if e - w > 3.98 { let c = (w + e) / 2; w = c - 1.99; e = c + 1.99 }
        if n - s > 3.98 { let c = (s + n) / 2; s = c - 1.99; n = c + 1.99 }
        loaded = (w, s, e, n, Date())
        let bbox = [w, s, e, n].map { String(format: "%.4f", $0) }.joined(separator: ",")
        struct List: Decodable { var reports: [Report] }
        do {
            let list: List = try await API.get("reports?bbox=\(bbox)")
            var next = items
            // remplace ce qui est dans la zone, garde le reste
            for r in items.values where r.lng >= w && r.lng <= e && r.lat >= s && r.lat <= n { next[r.id] = nil }
            for r in list.reports where r.alive { next[r.id] = r }
            if next != items { items = next }
        } catch {
            loaded = nil // hors ligne : on réessaiera au prochain déplacement
        }
    }

    private func persistMine() {
        let t = Reports.nowMs
        mine = mine.filter { $0.value > t }
        voted = voted.filter { items[$0.key] != nil || mine[$0.key] != nil }
        Store.save("reports.mine", mine)
        Store.save("reports.voted", voted)
    }

    // MARK: - Envoi (touche 2 : une tuile → envoi après 5 s, annulable)

    /// Choisit un type : position et cap AU MOMENT de l'appui.
    func pick(_ kind: ReportsKind) {
        guard let pos = Core.shared.position else {
            emit(.toast(Toast(text: "Position inconnue : impossible de signaler", icon: "location.slash", tone: .warn)))
            Haptic.play("error")
            return
        }
        Haptic.play("medium")
        pending = Pending(kind: kind, sub: nil, coordinate: pos.coordinate, heading: pos.heading, at: .now)
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoDelay))
            guard !Task.isCancelled else { return }
            self?.sendPending()
        }
    }

    /// Précision facultative (n'arrête pas le compte à rebours).
    func toggleSub(_ id: String) {
        guard var p = pending else { return }
        p.sub = p.sub == id ? nil : id
        pending = p
        Haptic.play("light")
    }

    func cancelPending() {
        pendingTask?.cancel(); pendingTask = nil
        pending = nil
        Haptic.play("light")
    }

    /// Envoie tout de suite (bouton « Envoyer » ou fin du délai). Le panneau se ferme ; si on
    /// l'avait fermé autrement pendant le délai, le signalement part quand même.
    func sendPending() {
        pendingTask?.cancel(); pendingTask = nil
        guard let p = pending else { return }
        pending = nil
        ReportsPanels.closeOwn()
        Haptic.play("success")
        Task { await send(p) }
    }

    @discardableResult
    func send(_ p: Pending) async -> Report? {
        struct Body: Encodable {
            var deviceId: String, type: String, sub: String?, lng: Double, lat: Double, heading: Double?, pseudo: String
        }
        struct Reply: Decodable { var report: Report; var merged: Bool }
        let heading = p.heading.flatMap { $0.isFinite ? ($0.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) : nil }
        do {
            let res: Reply = try await API.post("reports", body: Body(
                deviceId: Identity.deviceId, type: p.kind.rawValue, sub: p.sub,
                lng: p.coordinate.longitude, lat: p.coordinate.latitude, heading: heading, pseudo: Identity.nickname))
            upsert(res.report)
            if res.merged {
                voted[res.report.id] = .still
                emit(.pointsEarn(amount: 2, reason: "Vote : toujours là (doublon rejoint)"))
                emit(.toast(Toast(text: "Déjà signalé : merci, ta confirmation compte", icon: "checkmark", tone: .good)))
            } else {
                mine[res.report.id] = res.report.expiresAt
                emit(.pointsEarn(amount: 5, reason: "Signalement : \(p.kind.label)"))
                emit(.toast(Toast(text: "Merci ! \(p.kind.title(sub: p.sub))", icon: "checkmark", tone: .good)))
            }
            persistMine()
            return res.report
        } catch {
            emit(.toast(Toast(text: Self.errorText(error, "Signalement non envoyé, réessaie"), icon: "exclamationmark.triangle", tone: .warn)))
            return nil
        }
    }

    // MARK: - Votes

    /// Vote « toujours là » / « plus là ».
    func vote(_ id: String, _ v: Vote) async {
        let isMine = mine[id] != nil
        if voted[id] != nil && !isMine { return }
        voted[id] = v
        if ask?.id == id { setAsk(nil) }
        Haptic.play(v == .still ? "success" : "light")
        struct Body: Encodable { var deviceId: String; var vote: String }
        struct Reply: Decodable { var report: Report?; var removed: Bool; var already: Bool? }
        let path = "reports/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/vote"
        do {
            let res: Reply = try await API.post(path, body: Body(deviceId: Identity.deviceId, vote: v.rawValue))
            if res.removed || res.report == nil { remove(id) } else if let r = res.report { upsert(r) }
            if !isMine && res.already != true {
                emit(.pointsEarn(amount: 1, reason: v == .still ? "Vote : toujours là" : "Vote : plus là"))
            }
        } catch let e as API.HTTPError where e.status == 404 {
            remove(id)
        } catch {
            emit(.toast(Toast(text: Self.errorText(error, "Vote non envoyé"), icon: "exclamationmark.triangle", tone: .warn)))
        }
        persistMine()
    }

    /// Message d'erreur du serveur (`{"error":"…"}`), avec majuscule ; sinon le texte de secours.
    static func errorText(_ e: Error, _ fallback: String) -> String {
        guard let h = e as? API.HTTPError,
              let data = h.message.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let m = obj["error"] as? String, !m.isEmpty else { return fallback }
        return m.prefix(1).uppercased() + m.dropFirst()
    }

    // MARK: - « Toujours là ? »

    func setAsk(_ a: Ask?) {
        askTask?.cancel()
        ask = a
        guard let a else { return }
        askTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.askDuration))
            guard !Task.isCancelled, let self, self.ask?.id == a.id else { return }
            self.ask = nil
        }
    }

    // MARK: - Temps réel

    func connectRealtime() {
        guard !started else { return }
        started = true
        let socket = Socket.shared
        tokens.append(socket.onConnect { [weak self] in
            guard let self else { return }
            socket.emit("reports:hello", ["deviceId": Identity.deviceId])
            if !self.watched.isEmpty { socket.emit("reports:watch", ["tiles": self.watched]) }
        })
        let onReport: ([Any]) -> Void = { [weak self] args in
            guard let r = Self.decode(Report.self, args.first) else { return }
            self?.upsert(r)
        }
        tokens.append(socket.on("reports:new", onReport))
        tokens.append(socket.on("reports:update", onReport))
        tokens.append(socket.on("reports:remove") { [weak self] args in
            if let id = (args.first as? [String: Any])?["id"] as? String { self?.remove(id) }
        })
        tokens.append(socket.on("reports:thanks") { args in
            let m = args.first as? [String: Any]
            let amount = (m?["amount"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? 2
            emit(.pointsEarn(amount: min(5, amount), reason: "Ton signalement est confirmé"))
            if Core.shared.mode != .drive {
                let label = (m?["type"] as? String).flatMap(ReportsKind.init(rawValue:))?.label ?? "?"
                emit(.toast(Toast(text: "Ton signalement « \(label) » a été confirmé", icon: "checkmark", tone: .good)))
            }
        })
        // ménage : expirés
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                let s = ReportsStore.shared
                let t = Reports.nowMs
                for r in s.items.values where r.expiresAt <= t { s.remove(r.id) }
            }
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ any: Any?) -> T? {
        guard let any, JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
