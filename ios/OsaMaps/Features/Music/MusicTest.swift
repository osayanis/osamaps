#if DEBUG
import SwiftUI
import Observation

/// Fausse source de musique pour le Simulateur (qui n'a ni Musique ni Spotify) — DEBUG uniquement.
///   -musicTest YES | spotify     faux morceaux (source Apple Music ou Spotify)
///   -musicTestEmpty YES          source prête, mais rien en cours de lecture (état vide)
///   -musicTestNotice premium     affiche le message « Premium requis » au démarrage
@MainActor
@Observable
final class MusicTestProvider: MusicProvider {
    let source: MusicSource
    let status = MusicStatus.ready
    private(set) var now: MusicNow?
    private(set) var playlists: [MusicPlaylist] = []
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var index = 0

    private static let tracks: [(String, String, String, Double, Double)] = [
        ("Lumières de l'A71", "Les Phares", "Nationale 7", 214, 0.58),
        ("Aire de repos", "Clara Dune", "Kilomètres", 187, 0.08),
        ("Rond-point au soleil", "Vichy Club", "Été indien", 243, 0.92),
    ]

    init(source: MusicSource) {
        self.source = source
        if !UserDefaults.standard.bool(forKey: "musicTestEmpty") { load(0, playing: true) }
        playlists = [
            ("Route du soir", 42, 0.62), ("Favoris de conduite", 87, 0.12), ("Calme", 23, 0.45),
            ("Années 80", 120, 0.97), ("Découvertes", 30, 0.75), ("Podcast trajet", 12, 0.3),
        ].enumerated().map { i, p in
            MusicPlaylist(id: "\(source.rawValue):test\(i)", source: source, name: p.0, count: p.1,
                          artwork: .image(Self.cover(hue: p.2, size: 120)), uri: "spotify:playlist:test\(i)")
        }
    }

    private func load(_ i: Int, playing: Bool) {
        index = (i + Self.tracks.count) % Self.tracks.count
        let t = Self.tracks[index]
        now = MusicNow(track: MusicTrack(id: "test\(index)", title: t.0, artist: t.1, album: t.2,
                                         artwork: .image(Self.cover(hue: t.4, size: 300)), duration: t.3),
                       playing: playing, position: 64)
        onChange?()
    }

    func start() {}
    func refresh() async {}
    func loadPlaylists() async {}

    func toggle() async throws {
        guard var n = now else { load(0, playing: true); return }
        n.position = n.position(now: .now)
        n.at = .now
        n.playing.toggle()
        now = n
        onChange?()
    }

    func next() async throws { load(index + 1, playing: true) }
    func previous() async throws { load(index - 1, playing: true) }
    func play(_ playlist: MusicPlaylist) async throws { load(index + 1, playing: true) }

    func startDebugExtras(center: MusicCenter) {
        if UserDefaults.standard.string(forKey: "musicTestNotice") == "premium" {
            Task {
                // après le démarrage de la conduite des captures (go, puis drive)
                try? await Task.sleep(for: .seconds(9))
                center.show("Piloter Spotify depuis OsaMaps demande un compte Premium. Tu peux le faire dans Spotify.",
                            short: "Premium requis pour piloter Spotify", open: .spotify)
            }
        }
    }

    /// Pochette générée : dégradé sobre + note de musique.
    static func cover(hue: Double, size: CGFloat) -> UIImage {
        let r = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return r.image { ctx in
            let c1 = UIColor(hue: hue, saturation: 0.55, brightness: 0.75, alpha: 1)
            let c2 = UIColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.3, alpha: 1)
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c1.cgColor, c2.cgColor] as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: size, y: size), options: [])
            let cfg = UIImage.SymbolConfiguration(pointSize: size * 0.34, weight: .bold)
            if let note = UIImage(systemName: "music.note", withConfiguration: cfg)?.withTintColor(.white.withAlphaComponent(0.85), renderingMode: .alwaysOriginal) {
                note.draw(at: CGPoint(x: (size - note.size.width) / 2, y: (size - note.size.height) / 2))
            }
        }
    }
}
#endif
