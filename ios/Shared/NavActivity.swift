import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Live Activity de guidage (écran verrouillé + Dynamic Island), partagée entre l'app et l'extension.
/// Démarrée/mise à jour par le module guidance (Activity.request / update), affichée par OsaMapsLive.
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
        /// Ajouts du module guidance (valeurs par défaut : compatibles avec l'ancien contenu).
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
    }

    var destinationName: String
}
#endif
