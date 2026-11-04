import SwiftUI

/// Guidage tour par tour : progression sur l'itinéraire actif, HUD de manœuvre, voix française,
/// recalcul en cas de sortie de route, étapes, arrivée, vitesse, alertes (`.driveAlert`) et Live Activity.
///
/// Contrat :
///   écoute  .driveStart / .driveStop / .driveAlert / .driveRerouted / .geoTick, et Core.mode/route/routes
///   émet    .routeRecompute(from:) (sortie de route, anti-rebond 12 s), .driveArrived, .driveStop(arrived: true)
///   écrit   Core.progress ; à l'arrêt : mode .browse, routes [], destination nil, follow true
///   lit     Route.maneuvers (type Valhalla, typeName "waypoint" pour une étape, roundaboutExit, lanes),
///           Route.speedLimits (la route peut être remplacée au même id : la progression est gardée)
@MainActor
let guidanceFeature = Feature(
    id: "guidance",
    name: "Guidage",
    slots: [
        SlotEntry(.hud, order: 10) { GuidanceHUD() },
        SlotEntry(.sheet, order: 10) { GuidanceSheet() },
        SlotEntry(.settings, order: 20) { GuidanceSettingsSection() },
    ],
    start: {
        GuidanceEngine.shared.start()
        #if DEBUG
        GuidanceDebug.start()
        #endif
    }
)
