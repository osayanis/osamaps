import SwiftUI

/// Itinéraires : calcul (Valhalla via le serveur OsaMaps), alternatives, aperçu, étapes, départ différé,
/// recalcul en conduite, limites de vitesse le long du tracé. Le guidage tour par tour est au module guidance.
/// Contrat détaillé : voir `RoutingModel`.
@MainActor
let routingFeature = Feature(
    id: "routing",
    name: "Itinéraires",
    slots: [
        SlotEntry(.sheet, order: 20) { RoutingSheet() },
        SlotEntry(.settings, order: 20) { RoutingSettings() },
    ],
    mapLayers: [RoutingMapController.shared.layer],
    start: { RoutingModel.shared.start() }
)
