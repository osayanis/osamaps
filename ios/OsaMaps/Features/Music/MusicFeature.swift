import SwiftUI

/// Musique : Apple Music (lecteur système, bibliothèque) et Spotify (Web API, OAuth PKCE), pilotées sans quitter le GPS.
///
/// Slots :
///   .hud   order 90   mini-lecteur de conduite (sous la manœuvre et les alertes : ne cache ni la mascotte ni la vitesse)
///   .sheet order 60   panneau "music" (source, lecture en cours, playlists, réglages)
///   .rail  order 45   bouton Musique (hors conduite ; en conduite seulement sans mini-lecteur)
///   .settings order 65 section Musique (mini-lecteur, source, Apple Music, Client ID Spotify)
///
/// Bus :
///   émet   .custom("music:now", ["title", "artist", "source": "apple"|"spotify", "playing": "1"|"0"]) à chaque changement
///   écoute .custom("music:command", ["action": "toggle"|"next"|"previous"])
/// Ne touche jamais à la session audio : la voix du guidage baisse la musique comme avant (Voice.swift).
/// Test Simulateur (DEBUG) : -musicTest YES | spotify, -musicTestEmpty YES, -musicTestNotice premium.
@MainActor
let musicFeature = Feature(
    id: "music",
    name: "Musique",
    slots: [
        SlotEntry(.hud, order: 90) { MusicMiniPlayer() },
        SlotEntry(.sheet, order: 60) { MusicSheet() },
        SlotEntry(.rail, order: 45) { MusicRail() },
        SlotEntry(.settings, order: 65) { MusicSettingsSection() },
    ],
    start: { MusicCenter.shared.start() }
)
