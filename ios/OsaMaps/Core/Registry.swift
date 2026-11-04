import SwiftUI
import MapKit

/// Emplacements fixes de l'écran où les modules montent leurs vues (mêmes noms que la version web).
enum Slot: String, CaseIterable, Sendable {
    /// Barre du haut en mode exploration (recherche).
    case top
    /// Panneau du bas, empilé (fiche lieu, aperçu d'itinéraire, guidage…).
    case sheet
    /// Boutons ronds sur le bord droit.
    case rail
    /// Affichage de conduite (mode drive).
    case hud
    /// Plein écran par-dessus tout (accueil, toasts, modales).
    case overlay
    /// Sections de l'écran Réglages.
    case settings
}

struct SlotEntry {
    var slot: Slot
    /// Petit = d'abord / en haut.
    var order: Int = 100
    var view: @MainActor () -> AnyView

    init<V: View>(_ slot: Slot, order: Int = 100, @ViewBuilder _ view: @escaping @MainActor () -> V) {
        self.slot = slot
        self.order = order
        self.view = { AnyView(view()) }
    }
}

/// Une fonctionnalité = un dossier `Features/<Id>/` qui expose une valeur `Feature`
/// et l'ajoute dans `Features/Features.swift` (une ligne). Rien d'autre à toucher.
struct Feature {
    var id: String
    var name: String
    var slots: [SlotEntry] = []
    /// Calques de carte (overlays, annotations) — voir `MapLayer`.
    var mapLayers: [MapLayer] = []
    /// Appelé une fois au démarrage, après la création de la carte (abonnements bus, sockets…).
    var start: (@MainActor () -> Void)?
}

@MainActor
enum Registry {
    static private(set) var features: [Feature] = []

    static func register(_ list: [Feature]) {
        for f in list where !features.contains(where: { $0.id == f.id }) { features.append(f) }
    }

    static func entries(_ slot: Slot) -> [(id: String, entry: SlotEntry)] {
        features
            .flatMap { f in f.slots.filter { $0.slot == slot }.map { (id: f.id, entry: $0) } }
            .enumerated()
            .sorted { ($0.element.entry.order, $0.offset) < ($1.element.entry.order, $1.offset) }
            .map(\.element)
    }

    static var layers: [MapLayer] { features.flatMap(\.mapLayers) }
}

/// Vue qui affiche toutes les entrées d'un slot.
struct SlotView: View {
    let slot: Slot
    var body: some View {
        ForEach(Array(Registry.entries(slot).enumerated()), id: \.offset) { _, item in
            item.entry.view()
        }
    }
}
