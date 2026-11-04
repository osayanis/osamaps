import Foundation
import CoreLocation
import Observation

/// Amis & partage — client temps réel (port de `store.ts`).
/// L'appareil s'identifie avec deviceId + un secret gardé dans le trousseau : personne ne peut se faire passer
/// pour lui. Les amis sont désignés par un identifiant public (pid), jamais par leur deviceId.
@MainActor
@Observable
final class FriendsStore {
    static let shared = FriendsStore()

    enum Status { case off, connecting, ready, error }

    var status: Status = .off
    var error: String?
    var me: FriendsMe?
    var friends: [FriendsFriend] = [] { didSet { FriendsMapLayer.sync() } }
    var incoming: [FriendsRequest] = []
    var outgoing: [FriendsRequest] = []
    var trip: FriendsSharedTrip?
    /// Montrer ma destination + heure d'arrivée à mes amis (opt-in).
    var showDest: Bool = Store.load("friends.showDest", default: false)
    /// Pseudo (copie observable de `Identity.nickname`).
    var nickname: String = Identity.nickname

    @ObservationIgnored private var started = false
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var tokens: [BusToken] = []
    @ObservationIgnored private var lastSent = Date.distantPast
    @ObservationIgnored private var lastCoord: CLLocationCoordinate2D?
    @ObservationIgnored private var lastTripSent = Date.distantPast
    @ObservationIgnored private var prevIncoming: Set<String> = []
    @ObservationIgnored private var sharing = false
    @ObservationIgnored private var pendingInvite: String?

    private init() {}

    var pendingCount: Int { incoming.count }

    // MARK: - Démarrage

    /// Écoute des liens dès la construction de l'app (un lien peut arriver avant `start`).
    func listenLinks() {
        guard !listening else { return }
        listening = true
        tokens.append(Bus.shared.on { [weak self] e in
            if case .custom(let name, let payload) = e, name == "url", let s = payload["url"] { self?.handleLink(s) }
        })
    }

    func start() {
        guard !started else { return }
        started = true
        listenLinks()
        sharing = Prefs.shared.shareLocation
        let s = Socket.shared
        tokens.append(s.onConnect { [weak self] in Task { await self?.hello() } })
        tokens.append(s.on("friends:state") { [weak self] a in self?.applyState(a.first, notify: true) })
        tokens.append(s.on("friends:presence") { [weak self] a in
            guard let self, let j = a.first as? [String: Any], let pid = j["pid"] as? String else { return }
            let on = j["online"] as? Bool ?? false
            self.friends = self.friends.map { var f = $0; if f.pid == pid { f.online = on }; return f }
        })
        tokens.append(s.on("friends:loc") { [weak self] a in
            guard let self, let j = a.first as? [String: Any], let pid = j["pid"] as? String, let loc = FriendsLoc(json: j) else { return }
            self.friends = self.friends.map { var f = $0; if f.pid == pid { f.loc = loc }; return f }
        })
        tokens.append(s.on("friends:gone") { [weak self] a in
            guard let self, let pid = (a.first as? [String: Any])?["pid"] as? String else { return }
            self.friends = self.friends.map { var f = $0; if f.pid == pid { f.loc = nil }; return f }
        })

        tokens.append(Bus.shared.on { [weak self] e in
            guard let self else { return }
            switch e {
            case .geoTick: self.sendLocation(); self.sendTrip()
            case .driveStart: self.lastSent = .distantPast; self.sendLocation(force: true)
            case .driveRerouted: self.sendTrip(withCoords: true)
            case .driveArrived: self.arrived()
            case .driveStop(let arrived):
                if !arrived, self.trip != nil { Task { await self.stopTrip() } }
                self.lastSent = .distantPast
                self.sendLocation(force: true)
            default: break
            }
        })
        observeSharePref()

        // statut de connexion (le socket du Core ne signale pas les coupures), battement, positions périmées
        Task { [weak self] in
            var tick = 0
            while let self {
                try? await Task.sleep(for: .seconds(5))
                tick += 1
                if !Socket.shared.connected, self.status == .ready {
                    self.status = .off
                    self.friends = self.friends.map { var f = $0; f.online = false; return f }
                }
                if tick % 6 == 0 {
                    let stale = self.friends.contains { ($0.loc?.age ?? 0) > 300 }
                    if stale { self.friends = self.friends.map { var f = $0; if (f.loc?.age ?? 0) > 300 { f.loc = nil }; return f } }
                }
                // le serveur oublie une position au bout de 5 min : on reste visible même immobile
                if tick % 12 == 0 { self.sendLocation() }
            }
        }
    }

    /// Activer / couper le partage (le réglage peut changer depuis n'importe quel écran).
    private func observeSharePref() {
        withObservationTracking { _ = Prefs.shared.shareLocation } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let on = Prefs.shared.shareLocation
                if on != self.sharing {
                    self.sharing = on
                    if on { self.lastSent = .distantPast; self.sendLocation(force: true) }
                    else if self.status == .ready { Socket.shared.emit("friends:loc:stop") }
                }
                self.observeSharePref()
            }
        }
    }

    // MARK: - Réseau

    /// Émet avec accusé de réception ; réponse `{ ok: false }` après 8 s sans nouvelles.
    func call(_ event: String, _ payload: [String: Any]) async -> FriendsReply {
        await withCheckedContinuation { (cont: CheckedContinuation<FriendsReply, Never>) in
            var done = false
            let finish: (FriendsReply) -> Void = { r in
                guard !done else { return }
                done = true
                cont.resume(returning: r)
            }
            Socket.shared.emit(event, payload) { args in
                finish(FriendsReply(args.first as? [String: Any] ?? ["ok": false]))
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                finish(FriendsReply(["ok": false, "error": "Le serveur ne répond pas."]))
            }
        }
    }

    /// Identifiant d'appareil pour les amis : celui du Core, sauf si le module a dû en reprendre un neuf
    /// (secret perdu : restauration sur un autre iPhone, le secret « ThisDeviceOnly » ne suit pas).
    private var deviceId: String { Store.load("friends.deviceId", default: Optional<String>.none) ?? Identity.deviceId }

    private func hello(retry: Bool = true) async {
        status = .connecting
        error = nil
        guard let secret = FriendsKeychain.secret() else {
            status = .error
            error = "Trousseau indisponible pour l'instant. Déverrouille ton iPhone puis réessaie."
            return
        }
        let r = await call("friends:hello", [
            "deviceId": deviceId,
            "secret": secret,
            "name": Identity.nickname,
            "code": Store.load("friends.code", default: Optional<String>.none) ?? Identity.friendCode,
        ])
        if !r.ok, r.error == "secret invalide", retry {
            // cet identifiant appartient à un secret qu'on n'a plus : on repart d'un appareil neuf (amis à réinviter)
            Store.save("friends.deviceId", UUID().uuidString.lowercased())
            FriendsKeychain.reset()
            Store.remove("friends.code")
            await hello(retry: false)
            return
        }
        guard r.ok else {
            status = .error
            error = r.error ?? "Connexion impossible."
            return
        }
        applyState(r.json, notify: false)
        status = .ready
        lastSent = .distantPast
        sendLocation(force: true)
        // invitation arrivée avant la connexion : on la remontre si un autre panneau l'a remplacée entre-temps
        if let code = pendingInvite {
            pendingInvite = nil
            if Core.shared.panel != "friends-invite" { Core.shared.openPanel("friends-invite", data: code) }
        }
    }

    /// Nouvel essai manuel (bouton « Réessayer »).
    func reconnect() { Task { await hello() } }

    private func applyState(_ json: Any?, notify: Bool) {
        guard let j = json as? [String: Any] else { return }
        if let m = j["me"] as? [String: Any], let pid = m["pid"] as? String, let code = m["code"] as? String {
            me = FriendsMe(pid: pid, code: code, name: m["name"] as? String ?? "")
            Store.save("friends.code", code)
        }
        let inc = (j["incoming"] as? [Any] ?? []).compactMap(FriendsRequest.init(json:))
        if notify {
            for r in inc where !prevIncoming.contains(r.pid) {
                emit(.toast(Toast(text: "\(r.name ?? "Quelqu'un") veut t'ajouter en ami", icon: "person.badge.plus")))
                emit(.haptic("light"))
            }
        }
        prevIncoming = Set(inc.map(\.pid))
        incoming = inc
        outgoing = (j["outgoing"] as? [Any] ?? []).compactMap(FriendsRequest.init(json:))
        friends = (j["friends"] as? [Any] ?? []).compactMap(FriendsFriend.init(json:))
    }

    // MARK: - Actions

    func rename(_ name: String) async {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        Identity.nickname = clean
        nickname = clean
        if status == .ready { _ = await call("friends:rename", ["name": clean]) }
    }

    /// Envoie une demande ; renvoie un message d'erreur (en français) ou nil.
    func addFriend(_ code: String) async -> String? {
        let digits = code.filter(\.isNumber)
        let r = await call("friends:add", ["code": digits])
        guard r.ok else { return r.error ?? "Impossible d'envoyer la demande." }
        let accepted = r["accepted"] as? Bool ?? false
        emit(.toast(Toast(text: accepted ? "Vous êtes maintenant amis" : "Demande envoyée", icon: accepted ? "person.2.fill" : "paperplane.fill", tone: .good)))
        emit(.haptic("success"))
        return nil
    }

    func respond(_ pid: String, accept: Bool) async {
        let r = await call("friends:respond", ["pid": pid, "accept": accept])
        if !r.ok { emit(.toast(Toast(text: r.error ?? "Action impossible", tone: .warn))) }
        else if accept { emit(.toast(Toast(text: "Ami ajouté", icon: "person.2.fill", tone: .good))); emit(.haptic("success")) }
    }

    /// Retirer un ami OU annuler une demande envoyée.
    func removeFriend(_ pid: String) async {
        let r = await call("friends:remove", ["pid": pid])
        if !r.ok { emit(.toast(Toast(text: r.error ?? "Action impossible", tone: .warn))) }
    }

    /// « Supprimer mes données » : tout est effacé côté serveur, puis sur l'appareil, puis nouvel enregistrement vierge.
    @discardableResult
    func deleteMyData() async -> Bool {
        if trip != nil { await stopTrip() }
        let r = await call("friends:delete", [:])
        guard r.ok else {
            emit(.toast(Toast(text: r.error ?? "Suppression impossible", tone: .warn)))
            return false
        }
        Prefs.shared.shareLocation = false
        sharing = false
        FriendsKeychain.reset()
        Store.remove("friends.code")
        Store.remove("friends.showDest")
        me = nil; friends = []; incoming = []; outgoing = []; trip = nil; showDest = false
        prevIncoming = []
        emit(.toast(Toast(text: "Tes données d'amis ont été supprimées", icon: "trash", tone: .good)))
        await hello()
        return true
    }

    func setShowDest(_ v: Bool) {
        showDest = v
        Store.save("friends.showDest", v)
        lastSent = .distantPast
        sendLocation(force: true)
    }

    // MARK: - Position en direct

    /// ETA (horodatage ms) de la conduite en cours.
    func myEta() -> Double? {
        let c = Core.shared
        guard c.mode == .drive, let s = c.progress?.remainingTime ?? c.route?.duration else { return nil }
        return (Date().timeIntervalSince1970 + s) * 1000
    }

    private func myRemaining() -> Double? {
        Core.shared.progress?.remainingDistance ?? Core.shared.route?.distance
    }

    private func sendLocation(force: Bool = false) {
        guard status == .ready, Prefs.shared.shareLocation, let p = Core.shared.position else { return }
        let now = Date()
        let moved = lastCoord.map { Geo.distance($0, p.coordinate) } ?? .infinity
        let since = now.timeIntervalSince(lastSent)
        // au plus toutes les 4 s, et seulement si on a bougé de 15 m (ou toutes les 60 s pour rester visible)
        if !force && (since < 4 || (moved < 15 && since < 60)) { return }
        lastSent = now
        lastCoord = p.coordinate
        let c = Core.shared
        var payload: [String: Any] = [
            "lat": p.coordinate.latitude, "lng": p.coordinate.longitude,
            "heading": p.heading.map { $0 as Any } ?? NSNull(),
            "speed": p.speed.map { max(0, $0) as Any } ?? NSNull(),
        ]
        if c.mode == .drive {
            payload["drive"] = showDest
                ? ["to": c.destination?.name as Any? ?? NSNull(), "eta": myEta() as Any? ?? NSNull()]
                : ["to": NSNull(), "eta": NSNull()]
        } else {
            payload["drive"] = NSNull()
        }
        Socket.shared.emit("friends:loc", payload)
    }

    // MARK: - Partage de trajet

    /// Tracé allégé (≤ 400 points) depuis l'endroit où l'on est sur l'itinéraire : [[lng, lat], …].
    private func remainingCoords() -> [[Double]]? {
        guard let r = Core.shared.route, r.coords.count >= 2 else { return nil }
        let rest = Array(r.coords.dropFirst(max(0, min(Core.shared.progress?.shapeIndex ?? 0, r.coords.count - 2))))
        guard rest.count >= 2 else { return nil }
        let step = Int((Double(rest.count) / 400).rounded(.up))
        var out = stride(from: 0, to: rest.count, by: max(1, step)).map { rest[$0] }
        if out.last != rest.last, let l = rest.last { out.append(l) }
        return out.map { [($0.lng * 1e5).rounded() / 1e5, ($0.lat * 1e5).rounded() / 1e5] }
    }

    private func posPayload() -> Any {
        guard let p = Core.shared.position else { return NSNull() }
        return ["lat": p.coordinate.latitude, "lng": p.coordinate.longitude,
                "heading": p.heading.map { $0 as Any } ?? NSNull(),
                "speed": p.speed.map { max(0, $0) as Any } ?? NSNull()]
    }

    /// Texte qui accompagne le lien de suivi.
    var tripMessage: String {
        "Suis mon trajet vers \(Core.shared.destination?.name ?? "ma destination") en direct"
    }

    func startTrip() async -> FriendsSharedTrip? {
        if let trip { return trip }
        let c = Core.shared
        guard c.mode == .drive, let dest = c.destination, let coords = remainingCoords() else {
            emit(.toast(Toast(text: "Lance d'abord un itinéraire", tone: .warn)))
            return nil
        }
        guard status == .ready else {
            emit(.toast(Toast(text: "Pas de connexion au serveur", icon: "wifi.slash", tone: .warn)))
            return nil
        }
        var payload: [String: Any] = [
            "dest": ["name": dest.name, "lat": dest.lat, "lng": dest.lng],
            "coords": coords,
            "pos": posPayload(),
        ]
        if let e = myEta() { payload["eta"] = e }
        if let r = myRemaining() { payload["remaining"] = r }
        let r = await call("friends:trip:start", payload)
        guard r.ok, let token = r["token"] as? String else {
            emit(.toast(Toast(text: r.error ?? "Partage impossible", tone: .warn)))
            return nil
        }
        let t = FriendsSharedTrip(token: token, url: FriendsUtil.webLink("suivre", token),
                                  expiresAt: FriendsJSON.num(r["expiresAt"]) ?? 0, watchers: 0)
        trip = t
        lastTripSent = Date()
        emit(.haptic("success"))
        return t
    }

    func stopTrip() async {
        guard let t = trip else { return }
        trip = nil
        _ = await call("friends:trip:stop", ["token": t.token])
    }

    private func sendTrip(withCoords: Bool = false) {
        guard let t = trip else { return }
        let now = Date()
        if !withCoords && now.timeIntervalSince(lastTripSent) < 2 { return }
        lastTripSent = now
        var payload: [String: Any] = ["token": t.token, "pos": posPayload()]
        if let e = myEta() { payload["eta"] = e }
        if let r = myRemaining() { payload["remaining"] = r }
        if withCoords, let c = remainingCoords() { payload["coords"] = c }
        Task {
            let r = await call("friends:trip:update", payload)
            guard var cur = trip, cur.token == t.token else { return }
            if r.ok, let w = FriendsJSON.num(r["watchers"]), Int(w) != cur.watchers { cur.watchers = Int(w); trip = cur }
            if !r.ok, r.error == "Trajet introuvable." { trip = nil }
        }
    }

    /// « Bien arrivé » : ceux qui suivent le lien le voient tout de suite.
    private func arrived() {
        guard let t = trip else { return }
        Task { _ = await call("friends:trip:arrived", ["token": t.token]) }
        emit(.toast(Toast(text: t.watchers > 0 ? "Tes proches savent que tu es bien arrivé" : "Bien arrivé", icon: "checkmark.circle.fill", tone: .good)))
        trip = nil
        if Core.shared.panel == "share" { Core.shared.openPanel(nil) }
    }

    // MARK: - Liens

    /// osamaps://ami/CODE, osamaps://suivre/JETON (et les mêmes en https ?ami= / ?suivre= si le Core les relaie un jour).
    func handleLink(_ s: String) {
        guard let url = URL(string: s) else { return }
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let path = url.pathComponents.filter { $0 != "/" }
        let isApp = url.scheme == "osamaps"
        let kind = isApp ? url.host() : (q["ami"] != nil ? "ami" : q["suivre"] != nil ? "suivre" : nil)
        switch kind {
        case "ami":
            let code = (isApp ? (path.first ?? q["code"] ?? "") : (q["ami"] ?? "")).filter(\.isNumber)
            guard code.count == 6 else { return }
            if code == me?.code {
                emit(.toast(Toast(text: "C'est ton propre code ami", tone: .info)))
                return
            }
            #if DEBUG
            // tests dans le Simulateur (pas de toucher possible) : osamaps://ami/CODE?test=send envoie la demande
            if q["test"] == "send" {
                Task {
                    for _ in 0..<40 where status != .ready { try? await Task.sleep(for: .milliseconds(250)) }
                    _ = await addFriend(code)
                    Core.shared.openPanel("friends")
                }
                return
            }
            #endif
            if status != .ready { pendingInvite = code }
            Core.shared.openPanel("friends-invite", data: code)
        case "suivre":
            let token = (isApp ? (path.first ?? q["token"] ?? "") : (q["suivre"] ?? "")).lowercased()
            guard token.count == 36, token.allSatisfy({ $0 == "-" || $0.isHexDigit }) else { return }
            FriendsFollow.shared.open(token)
        #if DEBUG
        // tests dans le Simulateur : osamaps://friends-test/fiche?code=CODE, osamaps://friends-test/share
        case "friends-test":
            if path.first == "fiche", let f = friends.first(where: { $0.code == q["code"] }) {
                Core.shared.openPanel("friend", data: f.pid)
            } else if path.first == "share" {
                Task {
                    guard let t = await startTrip() else { return }
                    NSLog("OsaMaps friends: lien de suivi %@", t.url.absoluteString)
                    Core.shared.openPanel("share")
                }
            }
        #endif
        default: break
        }
    }

    /// Lien d'invitation : web (pour tout le monde) + lien app.
    var inviteURL: URL? { me.map { FriendsUtil.webLink("ami", $0.code) } }
    var inviteMessage: String {
        guard let me else { return "" }
        return "Ajoute-moi en ami sur OsaMaps (code \(FriendsUtil.prettyCode(me.code))). Dans l'app : osamaps://ami/\(me.code)"
    }
}
