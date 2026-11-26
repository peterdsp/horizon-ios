import Combine
import CoreLocation
import MapboxMaps
import SwiftUI
import UIKit

/// The phone's optional Mapbox Standard map: 3D buildings, traffic lines and a 3D car in the tilted view. It is driven by the
/// same `GuidanceMapModel` as the Apple and OpenStreetMap maps, so the view mode, the zoom setting, the route overview and
/// junction previews behave the same on all three.
struct MapboxPhoneMap: UIViewRepresentable {
    let token: String
    let routes: [RouteOption]
    let selected: Int
    /// Guidance is running: the map follows `camera` and does not fit the whole route.
    let following: Bool
    let camera: NavigationCameraTarget?
    let overview: [CLLocationCoordinate2D]?
    let overviewFit: Int
    let marks: [MapMark]
    let buildings3D: Bool
    let vehicle: VehiclePose?
    let vehicleScale: Double
    /// Counts taps on the location button outside guidance, to bring the map back to the car.
    let recenter: Int
    let onUserMove: () -> Void
    let onFailure: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    static let previewInsets = UIEdgeInsets(top: 180, left: 42, bottom: 300, right: 42)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MapboxMaps.MapView {
        MapboxOptions.accessToken = token
        let initialCamera = CameraOptions(center: vehicle?.coordinate ?? NavigationStore.fallbackCoordinate, zoom: 14)
        let view = MapboxMaps.MapView(frame: .zero, mapInitOptions: MapInitOptions(cameraOptions: initialCamera, styleURI: nil))
        let coordinator = context.coordinator
        coordinator.onUserMove = onUserMove
        coordinator.onFailure = onFailure
        coordinator.recenter = recenter
        view.gestures.delegate = coordinator
        view.location.dataModel = LocationDataModel(location: coordinator.locations.eraseToAnyPublisher())
        coordinator.alternatives = view.annotations.makePolylineAnnotationManager(id: "horizon-alternatives")
        coordinator.active = view.annotations.makePolylineAnnotationManager(id: "horizon-active")
        coordinator.markLayer = view.annotations.makePointAnnotationManager(id: "horizon-marks")
        coordinator.alternatives?.slot = "middle"
        coordinator.active?.slot = "middle"
        coordinator.markLayer?.slot = "top"
        coordinator.markLayer?.iconAllowOverlap = true
        return view
    }

    func updateUIView(_ view: MapboxMaps.MapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onUserMove = onUserMove
        coordinator.onFailure = onFailure
        coordinator.applyStyle(dark: colorScheme == .dark, buildings3D: buildings3D, view: view)
        coordinator.showRoutes(routes, selected: selected, following: following, view: view)
        coordinator.show(marks: marks)
        coordinator.updatePuck(vehicle, scale: vehicleScale, tilted: following && (camera?.pitch ?? 0) > 0, view: view)
        coordinator.apply(camera: camera, following: following, view: view)
        coordinator.showOverview(overview, fit: overviewFit, view: view)
        if recenter != coordinator.recenter {
            coordinator.recenter = recenter
            if camera == nil, let vehicle {
                coordinator.cameraAnimation = view.camera.ease(to: CameraOptions(center: vehicle.coordinate, zoom: 15, bearing: 0, pitch: 0),
                                                               duration: 0.5)
            }
        }
    }

    static func dismantleUIView(_ uiView: MapboxMaps.MapView, coordinator: Coordinator) {
        coordinator.styleTimeout?.cancel()
        coordinator.cameraAnimation?.cancel()
    }

    final class Coordinator: NSObject, GestureManagerDelegate {
        let locations = CurrentValueSubject<[MapboxMaps.Location], Never>([])
        var alternatives: PolylineAnnotationManager?
        var active: PolylineAnnotationManager?
        var markLayer: PointAnnotationManager?
        var onUserMove: (() -> Void)?
        var onFailure: (() -> Void)?
        var cameraAnimation: Cancelable?
        var styleTimeout: Task<Void, Never>?
        var recenter = 0
        private var styleGeneration = UUID()
        private var style: (dark: Bool, buildings: Bool)?
        private var shownRoutes: [RouteOption] = []
        private var selected = 0
        private var following = false
        private var markIDs: [String] = []
        private var puck: (scale: Double, model: Bool)?
        private var lastPuckFix: Date?
        private var camera: NavigationCameraTarget?
        private var overviewFit = 0

        func applyStyle(dark: Bool, buildings3D: Bool, view: MapboxMaps.MapView) {
            guard style?.dark != dark || style?.buildings != buildings3D else { return }
            style = (dark, buildings3D)
            let generation = UUID()
            styleGeneration = generation
            styleTimeout?.cancel()
            // A map that has not drawn its style in this time is treated as failed, and the phone falls back to OpenStreetMap.
            styleTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(18))
                guard !Task.isCancelled, let self, self.styleGeneration == generation else { return }
                self.onFailure?()
            }
            let standard = MapStyle.standard(lightPreset: dark ? .night : .day, show3dObjects: buildings3D, show3dBuildings: buildings3D)
            view.mapboxMap.load(mapStyle: standard) { [weak self, weak view] error in
                guard let self, let view, self.styleGeneration == generation else { return }
                self.styleTimeout?.cancel()
                guard error == nil else { self.onFailure?(); return }
                Self.installTerrainAndTraffic(on: view.mapboxMap)
            }
        }

        /// Terrain and live traffic lines, when the token has access to those tilesets.
        private static func installTerrainAndTraffic(on map: MapboxMap) {
            var dem = RasterDemSource(id: "horizon-dem")
            dem.url = "mapbox://mapbox.mapbox-terrain-dem-v1"
            dem.tileSize = 514
            dem.maxzoom = 14
            if (try? map.addSource(dem)) != nil {
                try? map.setTerrain(Terrain(sourceId: dem.id))
            }

            var traffic = VectorSource(id: "horizon-traffic")
            traffic.url = "mapbox://mapbox.mapbox-traffic-v1"
            var flow = LineLayer(id: "horizon-traffic-lines", source: traffic.id)
            flow.sourceLayer = "traffic"
            flow.slot = .middle
            flow.minZoom = 9
            flow.lineWidth = .constant(2)
            flow.lineOpacity = .constant(0.85)
            flow.lineColor = .expression(Exp(.match) {
                Exp(.get) { "congestion" }
                "low"; "#299760"
                "moderate"; "#e59a22"
                "heavy"; "#e25538"
                "severe"; "#ae2745"
                "rgba(0,0,0,0)"
            })
            if (try? map.addSource(traffic)) != nil { try? map.addLayer(flow) }
        }

        func showRoutes(_ routes: [RouteOption], selected: Int, following: Bool, view: MapboxMaps.MapView) {
            guard routes.map(\.id) != shownRoutes.map(\.id) || selected != self.selected || following != self.following else { return }
            shownRoutes = routes
            self.selected = selected
            self.following = following
            var activeLines: [PolylineAnnotation] = []
            var alternateLines: [PolylineAnnotation] = []
            for (index, route) in routes.enumerated() where route.coordinates.count >= 2 {
                var line = PolylineAnnotation(id: route.id.uuidString, lineCoordinates: route.coordinates)
                line.lineWidth = index == selected ? 7 : 5
                line.lineColor = StyleColor(index == selected ? .systemCyan : .systemGray)
                line.lineOpacity = index == selected ? 1 : 0.75
                if index == selected { activeLines.append(line) } else { alternateLines.append(line) }
            }
            active?.lineCap = .round
            active?.lineJoin = .round
            alternatives?.lineCap = .round
            alternatives?.lineJoin = .round
            active?.annotations = activeLines
            alternatives?.annotations = alternateLines
            if !following { fitRoutes(view: view) }
        }

        private func fitRoutes(view: MapboxMaps.MapView) {
            let points = shownRoutes.flatMap(\.coordinates)
            guard points.count >= 2 else { return }
            fitCamera(points, padding: MapboxPhoneMap.previewInsets, duration: 0.55, view: view)
        }

        /// Road features, the lane sign, the destination and the preview car: the same marks as the other maps.
        func show(marks: [MapMark]) {
            let ids = marks.map { "\($0.id)@\($0.coordinate.latitude),\($0.coordinate.longitude)" }
            guard ids != markIDs else { return }
            markIDs = ids
            markLayer?.annotations = marks.map { mark in
                var point = PointAnnotation(id: mark.id, coordinate: mark.coordinate)
                point.image = .init(image: mark.image, name: "horizon-mark-\(mark.imageKey ?? mark.id)")
                point.iconAnchor = mark.anchorsBottom ? .bottom : .center
                return point
            }
        }

        /// The car: the bundled 3D model in the tilted view while guiding, otherwise a flat car that turns with the course.
        func updatePuck(_ pose: VehiclePose?, scale: Double, tilted: Bool, view: MapboxMaps.MapView) {
            let modelURL = Bundle.main.url(forResource: "HorizonVehicle", withExtension: "glb")
            let wantsModel = tilted && modelURL != nil
            if puck?.scale != scale || puck?.model != wantsModel {
                puck = (scale, wantsModel)
                view.location.options.puckBearing = .course
                view.location.options.puckBearingEnabled = true
                if wantsModel, let modelURL {
                    let size = 5.5 * scale
                    view.location.options.puckType = .puck3D(Puck3DConfiguration(
                        model: Model(id: "horizon-vehicle", uri: modelURL), modelScale: .constant([size, size, size])))
                } else {
                    view.location.options.puckType = .puck2D(Puck2DConfiguration(
                        bearingImage: PhoneMapArtwork.vehicle(scale: scale), showsAccuracyRing: false))
                }
            }
            guard let pose, pose.location.timestamp != lastPuckFix else { return }
            lastPuckFix = pose.location.timestamp
            let fix = pose.location
            let adjusted = CLLocation(coordinate: pose.coordinate, altitude: fix.altitude,
                                      horizontalAccuracy: fix.horizontalAccuracy, verticalAccuracy: fix.verticalAccuracy,
                                      course: pose.bearing, speed: max(fix.speed, 0), timestamp: fix.timestamp)
            locations.send([Location(clLocation: adjusted)])
        }

        /// Moves to the guiding camera over a second, the time between two fixes, so the map glides with the car. Mapbox and
        /// MapLibre share the 512-point tile zoom scale, so the target's zoom applies as it is.
        func apply(camera target: NavigationCameraTarget?, following: Bool, view: MapboxMaps.MapView) {
            defer { camera = target }
            if let target, target != camera {
                let options = CameraOptions(center: target.center, zoom: target.zoom, bearing: target.heading, pitch: target.pitch)
                cameraAnimation = view.camera.ease(to: options, duration: 1, curve: .linear)
            } else if target == nil, camera != nil, !following {
                // A junction preview ended: back to the whole route.
                fitRoutes(view: view)
            }
        }

        /// The route overview: the rest of the route on screen, flat and north up, fitted once each time it opens.
        func showOverview(_ coordinates: [CLLocationCoordinate2D]?, fit: Int, view: MapboxMaps.MapView) {
            defer { overviewFit = fit }
            guard fit != overviewFit, let coordinates, coordinates.count > 1 else { return }
            fitCamera(coordinates, padding: UIEdgeInsets(top: 200, left: 50, bottom: 240, right: 50), duration: 0.8, view: view)
        }

        /// Fits coordinates on screen, flat and north up.
        private func fitCamera(_ coordinates: [CLLocationCoordinate2D], padding: UIEdgeInsets, duration: TimeInterval, view: MapboxMaps.MapView) {
            guard let options = try? view.mapboxMap.camera(for: coordinates, camera: CameraOptions(bearing: 0, pitch: 0),
                                                            coordinatesPadding: padding, maxZoom: 17, offset: nil) else { return }
            cameraAnimation = view.camera.ease(to: options, duration: duration)
        }

        func gestureManager(_ gestureManager: GestureManager, didBegin gestureType: GestureType) {
            cameraAnimation?.cancel()
            onUserMove?()
        }

        func gestureManager(_ gestureManager: GestureManager, didEnd gestureType: GestureType, willAnimate: Bool) {}
        func gestureManager(_ gestureManager: GestureManager, didEndAnimatingFor gestureType: GestureType) {}
    }
}
