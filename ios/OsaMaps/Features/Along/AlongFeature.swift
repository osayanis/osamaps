import SwiftUI

/// Sur le trajet : prix des carburants, bornes de recharge, météo à l'heure de passage, pauses.
/// Données réelles uniquement (flux officiel des carburants, base IRVE, Open-Meteo, OSM), via `/maps/api/along/*`.
///
/// Contrat :
///  panneaux  "along.station" (panelData = AlongStationRef), "along.fuel" (stations du trajet),
///            "along.weather" (météo du trajet). Bandeau discret au-dessus de l'aperçu (sheet, order 5).
///  écoute    driveStart / driveStop / driveArrived / driveRerouted / geoTick.
///  émet      placeGo (« Y aller »), routeAddStop (« Ajouter comme arrêt »), toast,
///            driveAlert (kind "weather" : neige/verglas/orage/pluie forte/brouillard ; kind "pause").
///  lit       core.route, core.mode, core.progress.shapeIndex, core.position.
///  tests     -alongPause 1 (rappel après 1 min), -alongEnergy ev ; DEBUG : osamaps://along-test, osamaps://along-station.
@MainActor
let alongFeature = Feature(
    id: "along",
    name: "Sur le trajet",
    slots: [
        // au-dessus du panneau de routing en aperçu ; seul quand un panneau along.* est ouvert
        SlotEntry(.sheet, order: 5) { AlongSheets() },
        SlotEntry(.settings, order: 40) { AlongSettings() },
    ],
    mapLayers: [AlongLayer.layer],
    start: {
        AlongModel.shared.start()
        #if DEBUG
        AlongDebug.start()
        #endif
    }
)
