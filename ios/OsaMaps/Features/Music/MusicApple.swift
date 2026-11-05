import MediaPlayer
import Observation

/// Apple Music sans compte développeur : le lecteur système (`MPMusicPlayerController.systemMusicPlayer`)
/// pilote l'app Musique elle-même (lecture en cours, commandes) et `MPMediaQuery` lit les playlists de la bibliothèque.
/// Rien ne touche à la session audio : la musique joue dans l'app Musique, et la voix du guidage la baisse
/// (ducking de Voice.swift) comme n'importe quelle autre app.
@MainActor
@Observable
final class MusicApple: MusicProvider {
    let source = MusicSource.apple
    private(set) var status: MusicStatus
    private(set) var now: MusicNow?
    private(set) var playlists: [MusicPlaylist] = []
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var attached = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var artworkCache: (id: String, image: UIImage?)?
    private var player: MPMusicPlayerController { .systemMusicPlayer }

    init() { status = Self.status(MPMediaLibrary.authorizationStatus()) }

    private static func status(_ s: MPMediaLibraryAuthorizationStatus) -> MusicStatus {
        switch s {
        case .authorized: .ready
        case .notDetermined: .needsAuth
        case .denied: .unavailable("Accès refusé. Autorise OsaMaps dans Réglages › Apps › OsaMaps › Médias et Apple Music.")
        case .restricted: .unavailable("L'accès à la musique est restreint sur cet iPhone.")
        @unknown default: .needsAuth
        }
    }

    func start() {
        // la demande d'autorisation n'est faite que sur un geste (panneau Musique), jamais au lancement
        if status == .ready { attach() }
    }

    /// Demande l'accès à la bibliothèque (bouton « Autoriser » du panneau).
    func requestAccess() async {
        let s = await withCheckedContinuation { (c: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
            MPMediaLibrary.requestAuthorization { c.resume(returning: $0) }
        }
        status = Self.status(s)
        if status == .ready {
            attach()
            await loadPlaylists()
        }
        onChange?()
    }

    private func attach() {
        guard !attached else { return }
        attached = true
        player.beginGeneratingPlaybackNotifications()
        let nc = NotificationCenter.default
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange, .MPMusicPlayerControllerPlaybackStateDidChange] {
            observers.append(nc.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.read() }
            })
        }
        read()
    }

    /// Relit le lecteur système.
    private func read() {
        guard status == .ready else { return }
        guard let item = player.nowPlayingItem else {
            if now != nil { now = nil; onChange?() }
            return
        }
        let id = String(item.persistentID)
        if artworkCache?.id != id {
            artworkCache = (id, item.artwork?.image(at: CGSize(width: 300, height: 300)))
        }
        let t = player.currentPlaybackTime
        let track = MusicTrack(id: id,
                               title: item.title ?? "Sans titre",
                               artist: item.artist ?? item.albumArtist ?? "",
                               album: item.albumTitle ?? "",
                               artwork: artworkCache?.image.map(MusicArtwork.image),
                               duration: item.playbackDuration)
        let next = MusicNow(track: track, playing: player.playbackState == .playing, position: t.isFinite ? t : 0)
        // la position seule ne compte pas comme un changement (elle avance toute seule)
        if next.track != now?.track || next.playing != now?.playing {
            now = next
            onChange?()
        } else {
            now = next
        }
    }

    func refresh() async { read() }

    func loadPlaylists() async {
        guard status == .ready else { playlists = []; return }
        let all = (MPMediaQuery.playlists().collections as? [MPMediaPlaylist]) ?? []
        playlists = all.filter { $0.count > 0 }.map { p in
            MusicPlaylist(id: "apple:\(p.persistentID)", source: .apple, name: p.name ?? "Playlist", count: p.count,
                          artwork: p.representativeItem?.artwork?.image(at: CGSize(width: 120, height: 120)).map(MusicArtwork.image))
        }
    }

    func toggle() async throws {
        guard status == .ready else { throw MusicError.notConnected }
        if player.playbackState == .playing {
            player.pause()
        } else {
            guard player.nowPlayingItem != nil else {
                throw MusicError.message("Rien à reprendre : choisis une playlist ou lance un morceau dans Musique.")
            }
            player.play()
        }
        await settle()
    }

    func next() async throws {
        guard status == .ready else { throw MusicError.notConnected }
        player.skipToNextItem()
        await settle()
    }

    func previous() async throws {
        guard status == .ready else { throw MusicError.notConnected }
        // comme partout : au début du morceau → précédent ; sinon on revient au début
        if player.currentPlaybackTime > 3 { player.skipToBeginning() } else { player.skipToPreviousItem() }
        await settle()
    }

    func play(_ playlist: MusicPlaylist) async throws {
        guard status == .ready else { throw MusicError.notConnected }
        guard let pid = UInt64(playlist.id.replacingOccurrences(of: "apple:", with: "")) else { return }
        let q = MPMediaQuery.playlists()
        q.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: pid), forProperty: MPMediaPlaylistPropertyPersistentID))
        player.setQueue(with: q)
        player.play()
        await settle()
    }

    /// Les notifications du lecteur système arrivent parfois en retard : on relit peu après la commande.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(350))
        read()
    }
}
