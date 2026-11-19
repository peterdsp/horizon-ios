import CoreLocation
import MapLibre
import SwiftUI
import UIKit

/// OpenFreeMap's OpenStreetMap styles: the same tile source as the Android app's free map, drawn with MapLibre Native so
/// downloaded areas work with no network.
enum OpenMapStyle {
    static let day = URL(string: "https://tiles.openfreemap.org/styles/liberty")!
    static let night = URL(string: "https://tiles.openfreemap.org/styles/dark")!

    static func url(dark: Bool) -> URL { dark ? night : day }
}

/// A MapLibre map with the route lines, used on the phone and in CarPlay.
final class OpenMapView: UIView, MLNMapViewDelegate {
    let mapView: MLNMapView
    private var lines: [MLNPolyline] = []
    private(set) var dark: Bool
    private var roadMarkers: [RoadMarker] = []
    private var markerIDs: [String] = []
    private var vehicle: MLNPointAnnotation?
    private var vehicleBearing = 0.0
    private var vehicleScale = 1.0
    var onGesture: (() -> Void)?
    var onRegionChange: ((MLNCoordinateBounds, Double) -> Void)?

    init(frame: CGRect = .zero, dark: Bool) {
        self.dark = dark
        mapView = MLNMapView(frame: frame, styleURL: OpenMapStyle.url(dark: dark))
        super.init(frame: frame)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.frame = bounds
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.compassView.isHidden = true
        mapView.setCenter(NavigationStore.fallbackCoordinate, zoomLevel: 12, animated: false)
        addSubview(mapView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setDark(_ dark: Bool) {
        guard dark != self.dark else { return }
        self.dark = dark
        mapView.styleURL = OpenMapStyle.url(dark: dark)
    }

    func show(routes: [RouteOption], selected: Int) {
        if !lines.isEmpty { mapView.removeAnnotations(lines) }
        // Unselected alternatives first, so the selected route draws on top.
        let ordered = routes.enumerated().filter { $0.offset != selected } + routes.enumerated().filter { $0.offset == selected }
        lines = ordered.compactMap { index, route in
            guard route.coordinates.count > 1 else { return nil }
            let line = MLNPolyline(coordinates: route.coordinates, count: UInt(route.coordinates.count))
            line.title = index == selected ? "selected" : "alternative"
            return line
        }
        mapView.addAnnotations(lines)
    }

    func fitRoutes(padding: UIEdgeInsets) {
        let points = lines.flatMap { line -> [CLLocationCoordinate2D] in
            var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: Int(line.pointCount))
            line.getCoordinates(&coords, range: NSRange(location: 0, length: Int(line.pointCount)))
            return coords
        }
        guard !points.isEmpty else { return }
        var coords = points
        mapView.setVisibleCoordinates(&coords, count: UInt(coords.count), edgePadding: padding, animated: true)
    }

    func follow(withHeading: Bool) {
        mapView.setUserTrackingMode(withHeading ? .followWithCourse : .follow, animated: true, completionHandler: nil)
    }

    func zoom(by delta: Double) { mapView.setZoomLevel(mapView.zoomLevel + delta, animated: true) }

    func pan(_ direction: CGVector) {
        let point = CGPoint(x: mapView.bounds.midX + direction.dx * mapView.bounds.width / 3,
                            y: mapView.bounds.midY + direction.dy * mapView.bounds.height / 3)
        mapView.setCenter(mapView.convert(point, toCoordinateFrom: mapView), animated: true)
    }

    func show(events: [RoadEvent]) {
        let ids = events.map(\.id)
        guard ids != markerIDs else { return }
        markerIDs = ids
        mapView.removeAnnotations(roadMarkers)
        roadMarkers = events.map(RoadMarker.init)
        mapView.addAnnotations(roadMarkers)
    }

    func showVehicle(_ pose: VehiclePose, scale: Double) {
        mapView.showsUserLocation = false
        vehicleBearing = pose.bearing
        vehicleScale = scale
        let pin = vehicle ?? MLNPointAnnotation()
        pin.coordinate = pose.coordinate
        if vehicle == nil {
            vehicle = pin
            mapView.addAnnotation(pin)
        }
        updateVehicleView()
    }

    func applyTracking(_ tracking: PhoneMapTracking) {
        guard let pose = tracking.pose else { return }
        let pitch = min(tracking.pitch, 60)
        let latitude = pose.coordinate.latitude * .pi / 180
        let metresPerPoint = 40_075_017 * cos(latitude) / (512 * pow(2, tracking.zoom))
        let altitude = max(45, Double(bounds.height) * metresPerPoint / 0.8)
        let camera = MLNMapCamera(lookingAtCenter: pose.coordinate, altitude: altitude,
                                 pitch: pitch, heading: tracking.bearing)
        let padding = UIEdgeInsets(top: tracking.navigating ? bounds.height * 0.30 : 0, left: 0, bottom: 0, right: 0)
        mapView.setCamera(camera, withDuration: 0.50, animationTimingFunction: nil,
                          edgePadding: padding, completionHandler: nil)
    }

    private func updateVehicleView() {
        guard let vehicle, let view = mapView.view(for: vehicle) as? IconView else { return }
        view.setVehicle(scale: vehicleScale, angle: (vehicleBearing - mapView.direction) * .pi / 180)
    }

    func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
        if let marker = annotation as? RoadMarker {
            return IconView(annotation: annotation, image: PhoneMapArtwork.event(marker.kind))
        }
        if let pin = annotation as? MLNPointAnnotation, pin === vehicle {
            let view = IconView(annotation: annotation, image: PhoneMapArtwork.vehicle(scale: vehicleScale))
            view.setVehicle(scale: vehicleScale, angle: (vehicleBearing - mapView.direction) * .pi / 180)
            return view
        }
        return nil
    }

    func mapView(_ mapView: MLNMapView, regionWillChangeAnimated animated: Bool) {
        if mapView.gestureRecognizers?.contains(where: { $0.state == .began || $0.state == .changed }) == true {
            onGesture?()
        }
    }

    func mapViewRegionIsChanging(_ mapView: MLNMapView) { updateVehicleView() }

    private final class RoadMarker: MLNPointAnnotation {
        let kind: RoadEvent.Kind

        init(event: RoadEvent) {
            kind = event.kind
            super.init()
            coordinate = event.coordinate
            title = kind.title
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }

    private final class IconView: MLNAnnotationView {
        private let icon = UIImageView()
        private var scale = 0.0

        init(annotation: MLNAnnotation, image: UIImage) {
            super.init(annotation: annotation, reuseIdentifier: nil)
            icon.image = image
            bounds.size = image.size
            icon.frame = bounds
            addSubview(icon)
            isEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func setVehicle(scale: Double, angle: Double) {
            if scale != self.scale {
                self.scale = scale
                let image = PhoneMapArtwork.vehicle(scale: scale)
                icon.image = image
                bounds.size = image.size
                icon.frame = bounds
            }
            icon.transform = CGAffineTransform(rotationAngle: angle)
        }
    }

    func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
        annotation.title == "selected" ? .systemCyan : UIColor.systemGray.withAlphaComponent(0.7)
    }

    func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
        annotation.title == "selected" ? 8 : 6
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
        updateVehicleView()
        onRegionChange?(mapView.visibleCoordinateBounds, mapView.zoomLevel)
    }
}

/// The OpenStreetMap map for SwiftUI.
struct OpenMap: UIViewRepresentable {
    var routes: [RouteOption] = []
    var selected = 0
    var tracking: PhoneMapTracking?
    var events: [RoadEvent] = []
    var onGesture: (() -> Void)?
    var onRegionChange: ((MLNCoordinateBounds, Double) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> OpenMapView {
        let view = OpenMapView(dark: colorScheme == .dark)
        view.onRegionChange = onRegionChange
        if tracking == nil { view.follow(withHeading: false) }
        return view
    }

    func updateUIView(_ view: OpenMapView, context: Context) {
        view.setDark(colorScheme == .dark)
        view.onRegionChange = onRegionChange
        view.onGesture = onGesture
        view.show(events: events)
        let coordinator = context.coordinator
        let navigating = tracking?.navigating == true
        let ids = routes.map(\.id)
        if coordinator.shownIDs != ids || coordinator.shownSelected != selected || coordinator.navigating != navigating {
            coordinator.shownIDs = ids
            coordinator.shownSelected = selected
            coordinator.navigating = navigating
            view.show(routes: routes, selected: selected)
            if !routes.isEmpty && !navigating { view.fitRoutes(padding: PhoneMapTracking.previewInsets) }
        }
        guard let tracking, let pose = tracking.pose else { return }
        let timestamp = pose.location.timestamp
        defer { coordinator.following = tracking.follows }
        if coordinator.lastFix != timestamp || coordinator.vehicleScale != tracking.vehicleScale {
            view.showVehicle(pose, scale: tracking.vehicleScale)
            coordinator.lastFix = timestamp
            coordinator.vehicleScale = tracking.vehicleScale
        }
        if tracking.follows && (!coordinator.following || coordinator.cameraFix != timestamp || coordinator.framing != tracking.framing) {
            view.applyTracking(tracking)
            coordinator.cameraFix = timestamp
            coordinator.framing = tracking.framing
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shownIDs: [UUID] = []
        var shownSelected = 0
        var following = false
        var navigating = false
        var lastFix: Date?
        var cameraFix: Date?
        var vehicleScale = 0.0
        var framing: PhoneCameraPolicy.Framing?
    }
}
