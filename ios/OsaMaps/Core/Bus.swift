import Foundation
import CoreLocation

/// Évènements entre modules (comme `bus.ts` de la version web) : aucun module n'importe un autre.
enum BusEvent: Sendable {
    /// Une navigation démarre / s'arrête.
    case driveStart(routeId: String)
    case driveStop(arrived: Bool)
    case driveArrived(destinationName: String)
    case driveRerouted(routeId: String)
    /// Nouvelle position (déjà dans `Core.position`).
    case geoTick(Position)
    /// Un lieu est choisi comme destination → le module routing calcule.
    case placeGo(Place)
    /// Ajouter une étape à l'itinéraire en cours (routing).
    case routeAddStop(Place)
    /// Sortie de l'itinéraire : routing recalcule depuis `from`.
    case routeRecompute(from: CLLocationCoordinate2D)
    case mapRecenter
    /// Alerte de conduite (guidance l'affiche et l'annonce une fois par id).
    case driveAlert(DriveAlert)
    /// Retard dû au trafic sur l'itinéraire actif (secondes).
    case trafficDelay(routeId: String, delay: Double, nextJamDistance: Double?)
    case toast(Toast)
    case pointsEarn(amount: Int, reason: String)
    /// Retour haptique : "light", "medium", "success", "warning", "error".
    case haptic(String)
    /// Échappatoire pour un évènement propre à un module (nom préfixé par son id).
    case custom(name: String, payload: [String: String])
}

@MainActor
final class Bus {
    static let shared = Bus()
    private var handlers: [UUID: (BusEvent) -> Void] = [:]

    /// Abonnement ; garder le jeton, et appeler `cancel()` pour se désabonner.
    @discardableResult
    func on(_ handler: @escaping (BusEvent) -> Void) -> BusToken {
        let id = UUID()
        handlers[id] = handler
        return BusToken { [weak self] in self?.handlers[id] = nil }
    }

    func emit(_ event: BusEvent) {
        for h in Array(handlers.values) { h(event) }
    }
}

final class BusToken {
    private let onCancel: () -> Void
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel() }
}

/// Raccourcis.
@MainActor func emit(_ e: BusEvent) { Bus.shared.emit(e) }
