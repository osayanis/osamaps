import SwiftUI

/// Live Activities hors guidage + branchement de la Live Activity de guidage (GuidanceLive) sur le Bus.
///
/// Contrat :
///   écoute  .driveAlert / .driveRerouted / .trafficDelay / .driveArrived → notifications dans la Dynamic Island (GuidanceLive)
///           .custom("music:now", ["title", "artist", "source": "apple"|"spotify", "playing": "1"|"0"]) → morceau affiché
///           .custom("friends:trip", ["token", "name", "dest", "eta" (s depuis 1970, ou ms), "remaining" (m),
///                   "state": "live"|"arrived"|"ended", "stale": "1"|"0"]) → Live Activity « un ami arrive » (LiveFriends)
///   émet    .custom("music:command", ["action": "toggle"|"next"|"previous"]) (boutons de la Live Activity)
///           .driveStop(arrived: false) (bouton Arrêter, via GuidanceEngine)
/// DEBUG : argument de lancement -livePreview YES|2|3 → écran d'aperçu des vues (compact, étendu, écran verrouillé) ;
///         osamaps://live-friend?name=Léa&dest=Gare&in=600&remaining=4200&state=live → Live Activity d'ami de test.
@MainActor
let liveFeature = Feature(
    id: "live",
    name: "Live Activities",
    slots: liveSlots,
    start: {
        GuidanceLive.shared.listen()
        LiveFriends.shared.start()
    }
)

@MainActor
private var liveSlots: [SlotEntry] {
    #if DEBUG
    if UserDefaults.standard.string(forKey: "livePreview") != nil {
        return [SlotEntry(.overlay, order: 999) { LivePreviewScreen() }]
    }
    #endif
    return []
}
