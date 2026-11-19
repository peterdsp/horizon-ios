import Combine
import CoreLocation
import MapboxMaps
import SwiftUI
import UIKit

struct MapboxPhoneMap: UIViewRepresentable {
    let token: String
    let routes: [RouteOption]
    let selected: Int
    let events: [RoadEvent]
    let tracking: PhoneMapTracking
    let onGesture: () -> Void
    let onFailure: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MapboxMaps.MapView {
        MapboxOptions.accessToken = token
        let initialCamera = CameraOptions(center: tracking.pose?.coordinate ?? NavigationStore.fallbackCoordinate, zoom: 12)
        let view = MapboxMaps.MapView(frame: .zero, mapInitOptions: MapInitOptions(cameraOptions: initialCamera, styleURI: nil))
        let coordinator = context.coordinator
        coordinator.onGesture = onGesture
        coordinator.onFailure = onFailure
        view.gestures.delegate = coordinator
        view.location.dataModel = LocationDataModel(location: coordinator.locations.eraseToAnyPublisher())
        coordinator.alternatives = view.annotations.makePolylineAnnotationManager(id: "horizon-alternatives")
        coordinator.active = view.annotations.makePolylineAnnotationManager(id: "horizon-active")
        coordinator.roadMarkers = view.annotations.makePointAnnotationManager(id: "horizon-events")
        coordinator.alternatives?.slot = "middle"
        coordinator.active?.slot = "middle"
        coordinator.roadMarkers?.slot = "top"
        return view
    }

    func updateUIView(_ view: MapboxMaps.MapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onGesture = onGesture
        coordinator.onFailure = onFailure
        coordinator.applyStyle(dark: colorScheme == .dark, view: view)
        coordinator.showRoutes(routes, selected: selected, navigating: tracking.navigating, view: view)
        coordinator.showEvents(events)
        coordinator.updatePuck(tracking, view: view)
        coordinator.follow(tracking, view: view)
    }

    static func dismantleUIView(_ uiView: MapboxMaps.MapView, coordinator: Coordinator) {
        coordinator.styleTimeout?.cancel()
        coordinator.cameraAnimation?.cancel()
    }

    final class Coordinator: NSObject, GestureManagerDelegate {
        let locations = CurrentValueSubject<[MapboxMaps.Location], Never>([])
        var alternatives: PolylineAnnotationManager?
        var active: PolylineAnnotationManager?
        var roadMarkers: PointAnnotationManager?
        var onGesture: (() -> Void)?
        var onFailure: (() -> Void)?
        var cameraAnimation: Cancelable?
        var styleTimeout: Task<Void, Never>?
        private var styleGeneration = UUID()
        private var dark: Bool?
        private var routeIDs: [UUID] = []
        private var eventIDs: [String] = []
        private var selected = 0
        private var navigating = false
        private var puckScale = 0.0
        private var usesModel = false
        private var lastPuckFix: Date?
        private var lastCameraFix: Date?
        private var lastFraming: PhoneCameraPolicy.Framing?
        private var wasFollowing = false

        func applyStyle(dark: Bool, view: MapboxMaps.MapView) {
            guard self.dark != dark else { return }
            self.dark = dark
            let generation = UUID()
            styleGeneration = generation
            styleTimeout?.cancel()
            styleTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(18))
                guard !Task.isCancelled, let self, self.styleGeneration == generation else { return }
                self.onFailure?()
            }
            view.mapboxMap.load(mapStyle: .standard(lightPreset: dark ? .night : .day, show3dObjects: true, show3dBuildings: true)) { [weak self, weak view] error in
                guard let self, let view, self.styleGeneration == generation else { return }
                self.styleTimeout?.cancel()
                guard error == nil else { self.onFailure?(); return }
                Self.installTerrainAndTraffic(on: view.mapboxMap)
            }
        }

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

        func showRoutes(_ routes: [RouteOption], selected: Int, navigating: Bool, view: MapboxMaps.MapView) {
            let ids = routes.map(\.id)
            guard ids != routeIDs || selected != self.selected || navigating != self.navigating else { return }
            routeIDs = ids
            self.selected = selected
            self.navigating = navigating
            var activeLines: [PolylineAnnotation] = []
            var alternateLines: [PolylineAnnotation] = []
            for (index, route) in routes.enumerated() where route.coordinates.count >= 2 {
                var line = PolylineAnnotation(id: route.id.uuidString, lineCoordinates: route.coordinates)
                line.lineWidth = index == selected ? 7 : 5
                line.lineColor = StyleColor(index == selected ? .systemBlue : .systemGray)
                line.lineOpacity = index == selected ? 1 : 0.75
                if index == selected { activeLines.append(line) } else { alternateLines.append(line) }
            }
            active?.lineCap = .round
            active?.lineJoin = .round
            alternatives?.lineCap = .round
            alternatives?.lineJoin = .round
            active?.annotations = activeLines
            alternatives?.annotations = alternateLines
            let points = routes.flatMap(\.coordinates)
            if !navigating, points.count >= 2 {
                let options = view.mapboxMap.camera(for: points, padding: PhoneMapTracking.previewInsets, bearing: 0, pitch: 0)
                cameraAnimation = view.camera.ease(to: options, duration: 0.55)
            }
        }

        func showEvents(_ events: [RoadEvent]) {
            let ids = events.map(\.id)
            guard ids != eventIDs else { return }
            eventIDs = ids
            roadMarkers?.iconAllowOverlap = true
            roadMarkers?.annotations = events.map { event in
                var marker = PointAnnotation(id: event.id, coordinate: event.coordinate)
                marker.image = .init(image: PhoneMapArtwork.event(event.kind), name: "road-event-\(event.kind.rawValue)")
                return marker
            }
        }

        func updatePuck(_ tracking: PhoneMapTracking, view: MapboxMaps.MapView) {
            let modelURL = Bundle.main.url(forResource: "HorizonVehicle", withExtension: "glb")
            let wantsModel = tracking.navigating && tracking.pitch > 0 && modelURL != nil
            if puckScale != tracking.vehicleScale || usesModel != wantsModel {
                puckScale = tracking.vehicleScale
                usesModel = wantsModel
                view.location.options.puckBearing = .course
                view.location.options.puckBearingEnabled = true
                if wantsModel, let modelURL {
                    let scale = 5.5 * puckScale
                    view.location.options.puckType = .puck3D(Puck3DConfiguration(
                        model: Model(uri: modelURL), modelScale: .constant([scale, scale, scale])))
                } else {
                    view.location.options.puckType = .puck2D(Puck2DConfiguration(
                        bearingImage: PhoneMapArtwork.vehicle(scale: puckScale), showsAccuracyRing: false))
                }
            }
            guard let pose = tracking.pose, pose.location.timestamp != lastPuckFix else { return }
            lastPuckFix = pose.location.timestamp
            let fix = pose.location
            let adjusted = CLLocation(coordinate: pose.coordinate, altitude: fix.altitude,
                                      horizontalAccuracy: fix.horizontalAccuracy, verticalAccuracy: fix.verticalAccuracy,
                                      course: pose.bearing, speed: max(fix.speed, 0), timestamp: fix.timestamp)
            locations.send([Location(clLocation: adjusted)])
        }

        func follow(_ tracking: PhoneMapTracking, view: MapboxMaps.MapView) {
            defer { wasFollowing = tracking.follows }
            guard tracking.follows, let pose = tracking.pose else { return }
            guard !wasFollowing || pose.location.timestamp != lastCameraFix || lastFraming != tracking.framing else { return }
            lastCameraFix = pose.location.timestamp
            lastFraming = tracking.framing
            let padding = UIEdgeInsets(top: tracking.navigating ? view.bounds.height * 0.30 : 0, left: 0, bottom: 0, right: 0)
            let options = CameraOptions(center: pose.coordinate, padding: padding, zoom: tracking.zoom,
                                        bearing: tracking.bearing, pitch: tracking.pitch)
            cameraAnimation = view.camera.ease(to: options, duration: 0.50, curve: .easeOut)
        }

        func gestureManager(_ gestureManager: GestureManager, didBegin gestureType: GestureType) {
            cameraAnimation?.cancel()
            onGesture?()
        }

        func gestureManager(_ gestureManager: GestureManager, didEnd gestureType: GestureType, willAnimate: Bool) {}
        func gestureManager(_ gestureManager: GestureManager, didEndAnimatingFor gestureType: GestureType) {}
    }
}
