import Foundation

/// Appels au serveur OsaMaps (le même que la version web, déjà en ligne) :
/// `try await API.get("reports?bbox=…")` → https://osalabs.fr/maps/api/reports?bbox=…
/// Les routes disponibles sont dans `server/features/*.js` (lis-les : c'est le contrat).
enum API {
    /// Surcharge possible pour tester contre un serveur local : argument de lancement `-api http://localhost:3005/maps/api/`.
    static var base: URL = {
        if let s = UserDefaults.standard.string(forKey: "api"), let u = URL(string: s) { return u }
        return URL(string: "https://osalabs.fr/maps/api/")!
    }()

    /// Racine du site (socket.io : https://osalabs.fr/maps/socket.io/).
    static var siteRoot: URL { base.deletingLastPathComponent().deletingLastPathComponent() }

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 90   // plafond ; le délai réel est posé par requête (20 s par défaut)
        c.httpAdditionalHeaders = ["User-Agent": "OsaMaps-iOS/0.1"]
        return URLSession(configuration: c)
    }()

    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()

    struct HTTPError: LocalizedError {
        var status: Int
        var message: String
        var errorDescription: String? { "\(status) \(message)" }
    }

    /// Délai par défaut d'une requête. Les routes du serveur qui attendent un service externe lent
    /// (Overpass…) passent `timeout:` plus long (ex. 60).
    static let defaultTimeout: TimeInterval = 20

    static func get<T: Decodable>(_ path: String, as: T.Type = T.self, timeout: TimeInterval? = nil) async throws -> T {
        try await send(URLRequest(url: url(path), timeoutInterval: timeout ?? defaultTimeout))
    }

    static func post<T: Decodable, B: Encodable>(_ path: String, body: B, as: T.Type = T.self, timeout: TimeInterval? = nil) async throws -> T {
        var r = URLRequest(url: url(path), timeoutInterval: timeout ?? defaultTimeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try encoder.encode(body)
        return try await send(r)
    }

    /// Variante sans type : renvoie le JSON brut (dictionnaire/tableau).
    static func json(_ path: String, method: String = "GET", body: Any? = nil, timeout: TimeInterval? = nil) async throws -> Any {
        var r = URLRequest(url: url(path), timeoutInterval: timeout ?? defaultTimeout)
        r.httpMethod = method
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await session.data(for: r)
        try check(resp, data)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Requête vers un service externe (Valhalla, IGN, Photon, Open-Meteo…) avec le même User-Agent.
    static func external<T: Decodable>(_ url: URL, as: T.Type = T.self, timeout: TimeInterval? = nil) async throws -> T {
        try await send(URLRequest(url: url, timeoutInterval: timeout ?? defaultTimeout))
    }

    private static func url(_ path: String) -> URL {
        URL(string: path, relativeTo: base)!.absoluteURL
    }

    private static func send<T: Decodable>(_ r: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: r)
        try check(resp, data)
        return try decoder.decode(T.self, from: data)
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let h = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(h.statusCode) else {
            throw HTTPError(status: h.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
    }
}

/// Services externes gratuits (vérifiés le 4 nov. 2026) — respecte-les : cache, pas de rafales.
enum External {
    static let valhalla = URL(string: "https://valhalla1.openstreetmap.de")!
    static let geocodeFr = URL(string: "https://data.geopf.fr/geocodage")!
    static let photon = URL(string: "https://photon.komoot.io")!
    static let weather = URL(string: "https://api.open-meteo.com/v1/forecast")!
}
