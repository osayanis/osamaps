import Foundation

/// Client socket.io v4 minimal (WebSocket seul, sans dépendance) vers le serveur OsaMaps.
///   Socket.shared.on("reports:new") { args in … }      // args = arguments JSON décodés
///   Socket.shared.emit("reports:watch", ["tiles": […]])
///   Socket.shared.emit("friends:add", ["code": "123456"]) { reply in … }   // avec accusé (ack)
///   Socket.shared.onConnect { … }   // appelé à chaque (re)connexion : renvoie tes « hello »/« watch »
/// Se connecte au premier usage, se reconnecte tout seul (délai croissant).
@MainActor
final class Socket {
    static let shared = Socket()

    private(set) var connected = false
    private var task: URLSessionWebSocketTask?
    private var handlers: [String: [UUID: ([Any]) -> Void]] = [:]
    private var connectHandlers: [UUID: () -> Void] = [:]
    private var acks: [Int: ([Any]) -> Void] = [:]
    private var nextAck = 0
    private var retry = 0
    private var started = false
    private var pendingEmits: [String] = []

    private init() {}

    private var url: URL {
        var c = URLComponents(url: API.siteRoot.appendingPathComponent("maps/socket.io/"), resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.queryItems = [URLQueryItem(name: "EIO", value: "4"), URLQueryItem(name: "transport", value: "websocket")]
        return c.url!
    }

    func start() {
        guard !started else { return }
        started = true
        open()
    }

    @discardableResult
    func on(_ event: String, _ handler: @escaping ([Any]) -> Void) -> BusToken {
        start()
        let id = UUID()
        handlers[event, default: [:]][id] = handler
        return BusToken { [weak self] in self?.handlers[event]?[id] = nil }
    }

    @discardableResult
    func onConnect(_ handler: @escaping () -> Void) -> BusToken {
        start()
        let id = UUID()
        connectHandlers[id] = handler
        if connected { handler() }
        return BusToken { [weak self] in self?.connectHandlers[id] = nil }
    }

    /// Émet un évènement. `data` : tout objet JSON (dictionnaire, tableau, chaîne, nombre) ou nil.
    func emit(_ event: String, _ data: Any? = nil, ack: (([Any]) -> Void)? = nil) {
        start()
        var args: [Any] = [event]
        if let data { args.append(data) }
        guard let json = try? JSONSerialization.data(withJSONObject: args),
              let body = String(data: json, encoding: .utf8) else { return }
        var packet = "42"
        if let ack {
            nextAck += 1
            acks[nextAck] = ack
            packet += String(nextAck)
        }
        packet += body
        if connected { send(packet) } else { pendingEmits.append(packet); if pendingEmits.count > 50 { pendingEmits.removeFirst() } }
    }

    // MARK: - Transport

    private func open() {
        task?.cancel(with: .goingAway, reason: nil)
        let t = API.session.webSocketTask(with: url)
        task = t
        t.resume()
        receive(t)
    }

    private func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, t === self.task else { return }
                switch result {
                case .success(.string(let s)):
                    self.handle(s)
                    self.receive(t)
                case .success:
                    self.receive(t)
                case .failure:
                    self.dropped()
                }
            }
        }
    }

    private func dropped() {
        connected = false
        task = nil
        retry += 1
        let delay = min(30.0, pow(1.6, Double(retry)))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.open()
        }
    }

    private func handle(_ s: String) {
        guard let first = s.first else { return }
        switch first {
        case "0": send("40")                 // engine.io open → connexion au namespace /
        case "2": send("3")                  // ping → pong
        case "1": dropped()                  // close
        case "4": handleSocketIO(String(s.dropFirst()))
        default: break
        }
    }

    private func handleSocketIO(_ s: String) {
        guard let type = s.first else { return }
        var rest = Substring(s.dropFirst())
        switch type {
        case "0": // connecté
            connected = true
            retry = 0
            let queued = pendingEmits; pendingEmits.removeAll()
            for h in Array(connectHandlers.values) { h() }
            for p in queued { send(p) }
        case "1": // déconnecté par le serveur
            connected = false
            dropped()
        case "2", "3":
            let digits = rest.prefix(while: \.isNumber)
            let id = Int(digits)
            rest = rest.dropFirst(digits.count)
            guard let data = rest.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return }
            if type == "3" {
                if let id, let cb = acks.removeValue(forKey: id) { cb(arr) }
                return
            }
            guard let name = arr.first as? String else { return }
            let args = Array(arr.dropFirst())
            for h in Array((handlers[name] ?? [:]).values) { h(args) }
        case "4": // erreur de connexion
            dropped()
        default: break
        }
    }
}
