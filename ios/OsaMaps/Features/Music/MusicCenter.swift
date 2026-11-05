import SwiftUI
import Observation

/// Le chef d'orchestre du module : choisit la source affichée, exécute les commandes, mémorise
/// favoris et playlists récentes, et tient le Bus au courant.
///
/// Contrat Bus (Dynamic Island / Live Activity, autre module) :
///   émet   .custom("music:now", ["title", "artist", "source": "apple"|"spotify", "playing": "1"|"0"]) à chaque changement
///   écoute .custom("music:command", ["action": "toggle"|"next"|"previous"])
@MainActor
@Observable
final class MusicCenter {
    static let shared = MusicCenter()

    let apple = MusicApple()
    let spotify = MusicSpotify()
    #if DEBUG
    /// Fausse source (argument de lancement `-musicTest YES` ou `-musicTest spotify`), Simulateur et tests.
    private(set) var test: MusicTestProvider?
    #endif

    /// Source choisie (affichée en priorité, playlists du panneau).
    var preferred: MusicSource { didSet { Store.save("music.source", preferred) } }
    /// Mini-lecteur au-dessus de la barre de guidage pendant la conduite.
    var miniPlayer: Bool { didSet { Store.save("music.miniPlayer", miniPlayer) } }
    private(set) var favorites: [String] { didSet { Store.save("music.favorites", favorites) } }
    private(set) var recents: [String] { didSet { Store.save("music.recents", recents) } }
    /// Message ponctuel (Premium requis, rien à reprendre…), effacé tout seul.
    var notice: MusicNotice?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastEmitted: [String: String]?
    @ObservationIgnored private var bus: BusToken?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    private init() {
        preferred = Store.load("music.source", default: MusicSource.apple)
        miniPlayer = Store.load("music.miniPlayer", default: true)
        favorites = Store.load("music.favorites", default: [String]())
        recents = Store.load("music.recents", default: [String]())
        #if DEBUG
        if let flag = UserDefaults.standard.string(forKey: "musicTest"), flag != "NO", flag != "0" {
            let src: MusicSource = flag == "spotify" ? .spotify : .apple
            test = MusicTestProvider(source: src)
            preferred = src
        }
        #endif
    }

    func provider(_ s: MusicSource) -> MusicProvider {
        #if DEBUG
        if let test, test.source == s { return test }
        #endif
        return s == .apple ? apple : spotify
    }

    func start() {
        guard !started else { return }
        started = true
        for s in MusicSource.allCases {
            let p = provider(s)
            p.onChange = { [weak self] in self?.changed() }
            p.start()
        }
        bus = Bus.shared.on { [weak self] e in
            guard case .custom(let name, let payload) = e, name == "music:command" else { return }
            switch payload["action"] {
            case "toggle": self?.toggle()
            case "next": self?.next()
            case "previous": self?.previous()
            default: break
            }
        }
        changed()
        #if DEBUG
        test?.startDebugExtras(center: self)
        #endif
    }

    // MARK: - Lecture affichée

    /// Ce qu'on affiche : la source choisie si elle a un morceau, sinon l'autre si elle joue.
    var current: (source: MusicSource, now: MusicNow)? {
        let main = provider(preferred)
        if let n = main.now { return (preferred, n) }
        let other: MusicSource = preferred == .apple ? .spotify : .apple
        if let n = provider(other).now, n.playing { return (other, n) }
        return nil
    }

    /// Le mini-lecteur de conduite est affiché.
    var showsMiniPlayer: Bool { miniPlayer && current != nil }

    private func changed() {
        let c = current
        let payload: [String: String] = [
            "title": c?.now.track.title ?? "",
            "artist": c?.now.track.artist ?? "",
            "source": (c?.source ?? preferred).rawValue,
            "playing": c?.now.playing == true ? "1" : "0",
        ]
        guard payload != lastEmitted else { return }
        lastEmitted = payload
        Bus.shared.emit(.custom(name: "music:now", payload: payload))
    }

    // MARK: - Commandes

    func toggle() { command { try await $0.toggle() } }
    func next() { command { try await $0.next() } }
    func previous() { command { try await $0.previous() } }

    private func command(_ op: @escaping (MusicProvider) async throws -> Void) {
        let src = current?.source ?? preferred
        let p = provider(src)
        Haptic.play("light")
        Task {
            do { try await op(p) } catch { report(error, source: src) }
            changed()
        }
    }

    func play(_ playlist: MusicPlaylist) {
        recents.removeAll { $0 == playlist.id }
        recents.insert(playlist.id, at: 0)
        if recents.count > 8 { recents.removeLast(recents.count - 8) }
        Haptic.play("light")
        let p = provider(playlist.source)
        Task {
            do { try await p.play(playlist) } catch { report(error, source: playlist.source) }
            changed()
        }
    }

    func isFavorite(_ p: MusicPlaylist) -> Bool { favorites.contains(p.id) }

    func toggleFavorite(_ p: MusicPlaylist) {
        Haptic.play("light")
        if let i = favorites.firstIndex(of: p.id) { favorites.remove(at: i) } else { favorites.insert(p.id, at: 0) }
    }

    func refreshAll() async {
        for s in MusicSource.allCases { await provider(s).refresh() }
        changed()
    }

    func open(_ s: MusicSource) {
        UIApplication.shared.open(s.appURL)
    }

    // MARK: - Messages

    func show(_ text: String, open: MusicSource? = nil) {
        notice = MusicNotice(text: text, openSource: open)
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(7))
            if !Task.isCancelled { withAnimation(Osa.anim) { notice = nil } }
        }
    }

    private func report(_ error: Error, source: MusicSource) {
        Haptic.play("warning")
        switch error as? MusicError {
        case .premiumRequired:
            show("Piloter Spotify depuis OsaMaps demande un compte Premium. Tu peux le faire dans Spotify.", open: .spotify)
        case .noActiveDevice:
            show("Spotify ne joue sur aucun appareil. Ouvre Spotify et lance un morceau.", open: .spotify)
        case .notConnected:
            show(source == .apple ? "Autorise l'accès à ta musique dans le panneau Musique."
                                  : "Connecte Spotify dans les réglages Musique pour piloter la lecture.", open: source)
        case .message(let m):
            show(m, open: source)
        case nil:
            show("Pas de réseau : la commande n'est pas passée.", open: source)
        }
    }
}
