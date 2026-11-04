import SwiftUI

/// La mascotte Osa au volant : « ma position » sur la carte, points, niveaux, badges, accessoires,
/// statistiques de trajet (panneau "trip-summary") et profil (panneau "profile").
@MainActor
let mascotFeature = Feature(
    id: "mascot",
    name: "Mascotte et progression",
    slots: [
        SlotEntry(.rail, order: 5) { MascotRailButton() },
        SlotEntry(.sheet, order: 60) { MascotSheet() },
        SlotEntry(.settings, order: 70) { MascotSettingsSection() },
    ],
    mapLayers: [MascotPin.shared.layer],
    start: { MascotEngine.shared.start() }
)
