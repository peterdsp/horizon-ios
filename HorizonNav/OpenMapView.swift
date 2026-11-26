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
    private var shownMarks: [String: MarkPoint] = [:]
    private(set) var dark: Bool
    private(set) var buildings3D = AppSettings.buildings3D
    var onRegionChange: ((MLNCoordinateBounds, Double) -> Void)?
    /// The map was dragged, pinched, turned or tilted by hand.
    var onUserMove: (() -> Void)?

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

    /// Moves to the guiding camera over a second, the time between two fixes, so the map glides with the car.
    func apply(camera target: NavigationCameraTarget) {
        if mapView.userTrackingMode != .none { mapView.setUserTrackingMode(.none, animated: false, completionHandler: nil) }
        let distance = NavigationCamera.distance(zoom: target.zoom, latitude: target.center.latitude, viewHeight: Double(mapView.bounds.height))
        let camera = MLNMapCamera(lookingAtCenter: target.center, acrossDistance: distance, pitch: target.pitch, heading: target.heading)
        mapView.setCamera(camera, withDuration: 1, animationTimingFunction: CAMediaTimingFunction(name: .linear))
    }

    /// The route overview: the rest of the route on screen, flat and north up.
    func showOverview(_ coordinates: [CLLocationCoordinate2D], padding: UIEdgeInsets) {
        guard coordinates.count > 1 else { return }
        if mapView.userTrackingMode != .none { mapView.setUserTrackingMode(.none, animated: false, completionHandler: nil) }
        flatten()
        let shape = MLNPolyline(coordinates: coordinates, count: UInt(coordinates.count))
        mapView.setCamera(mapView.cameraThatFitsShape(shape, direction: 0, edgePadding: padding), withDuration: 0.8, animationTimingFunction: nil)
    }

    /// Back to a flat, north-up map. Fitting a shape keeps the current tilt, so the fits flatten first.
    func flatten() {
        let flat = mapView.camera
        flat.pitch = 0
        flat.heading = 0
        mapView.camera = flat
    }

    /// Road features, the lane sign, the destination and the preview car. Unchanged marks stay; moved ones glide.
    func show(marks: [MapMark]) {
        let wanted = Dictionary(marks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let gone = shownMarks.filter { wanted[$0.key] == nil }
        if !gone.isEmpty { mapView.removeAnnotations(Array(gone.values)) }
        gone.keys.forEach { shownMarks[$0] = nil }
        var added: [MarkPoint] = []
        for mark in marks {
            if let point = shownMarks[mark.id] {
                if point.coordinate.latitude != mark.coordinate.latitude || point.coordinate.longitude != mark.coordinate.longitude {
                    point.coordinate = mark.coordinate
                }
            } else {
                let point = MarkPoint(mark: mark)
                shownMarks[mark.id] = point
                added.append(point)
            }
        }
        if !added.isEmpty { mapView.addAnnotations(added) }
    }

    /// 3D buildings: the day style's own extruded buildings flattened or raised, and for the night style, which has none,
    /// extruded buildings added from the same tiles, as the Android app adds them to a map without any (`dl-building-3d`).
    func setBuildings3D(_ on: Bool) {
        guard on != buildings3D else { return }
        buildings3D = on
        if let style = mapView.style { applyStyleExtras(style) }
    }

    private static let addedBuildingsLayer = "horizon-building-3d"

    private func applyStyleExtras(_ style: MLNStyle) {
        if let own = style.layer(withIdentifier: "building-3d") as? MLNFillExtrusionStyleLayer {
            own.fillExtrusionHeight = buildings3D ? NSExpression(forKeyPath: "render_height") : NSExpression(forConstantValue: 0)
            own.fillExtrusionBase = buildings3D ? NSExpression(forKeyPath: "render_min_height") : NSExpression(forConstantValue: 0)
        } else if buildings3D, style.layer(withIdentifier: Self.addedBuildingsLayer) == nil, let source = style.source(withIdentifier: "openmaptiles") {
            let layer = MLNFillExtrusionStyleLayer(identifier: Self.addedBuildingsLayer, source: source)
            layer.sourceLayerIdentifier = "building"
            layer.minimumZoomLevel = 15
            layer.fillExtrusionColor = NSExpression(forConstantValue: dark ? UIColor(red: 0.16, green: 0.17, blue: 0.22, alpha: 1) : UIColor(white: 0.85, alpha: 1))
            layer.fillExtrusionOpacity = NSExpression(forConstantValue: 0.9)
            // Risen from flat as the map zooms in, so they do not pop up (Android: zoom 15 to 15.6).
            layer.fillExtrusionHeight = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 15, 0, 15.6, ["get", "render_height"]])
            layer.fillExtrusionBase = NSExpression(mglJSONObject: ["get", "render_min_height"])
            // Under the labels, so street names stay readable.
            if let firstSymbol = style.layers.first(where: { $0 is MLNSymbolStyleLayer }) {
                style.insertLayer(layer, below: firstSymbol)
            } else {
                style.addLayer(layer)
            }
        } else if !buildings3D, let added = style.layer(withIdentifier: Self.addedBuildingsLayer) {
            style.removeLayer(added)
        }
        // One-way arrows from the usual guiding zoom: the day style starts them a level later than the night style.
        for id in ["road_one_way_arrow", "road_one_way_arrow_opposite"] {
            style.layer(withIdentifier: id)?.minimumZoomLevel = 15
        }
    }

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        applyStyleExtras(style)
    }

    func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
        guard let point = annotation as? MarkPoint else { return nil }
        let key = point.mark.imageKey ?? point.mark.id
        if let reused = mapView.dequeueReusableAnnotationImage(withIdentifier: key) { return reused }
        var image = point.mark.image
        if point.mark.anchorsBottom {
            // Annotation images are centred on their point: a clear lower half stands the picture on it.
            let size = CGSize(width: image.size.width, height: image.size.height * 2)
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            image = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(at: .zero) }
        }
        return MLNAnnotationImage(image: image, reuseIdentifier: key)
    }

    func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
        let byHand: MLNCameraChangeReason = [.gesturePan, .gesturePinch, .gestureRotate, .gestureZoomIn, .gestureZoomOut, .gestureOneFingerZoom, .gestureTilt]
        if !reason.intersection(byHand).isEmpty { onUserMove?() }
    }

    func pan(_ direction: CGVector) {
        let point = CGPoint(x: mapView.bounds.midX + direction.dx * mapView.bounds.width / 3,
                            y: mapView.bounds.midY + direction.dy * mapView.bounds.height / 3)
        mapView.setCenter(mapView.convert(point, toCoordinateFrom: mapView), animated: true)
    }

    func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
        annotation.title == "selected" ? .systemCyan : UIColor.systemGray.withAlphaComponent(0.7)
    }

    func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
        annotation.title == "selected" ? 8 : 6
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
        onRegionChange?(mapView.visibleCoordinateBounds, mapView.zoomLevel)
    }
}

/// A mark on the MapLibre map, keeping the picture it is drawn with.
final class MarkPoint: MLNPointAnnotation {
    let mark: MapMark

    init(mark: MapMark) {
        self.mark = mark
        super.init()
        coordinate = mark.coordinate
        accessibilityLabel = mark.label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The OpenStreetMap map for SwiftUI.
struct OpenMap: UIViewRepresentable {
    var routes: [RouteOption] = []
    var selected = 0
    var following = false
    var onRegionChange: ((MLNCoordinateBounds, Double) -> Void)?
    /// The guiding camera, the overview and the marks, when a `GuidanceMapModel` drives this map.
    var camera: NavigationCameraTarget?
    var overview: [CLLocationCoordinate2D]?
    var overviewFit = 0
    var marks: [MapMark] = []
    var buildings3D = AppSettings.buildings3D
    var onUserMove: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> OpenMapView {
        let view = OpenMapView(dark: colorScheme == .dark)
        view.onRegionChange = onRegionChange
        view.follow(withHeading: false)
        return view
    }

    func updateUIView(_ view: OpenMapView, context: Context) {
        view.setDark(colorScheme == .dark)
        view.setBuildings3D(buildings3D)
        view.onRegionChange = onRegionChange
        view.onUserMove = onUserMove
        view.show(marks: marks)
        let ids = routes.map(\.id)
        if context.coordinator.shownIDs != ids || context.coordinator.shownSelected != selected {
            context.coordinator.shownIDs = ids
            context.coordinator.shownSelected = selected
            view.show(routes: routes, selected: selected)
            if !routes.isEmpty && !following { view.fitRoutes(padding: UIEdgeInsets(top: 60, left: 40, bottom: 220, right: 40)) }
        }
        if following != context.coordinator.following {
            context.coordinator.following = following
            if following && camera == nil { view.follow(withHeading: true) }
        }
        if let camera, camera != context.coordinator.camera { view.apply(camera: camera) }
        // A junction preview ended: back to the whole route.
        if camera == nil, context.coordinator.camera != nil, !following, !routes.isEmpty {
            view.flatten()
            view.fitRoutes(padding: UIEdgeInsets(top: 60, left: 40, bottom: 220, right: 40))
        }
        context.coordinator.camera = camera
        if overviewFit != context.coordinator.overviewFit, let overview {
            view.showOverview(overview, padding: UIEdgeInsets(top: 160, left: 50, bottom: 220, right: 50))
        }
        context.coordinator.overviewFit = overviewFit
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shownIDs: [UUID] = []
        var shownSelected = 0
        var following = false
        var camera: NavigationCameraTarget?
        var overviewFit = 0
    }
}
