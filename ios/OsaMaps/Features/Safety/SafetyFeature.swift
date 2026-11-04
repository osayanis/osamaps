import SwiftUI

/// Sécurité routière : zones de danger (légales : jamais l'emplacement d'un radar), ZFE, virages serrés,
/// passages à niveau, écoles, fatigue de nuit, « Tu es passager ? ».
///
/// Contrat d'intégration :
///  - émet `.driveAlert` (ids « safety-… », kinds : danger-zone, sharp-curve, level-crossing, school-zone, zfe,
///    night-fatigue) une seule fois par élément et par trajet — guidance les affiche/annonce ;
///  - slot `.hud` (order 40) : bandeau « Zone de danger — reste attentif » tant qu'on est dans une zone ;
///  - slot `.sheet` (order 30) : carte ZFE en aperçu, seulement si `core.panel == nil` et utile pour la vignette ;
///  - slot `.overlay` (order 80) : « Tu es passager ? » ; utilitaire par le Bus (voir SafetyPassenger.swift) :
///    `.custom("safety:passenger-check", ["token"])` → `.custom("safety:passenger-answer", ["token", "answer"])` ;
///  - slot `.settings` (order 40) : vignette Crit'Air, types d'alertes, état des données.
@MainActor
let safetyFeature = Feature(
    id: "safety",
    name: "Sécurité routière",
    slots: {
        var s: [SlotEntry] = [
            SlotEntry(.hud, order: 40) { SafetyHud() },
            SlotEntry(.sheet, order: 30) { SafetyZfeCard() },
            SlotEntry(.overlay, order: 80) { SafetyPassengerOverlay() },
            SlotEntry(.settings, order: 40) { SafetySettingsSection() },
        ]
        #if DEBUG
        s.append(SlotEntry(.overlay, order: 99) { SafetyDebugOverlay() })
        #endif
        return s
    }(),
    mapLayers: [SafetyMapController.shared.layer],
    start: {
        SafetyEngine.shared.start()
        SafetyPassenger.shared.start()
        #if DEBUG
        SafetyDebug.start()
        #endif
    }
)
