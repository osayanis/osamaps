import MapKit
import UIKit

/// Un calque de carte fourni par un module. La carte est un `MKMapView` (UIKit) partagé :
/// chaque module y ajoute SES overlays/annotations et fournit leurs rendus.
///
/// Règles :
/// - marque tes objets pour les reconnaître : sous-classe propre (`final class ReportAnnotation: MKPointAnnotation`)
///   ou `title`/`subtitle` préfixés par ton id ;
/// - `renderer` / `annotationView` : renvoie nil si l'objet n'est pas à toi (le suivant sera demandé) ;
/// - `didSelect` : renvoie true si tu as géré la sélection.
struct MapLayer {
    var id: String
    /// Ordre de rendu des overlays (petit = dessous).
    var zIndex: Int = 100
    /// Appelé quand la carte est prête : ajoute tes overlays/annotations, abonne-toi au Core/Bus.
    var attach: @MainActor (MKMapView) -> Void
    var renderer: (@MainActor (MKOverlay) -> MKOverlayRenderer?)?
    var annotationView: (@MainActor (MKMapView, MKAnnotation) -> MKAnnotationView?)?
    var didSelect: (@MainActor (MKMapView, MKAnnotation) -> Bool)?
    /// Changement de région (pour charger les données visibles).
    var regionDidChange: (@MainActor (MKMapView) -> Void)?
    /// Appui long sur la carte.
    var longPress: (@MainActor (CLLocationCoordinate2D) -> Bool)?
    /// Tape simple sur la carte (hors annotation) : renvoie true si tu l'as géré.
    var tap: (@MainActor (CLLocationCoordinate2D) -> Bool)?

    init(id: String, zIndex: Int = 100,
         attach: @escaping @MainActor (MKMapView) -> Void,
         renderer: (@MainActor (MKOverlay) -> MKOverlayRenderer?)? = nil,
         annotationView: (@MainActor (MKMapView, MKAnnotation) -> MKAnnotationView?)? = nil,
         didSelect: (@MainActor (MKMapView, MKAnnotation) -> Bool)? = nil,
         regionDidChange: (@MainActor (MKMapView) -> Void)? = nil,
         longPress: (@MainActor (CLLocationCoordinate2D) -> Bool)? = nil,
         tap: (@MainActor (CLLocationCoordinate2D) -> Bool)? = nil) {
        self.id = id; self.zIndex = zIndex; self.attach = attach; self.renderer = renderer
        self.annotationView = annotationView; self.didSelect = didSelect
        self.regionDidChange = regionDidChange; self.longPress = longPress; self.tap = tap
    }
}

/// Utilitaires de carte partagés.
@MainActor
enum MapHub {
    /// Cadre la carte sur des coordonnées en tenant compte du panneau du bas et de la barre du haut.
    static func fit(_ coords: [CLLocationCoordinate2D], animated: Bool = true, extraTop: CGFloat = 0) {
        guard let map = Core.shared.map, !coords.isEmpty else { return }
        Core.shared.follow = false
        // la vue de conduite (inclinée, orientée, marge haute) fausserait le cadrage : on la remet à plat
        map.layoutMargins = .zero
        if map.camera.pitch != 0 || map.camera.heading != 0 {
            let cam = map.camera.copy() as! MKMapCamera
            cam.pitch = 0; cam.heading = 0
            map.setCamera(cam, animated: false)
        }
        let line = MKPolyline(coordinates: coords, count: coords.count)
        let pad = UIEdgeInsets(top: 90 + extraTop, left: 40, bottom: Core.shared.sheetHeight + 30, right: 70)
        map.setVisibleMapRect(line.boundingMapRect, edgePadding: pad, animated: animated)
    }
}
