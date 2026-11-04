import SwiftUI
import MapKit

/// La carte plein écran (MKMapView). Les modules y posent leurs calques via `MapLayer`
/// (Registry). Le suivi de position (follow) est géré ici : en conduite, la carte suit,
/// s'oriente selon le cap et s'incline. Un geste de l'utilisateur coupe le suivi.
struct MapView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        let config = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        config.showsTraffic = false
        map.preferredConfiguration = config
        map.showsUserLocation = false          // le module mascot dessine « ma position »
        map.showsCompass = false               // le module shell a sa boussole
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        map.pointOfInterestFilter = .excludingAll
        map.setRegion(MKCoordinateRegion(center: Location.defaultCenter, latitudinalMeters: 4000, longitudinalMeters: 4000), animated: false)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userGesture(_:)))
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userGesture(_:)))
        pinch.delegate = context.coordinator
        map.addGestureRecognizer(pinch)
        let rot = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userGesture(_:)))
        rot.delegate = context.coordinator
        map.addGestureRecognizer(rot)
        let long = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
        long.minimumPressDuration = 0.5
        map.addGestureRecognizer(long)

        context.coordinator.map = map
        Task { @MainActor in
            Core.shared.map = map
            for layer in Registry.layers.sorted(by: { $0.zIndex < $1.zIndex }) { layer.attach(map) }
            Core.shared.mapReady = true
            context.coordinator.observe()
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        weak var map: MKMapView?
        private var lastPosition: Position?

        /// Suit `Core.position` / `follow` / `mode` (Observation, sans Combine).
        func observe() {
            withObservationTracking {
                let c = Core.shared
                _ = c.position; _ = c.follow; _ = c.mode; _ = c.sheetHeight
            } onChange: { [weak self] in
                Task { @MainActor in
                    self?.updateCamera()
                    self?.observe()
                }
            }
        }

        private func updateCamera() {
            let c = Core.shared
            guard let map, let p = c.position, c.follow else { lastPosition = c.position; return }
            let driving = c.mode == .drive
            let cam = MKMapCamera()
            cam.centerCoordinate = p.coordinate
            if driving {
                cam.centerCoordinateDistance = 700
                cam.pitch = 55
                cam.heading = p.heading ?? map.camera.heading
            } else {
                cam.centerCoordinateDistance = max(600, min(map.camera.centerCoordinateDistance, 30_000))
                cam.pitch = 0
                cam.heading = map.camera.heading
            }
            // en conduite, la position est plus bas que le centre : on voit la route devant
            let bottomPad: CGFloat = driving ? 0 : c.sheetHeight
            map.layoutMargins = UIEdgeInsets(top: driving ? map.bounds.height * 0.35 : 0, left: 0, bottom: bottomPad, right: 0)
            let dt = lastPosition.map { p.time.timeIntervalSince($0.time) } ?? 0.6
            lastPosition = p
            UIView.animate(withDuration: driving ? min(1, max(0.15, dt)) : 0.5, delay: 0, options: [.curveLinear, .beginFromCurrentState, .allowUserInteraction]) {
                map.setCamera(cam, animated: false)
            }
        }

        @objc func userGesture(_ g: UIGestureRecognizer) {
            if g.state == .began { Core.shared.follow = false }
        }

        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map else { return }
            let coord = map.convert(g.location(in: map), toCoordinateFrom: map)
            for layer in Registry.layers { if layer.longPress?(coord) == true { return } }
        }

        nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            for layer in Registry.layers { if let r = layer.renderer?(overlay) { return r } }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            for layer in Registry.layers { if let v = layer.annotationView?(mapView, annotation) { return v } }
            return nil
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            for layer in Registry.layers { if layer.didSelect?(mapView, annotation) == true { break } }
            mapView.deselectAnnotation(annotation, animated: false)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            for layer in Registry.layers { layer.regionDidChange?(mapView) }
        }
    }
}
