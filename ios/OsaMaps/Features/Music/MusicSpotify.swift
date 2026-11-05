import SwiftUI
import AuthenticationServices
import CryptoKit
import Observation

/// Spotify par la Web API, sans SDK : connexion OAuth « PKCE » (pas de secret dans l'app) dans une
/// `ASWebAuthenticationSession`, jetons dans le trousseau, rafraîchis tout seuls.
/// - Morceau en cours : fonctionne avec un compte gratuit.
/// - Commandes (lecture, pause, suivant…) : Spotify les réserve à Premium (403 → message clair + « Ouvrir Spotify »).
/// - Sans Client ID : mode simple, on ouvre seulement l'app Spotify.
@MainActor
@Observable
final class MusicSpotify: MusicProvider {
    static let redirectURI = "osamaps://spotify-callback"
    private static let scopes = "user-read-currently-playing user-read-playback-state user-modify-playback-state playlist-read-private playlist-read-collaborative"

    let source = MusicSource.spotify
    private(set) var now: MusicNow?
    private(set) var playlists: [MusicPlaylist] = []
    /// Nom du compte connecté (GET /v1/me).
    private(set) var accountName: String?
    /// Connexion en cours / dernier problème de connexion (affiché dans les réglages).
    private(set) var connecting = false
    private(set) var connectError: String?
    @ObservationIgnored var onChange: (() -> Void)?

    /// Client ID de l'app créée par l'utilisateur sur developer.spotify.com (pas un secret).
    var clientId: String {
        didSet {
            let clean = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean != clientId { clientId = clean; return }
            guard clean != oldValue else { return }
            Store.save("music.spotifyClientId", clean)
            // un autre Client ID = une autre app Spotify : les anciens jetons ne valent plus rien
            if tokens != nil { disconnect() }
            onChange?()
        }
    }
    private var tokens: Tokens? {
        didSet {
            if let tokens, let data = try? JSONEncoder().encode(tokens) { MusicKeychain.save("spotify-tokens", data) }
            else if tokens == nil { MusicKeychain.delete("spotify-tokens") }
        }
    }

    @ObservationIgnored private var session: ASWebAuthenticationSession?
    @ObservationIgnored private let anchor = MusicAuthAnchor()
    @ObservationIgnored private var refreshing: Task<Tokens?, Never>?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var backoffUntil = Date.distantPast

    private struct Tokens: Codable {
        var access: String
        var refresh: String
        var expires: Date
    }

    init() {
        clientId = Store.load("music.spotifyClientId", default: "")
        tokens = MusicKeychain.load("spotify-tokens").flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
    }

    /// Format d'un Client ID Spotify : 32 caractères hexadécimaux.
    static func validClientId(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy(\.isHexDigit)
    }

    var status: MusicStatus {
        if !Self.validClientId(clientId) { return .minimal }
        return tokens == nil ? .needsAuth : .ready
    }

    func start() {
        startPolling()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.refresh() } }
        }
        if status == .ready { Task { await loadAccount(); await refresh() } }
    }

    // MARK: - Connexion (OAuth PKCE)

    func connect() {
        guard Self.validClientId(clientId), !connecting else { return }
        connectError = nil
        connecting = true
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(16)
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientId),
            .init(name: "scope", value: Self.scopes),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
        ]
        let handler: (URL?, Error?) -> Void = { [weak self] url, error in
            Task { @MainActor in await self?.finishConnect(url: url, error: error, verifier: verifier, state: state) }
        }
        let s: ASWebAuthenticationSession
        if #available(iOS 17.4, *) {
            s = ASWebAuthenticationSession(url: c.url!, callback: .customScheme("osamaps"), completionHandler: handler)
        } else {
            s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: "osamaps", completionHandler: handler)
        }
        s.presentationContextProvider = anchor
        session = s
        if !s.start() {
            connecting = false
            connectError = "Impossible d'ouvrir la page de connexion Spotify."
        }
    }

    private func finishConnect(url: URL?, error: Error?, verifier: String, state: String) async {
        session = nil
        defer { connecting = false; onChange?() }
        if let error {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                connectError = "Connexion annulée. Si Spotify affichait une erreur, vérifie le Client ID et la Redirect URI."
            } else {
                connectError = "Connexion impossible : \(error.localizedDescription)"
            }
            return
        }
        let q = URLComponents(url: url ?? URL(string: "osamaps://")!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ k: String) -> String? { q.first { $0.name == k }?.value }
        if let e = value("error") {
            connectError = e == "access_denied" ? "Tu as refusé l'accès dans Spotify." : "Spotify a refusé la connexion (\(e))."
            return
        }
        guard value("state") == state, let code = value("code") else {
            connectError = "Réponse de Spotify inattendue, réessaie."
            return
        }
        do {
            tokens = try await tokenRequest(["grant_type": "authorization_code", "code": code,
                                             "redirect_uri": Self.redirectURI, "client_id": clientId,
                                             "code_verifier": verifier], previousRefresh: nil)
            Haptic.play("success")
            await loadAccount()
            await refresh()
            await loadPlaylists()
        } catch MusicError.message(let m) {
            connectError = m
        } catch {
            connectError = "Connexion impossible, vérifie le réseau."
        }
    }

    func disconnect() {
        tokens = nil
        now = nil
        playlists = []
        accountName = nil
        connectError = nil
        onChange?()
    }

    private func tokenRequest(_ params: [String: String], previousRefresh: String?) async throws -> Tokens {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        struct R: Decodable { let access_token: String?; let refresh_token: String?; let expires_in: Double?; let error: String?; let error_description: String? }
        let r = try? JSONDecoder().decode(R.self, from: data)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let access = r?.access_token else {
            switch r?.error {
            case "invalid_client": throw MusicError.message("Spotify ne reconnaît pas ce Client ID.")
            case "invalid_grant": throw MusicError.notConnected
            default: throw MusicError.message("Spotify a refusé la connexion\(r?.error_description.map { " (\($0))" } ?? "").")
            }
        }
        guard let refresh = r?.refresh_token ?? previousRefresh else { throw MusicError.message("Spotify n'a pas renvoyé de jeton de rafraîchissement.") }
        return Tokens(access: access, refresh: refresh, expires: .now.addingTimeInterval((r?.expires_in ?? 3600) - 60))
    }

    /// Un jeton valide (rafraîchi si besoin ; une seule requête de rafraîchissement à la fois).
    private func accessToken(force: Bool = false) async throws -> String {
        guard let t = tokens else { throw MusicError.notConnected }
        if !force && t.expires > .now { return t.access }
        if refreshing == nil {
            let clientId = clientId
            refreshing = Task { [weak self] in
                guard let self else { return nil }
                do {
                    return try await self.tokenRequest(["grant_type": "refresh_token", "refresh_token": t.refresh, "client_id": clientId],
                                                       previousRefresh: t.refresh)
                } catch MusicError.notConnected {
                    // jeton révoqué (accès retiré dans le compte Spotify…) : il faut se reconnecter
                    self.disconnect()
                    self.connectError = "La connexion à Spotify a expiré, reconnecte-toi."
                    return nil
                } catch { return nil }
            }
        }
        let fresh = await refreshing?.value
        refreshing = nil
        guard let fresh else { throw MusicError.notConnected }
        tokens = fresh
        return fresh.access
    }

    // MARK: - Web API

    private func api(_ method: String, _ path: String, body: [String: Any]? = nil, retry: Bool = true) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
        req.httpMethod = method
        req.timeoutInterval = 12
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        } else if method != "GET" {
            req.setValue("0", forHTTPHeaderField: "Content-Length")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 && retry {
            _ = try await accessToken(force: true)
            return try await api(method, path, body: body, retry: false)
        }
        if code == 429 {
            let wait = Double((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 10
            backoffUntil = .now.addingTimeInterval(wait)
        }
        return (data, code)
    }

    private func tryAPI(_ method: String, _ path: String) async -> (Data, Int)? {
        try? await api(method, path)
    }

    /// Commande du lecteur : 2xx = ok ; 403 = Premium requis ; 404 = aucun appareil actif.
    private func command(_ method: String, _ path: String, body: [String: Any]? = nil) async throws {
        guard status == .ready else { throw MusicError.notConnected }
        let (data, code) = try await api(method, path, body: body)
        switch code {
        case 200..<300: break
        case 403:
            let text = String(decoding: data, as: UTF8.self)
            if text.contains("PREMIUM_REQUIRED") || text.localizedCaseInsensitiveContains("premium") || text.isEmpty {
                throw MusicError.premiumRequired
            }
            throw MusicError.message("Spotify refuse cette commande pour ce morceau.")
        case 404: throw MusicError.noActiveDevice
        case 429: throw MusicError.message("Spotify est saturé, réessaie dans un instant.")
        default: throw MusicError.message("Spotify ne répond pas (\(code)).")
        }
        // Spotify met un court instant à appliquer la commande
        try? await Task.sleep(for: .milliseconds(450))
        await refresh()
    }

    func toggle() async throws {
        if now?.playing == true {
            try await command("PUT", "/me/player/pause")
        } else {
            try await command("PUT", "/me/player/play")
        }
    }

    func next() async throws { try await command("POST", "/me/player/next") }

    func previous() async throws { try await command("POST", "/me/player/previous") }

    func play(_ playlist: MusicPlaylist) async throws {
        guard let uri = playlist.uri else { return }
        do {
            try await command("PUT", "/me/player/play", body: ["context_uri": uri])
        } catch MusicError.premiumRequired, MusicError.noActiveDevice, MusicError.notConnected {
            // sans Premium (ou Spotify fermé) : on ouvre la playlist dans l'app Spotify, qui sait la jouer
            if let url = URL(string: uri) { await UIApplication.shared.open(url) }
        }
    }

    func refresh() async {
        guard status == .ready, Date.now > backoffUntil else { return }
        guard let res = await tryAPI("GET", "/me/player/currently-playing?additional_types=episode") else { return }
        let (data, code) = res
        var next: MusicNow?
        if code == 200, let r = try? JSONDecoder().decode(SPNow.self, from: data), let item = r.item {
            let images = item.album?.images ?? item.images ?? item.show?.images ?? []
            let track = MusicTrack(id: item.id ?? item.uri ?? item.name ?? "?",
                                   title: item.name ?? "Sans titre",
                                   artist: item.artists?.compactMap(\.name).joined(separator: ", ") ?? item.show?.name ?? "",
                                   album: item.album?.name ?? "",
                                   artwork: Self.bestImage(images).map(MusicArtwork.url),
                                   duration: Double(item.duration_ms ?? 0) / 1000)
            next = MusicNow(track: track, playing: r.is_playing ?? false, position: Double(r.progress_ms ?? 0) / 1000)
        } else if code != 204 && code != 200 {
            return // erreur passagère : on garde l'état connu
        }
        let changed = next?.track != now?.track || next?.playing != now?.playing
        now = next
        if changed { onChange?() }
    }

    func loadPlaylists() async {
        guard status == .ready, let res = await tryAPI("GET", "/me/playlists?limit=50"), res.1 == 200,
              let r = try? JSONDecoder().decode(SPPage.self, from: res.0) else { return }
        playlists = (r.items ?? []).compactMap { $0 }.compactMap { p in
            guard let id = p.id else { return nil }
            return MusicPlaylist(id: "spotify:\(id)", source: .spotify, name: p.name ?? "Playlist",
                                 count: p.tracks?.total ?? p.items?.total,
                                 artwork: Self.bestImage(p.images ?? []).map(MusicArtwork.url),
                                 uri: p.uri ?? "spotify:playlist:\(id)")
        }
    }

    private func loadAccount() async {
        guard let res = await tryAPI("GET", "/me"), res.1 == 200 else { return }
        struct Me: Decodable { let display_name: String?; let id: String? }
        let me = try? JSONDecoder().decode(Me.self, from: res.0)
        accountName = me?.display_name ?? me?.id
    }

    // MARK: - Mise à jour régulière

    /// Spotify ne prévient pas : on relit le morceau toutes les 5 s (app au premier plan) ou 12 s
    /// (en arrière-plan pendant la conduite, pour la Dynamic Island) ; rien sinon.
    private func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                let active = UIApplication.shared.applicationState == .active
                let wait: Double = active ? 5 : 12
                try? await Task.sleep(for: .seconds(wait))
                guard let self else { return }
                if self.status == .ready && (active || Core.shared.mode == .drive) { await self.refresh() }
            }
        }
    }

    // MARK: - Outils

    private static func bestImage(_ images: [SPImage]) -> URL? {
        let sorted = images.sorted { abs(($0.width ?? 300) - 300) < abs(($1.width ?? 300) - 300) }
        return sorted.first?.url.flatMap(URL.init(string:))
    }

    private static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return String(bytes.map { chars[Int($0) % chars.count] })
    }

    private struct SPImage: Decodable { let url: String?; let width: Int? }
    private struct SPName: Decodable { let name: String? }
    private struct SPShow: Decodable { let name: String?; let images: [SPImage]? }
    private struct SPAlbum: Decodable { let name: String?; let images: [SPImage]? }
    private struct SPItem: Decodable {
        let id: String?; let uri: String?; let name: String?; let duration_ms: Int?
        let artists: [SPName]?; let album: SPAlbum?; let images: [SPImage]?; let show: SPShow?
    }
    private struct SPNow: Decodable { let is_playing: Bool?; let progress_ms: Int?; let item: SPItem? }
    private struct SPTotal: Decodable { let total: Int? }
    private struct SPPlaylist: Decodable {
        let id: String?; let name: String?; let uri: String?; let images: [SPImage]?
        // `tracks` historiquement, `items` depuis les changements de 2026 : on lit les deux
        let tracks: SPTotal?; let items: SPTotal?
    }
    private struct SPPage: Decodable { let items: [SPPlaylist?]? }
}

/// Fenêtre où présenter la page de connexion Spotify.
final class MusicAuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return key }
            if let scene = scenes.first { return UIWindow(windowScene: scene) }
            return ASPresentationAnchor()
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
