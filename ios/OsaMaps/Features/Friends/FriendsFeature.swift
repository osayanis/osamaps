import SwiftUI

/// Amis & partage : code ami, demandes, position en direct (opt-in, amis seulement), marqueurs sur la carte,
/// « Rejoindre » / « À mi-chemin », partage de trajet par lien ?suivre=, « bien arrivé », vue de suivi native.
///
/// Panneaux du bas possédés : "friends", "friend", "share", "friends-invite", "friends-follow".
/// Liens gérés (relayés par Links en `.custom(name: "url")`) : osamaps://ami/CODE, osamaps://suivre/JETON.
@MainActor
let friendsFeature: Feature = {
    // un lien d'ouverture peut arriver avant `start` : on écoute le bus dès la construction
    FriendsStore.shared.listenLinks()
    return Feature(
        id: "friends",
        name: "Amis et partage",
        slots: [
            SlotEntry(.rail, order: 40) { FriendsRail() },
            SlotEntry(.sheet, order: 50) { FriendsSheet() },
            SlotEntry(.settings, order: 60) { FriendsSettings() },
        ],
        mapLayers: [FriendsMapLayer.layer, FriendsFollowLayer.layer],
        start: { FriendsStore.shared.start() }
    )
}()
