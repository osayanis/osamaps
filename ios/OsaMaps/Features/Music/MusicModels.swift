import SwiftUI

/// D'où vient la musique.
enum MusicSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple, spotify
    var id: String { rawValue }
    var label: String { self == .apple ? "Apple Music" : "Spotify" }
    /// Lien d'ouverture de l'app (déclarés dans LSApplicationQueriesSchemes).
    var appURL: URL { URL(string: self == .apple ? "music://" : "spotify:")! }
}

/// Pochette : image locale (Apple Music, bibliothèque) ou adresse web (Spotify).
enum MusicArtwork: Equatable {
    case image(UIImage)
    case url(URL)
}

/// Le morceau en cours.
struct MusicTrack: Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String = ""
    var artwork: MusicArtwork?
    /// Durée (s), 0 si inconnue.
    var duration: Double = 0
}

/// Lecture en cours d'une source : morceau, état, position (pour la barre de progression).
struct MusicNow: Equatable {
    var track: MusicTrack
    var playing: Bool
    /// Position (s) au moment `at`.
    var position: Double = 0
    var at: Date = .now

    /// Position estimée maintenant (avance toute seule pendant la lecture).
    func position(now: Date) -> Double {
        let p = playing ? position + now.timeIntervalSince(at) : position
        return track.duration > 0 ? min(max(0, p), track.duration) : max(0, p)
    }
}

/// Une playlist de la bibliothèque (Apple) ou du compte (Spotify).
struct MusicPlaylist: Identifiable, Equatable {
    /// "apple:<persistentID>" ou "spotify:<id>".
    var id: String
    var source: MusicSource
    var name: String
    var count: Int?
    var artwork: MusicArtwork?
    /// Spotify : `spotify:playlist:…` (lecture via l'API ou ouverture de l'app).
    var uri: String?
}

/// État d'une source, pour savoir quoi afficher.
enum MusicStatus: Equatable {
    /// Prête (autorisée / connectée).
    case ready
    /// Accès à demander (Apple : autorisation ; Spotify : connexion).
    case needsAuth
    /// Spotify sans Client ID : on peut seulement ouvrir l'app.
    case minimal
    /// Refusé ou indisponible, avec l'explication.
    case unavailable(String)
}

/// Message ponctuel (Premium requis, aucun appareil actif…), avec éventuellement un bouton « Ouvrir … ».
struct MusicNotice: Equatable, Identifiable {
    var id = UUID()
    var text: String
    /// Version courte pour le mini-lecteur de conduite (lisible d'un coup d'œil).
    var short: String?
    var openSource: MusicSource?
}

/// Erreurs remontées par une source lors d'une commande.
enum MusicError: Error {
    /// Spotify : les commandes à distance demandent Premium (403).
    case premiumRequired
    /// Spotify : aucun appareil actif (404 NO_ACTIVE_DEVICE).
    case noActiveDevice
    /// Pas connecté / pas autorisé.
    case notConnected
    /// Autre problème, déjà formulé en français.
    case message(String)
}

/// Une source de musique (Apple Music, Spotify, ou la fausse source de test DEBUG).
@MainActor
protocol MusicProvider: AnyObject {
    var source: MusicSource { get }
    var status: MusicStatus { get }
    var now: MusicNow? { get }
    var playlists: [MusicPlaylist] { get }
    /// Appelé à chaque changement (morceau, lecture, état) : le centre recalcule et prévient le Bus.
    var onChange: (() -> Void)? { get set }

    func start()
    /// Relit la lecture en cours (au retour au premier plan, après une commande…).
    func refresh() async
    func loadPlaylists() async
    func toggle() async throws
    func next() async throws
    func previous() async throws
    func play(_ playlist: MusicPlaylist) async throws
}
