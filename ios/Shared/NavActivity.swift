import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Live Activity de guidage (écran verrouillé + Dynamic Island), partagée entre l'app et l'extension.
/// Démarrée / mise à jour par GuidanceLive (app, en local : pas de push APNs), affichée par OsaMapsLive.
/// Tous les champs ajoutés ont une valeur par défaut (le moteur de guidage construit l'état avec l'init de base).
struct NavActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Distance jusqu'à la prochaine manœuvre (m).
        var distance: Double
        /// Texte court (« Tournez à droite », « 2e sortie »).
        var instruction: String
        var street: String?
        /// Nom de symbole SF de la flèche (ex. "arrow.turn.up.right").
        var symbol: String
        /// Heure d'arrivée.
        var eta: Date
        /// Mètres restants.
        var remaining: Double
        /// Alerte en cours (« Police signalée »), si besoin.
        var alert: String?
        var arrived: Bool = false
        /// Forme de la flèche dessinée : valeur brute de GuidanceKind (« right », « roundabout »…).
        var kind: String = "straight"
        /// Rond-point : numéro de sortie.
        var exit: Int? = nil
        /// Ton de l'alerte : "info", "warn", "danger", "police".
        var alertTone: String? = nil
        /// Mètres jusqu'à l'alerte (nil = sans distance).
        var alertDistance: Double? = nil
        /// Part du trajet effectuée (0…1).
        var progress: Double = 0
        /// Manœuvre imminente (affichage inversé, comme le HUD).
        var imminent: Bool = false

        // — Ajouts Live (remplis par GuidanceLive, pas par le moteur) —

        /// Symbole SF de l'alerte en cours (police, travaux, bouchon…).
        var alertSymbol: String? = nil
        /// Notification brève en cours (la Dynamic Island s'ouvre en grand) : "alert", "reroute", "traffic", "arrival".
        var bannerKind: String? = nil
        var bannerTitle: String? = nil
        var bannerDetail: String? = nil
        /// "police", "danger", "warn", "info", "ok".
        var bannerTone: String? = nil
        var bannerSymbol: String? = nil
        /// Distance qui décompte (alerte), en mètres.
        var bannerDistance: Double? = nil
        /// Texte court à droite de la pastille compacte (« +6 min », « 14:32 »), si pas de distance.
        var bannerShort: String? = nil
        /// Retard dû au trafic sur le reste du trajet (s).
        var delay: Double = 0
        /// Morceau en cours (contrat « music:now » de l'agent musique).
        var musicTitle: String? = nil
        var musicArtist: String? = nil
        /// "apple" ou "spotify".
        var musicSource: String? = nil
        var musicPlaying: Bool = false
        /// Voix du guidage active (icône du bouton « Couper la voix »).
        var voiceOn: Bool = true
    }

    var destinationName: String
}

/// Live Activity « un ami arrive » (suivi d'un trajet partagé, hors conduite).
struct FriendActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Nom de la destination de l'ami.
        var destination: String
        var eta: Date?
        /// Mètres restants.
        var remaining: Double?
        /// Part du trajet effectuée (0…1), estimée depuis le premier « reste » reçu.
        var progress: Double = 0
        var arrived: Bool = false
        /// Plus de position depuis un moment.
        var stale: Bool = false
    }

    /// Prénom / pseudo de l'ami.
    var name: String
    var token: String
}
#endif
