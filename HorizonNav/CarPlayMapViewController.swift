import Combine
import MapKit
import UIKit

/// The map a CarPlay navigation app draws in its own `CPWindow`, under the `CPMapTemplate` controls.
/// Shows live traffic from Apple Maps, every route option during preview, and follows the car while guiding.
/// With no signal, or with OpenStreetMap chosen in Settings, the MapLibre map draws downloaded areas instead.
final class CarPlayMapViewController: UIViewController, MKMapViewDelegate {
    private let store: NavigationStore
    private let mapView = MKMapView()
    private var openMap: OpenMapView?
    private let speedSign = SpeedSignView()
    /// The instrument cluster's smaller map: it always follows the car.
    private let compact: Bool
    private var cancellables: Set<AnyCancellable> = []
    /// The guiding camera, overview and marks for the car screen (not the cluster, which keeps following the car).
    private(set) lazy var guidanceMap = GuidanceMapModel(store: store)
    private var shownMarks: [String: MarkAnnotation] = [:]
    /// The limit sign and speedometer, shown while guiding unless the car turns them off.
    var showsSpeedSign = true { didSet { updateSpeedSign() } }

    init(store: NavigationStore, compact: Bool = false) {
        self.store = store
        self.compact = compact
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        mapView.frame = view.bounds
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.showsTraffic = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.userTrackingMode = compact ? .followWithHeading : .follow
        view.addSubview(mapView)
        speedSign.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(speedSign)
        NSLayoutConstraint.activate([
            speedSign.widthAnchor.constraint(equalToConstant: 76),
            speedSign.heightAnchor.constraint(equalToConstant: 108),
            speedSign.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            speedSign.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
        ])
        // Day and night follow the car's look, or the Settings override applied to this controller.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            self.openMap?.setDark(self.isDark)
        }
        store.$speedLimit.combineLatest(store.$currentSpeed, store.$phase, store.$nextLimitDrop)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.updateSpeedSign() }
            .store(in: &cancellables)

        store.$routeOptions.combineLatest(store.$selectedRouteIndex, store.$phase)
            .receive(on: RunLoop.main)
            .sink { [weak self] options, selected, phase in self?.render(options: options, selected: selected, phase: phase) }
            .store(in: &cancellables)
        NetworkMonitor.shared.$isOnline.combineLatest(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () }.prepend(()))
            .map { online, _ in MapSourcePolicy.usesOpenMap(online: online) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] useOpen in self?.setOpenMap(useOpen) }
            .store(in: &cancellables)
        guard !compact else { return }
        guidanceMap.$camera
            .compactMap { $0 }
            .sink { [weak self] target in self?.apply(camera: target) }
            .store(in: &cancellables)
        guidanceMap.$overview
            .sink { [weak self] coordinates in if let coordinates { self?.showOverview(coordinates) } }
            .store(in: &cancellables)
        guidanceMap.$marks
            .sink { [weak self] marks in self?.show(marks: marks) }
            .store(in: &cancellables)
        guidanceMap.$buildings3D
            .sink { [weak self] on in
                self?.mapView.showsBuildings = on
                self?.openMap?.setBuildings3D(on)
            }
            .store(in: &cancellables)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !compact { guidanceMap.viewHeight = Double(view.bounds.height) }
    }

    /// The guiding camera on whichever map is showing.
    private func apply(camera target: NavigationCameraTarget) {
        if let openMap { openMap.apply(camera: target); return }
        if mapView.userTrackingMode != .none { mapView.setUserTrackingMode(.none, animated: false) }
        let distance = NavigationCamera.appleDistance(zoom: target.zoom, latitude: target.center.latitude, viewHeight: Double(mapView.bounds.height))
        let camera = MKMapCamera(lookingAtCenter: target.center, fromDistance: distance, pitch: target.pitch, heading: target.heading)
        UIView.animate(withDuration: 1, delay: 0, options: [.curveLinear, .beginFromCurrentState, .allowUserInteraction]) {
            self.mapView.camera = camera
        }
    }

    /// The rest of the route on screen, flat and north up, clear of the trip estimates on the right.
    private func showOverview(_ coordinates: [CLLocationCoordinate2D]) {
        let padding = UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 260)
        if let openMap { openMap.showOverview(coordinates, padding: padding); return }
        guard coordinates.count > 1 else { return }
        if mapView.userTrackingMode != .none { mapView.setUserTrackingMode(.none, animated: false) }
        let flat = mapView.camera.copy() as! MKMapCamera
        flat.pitch = 0
        flat.heading = 0
        mapView.camera = flat
        let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
        mapView.setVisibleMapRect(line.boundingMapRect, edgePadding: padding, animated: true)
    }

    private func show(marks: [MapMark]) {
        openMap?.show(marks: marks)
        let wanted = Dictionary(marks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let gone = shownMarks.filter { wanted[$0.key] == nil }
        if !gone.isEmpty { mapView.removeAnnotations(Array(gone.values)) }
        gone.keys.forEach { shownMarks[$0] = nil }
        for mark in marks {
            if let shown = shownMarks[mark.id] {
                if shown.coordinate.latitude != mark.coordinate.latitude || shown.coordinate.longitude != mark.coordinate.longitude {
                    shown.coordinate = mark.coordinate
                }
            } else {
                let annotation = MarkAnnotation(mark: mark)
                shownMarks[mark.id] = annotation
                mapView.addAnnotation(annotation)
            }
        }
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard let annotation = annotation as? MarkAnnotation else { return nil }
        let id = annotation.mark.imageKey ?? annotation.mark.id
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
        view.annotation = annotation
        view.image = annotation.mark.image
        view.centerOffset = annotation.mark.anchorsBottom ? CGPoint(x: 0, y: -annotation.mark.image.size.height / 2) : .zero
        view.displayPriority = .required
        view.isAccessibilityElement = true
        view.accessibilityLabel = annotation.mark.label
        return view
    }

    private var isDark: Bool { traitCollection.userInterfaceStyle == .dark }

    private func updateSpeedSign() {
        let guiding = store.phase == .guiding || store.phase == .rerouting
        speedSign.isHidden = !(showsSpeedSign && guiding)
        speedSign.update(limit: store.speedLimit, speed: store.currentSpeed, next: store.nextLimitDrop)
    }

    /// Swaps between Apple Maps and the OpenStreetMap map that can draw downloaded areas offline.
    private func setOpenMap(_ enabled: Bool) {
        if enabled, openMap == nil {
            let open = OpenMapView(frame: view.bounds, dark: isDark)
            open.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(open, belowSubview: speedSign)
            openMap = open
            if !compact {
                open.setBuildings3D(guidanceMap.buildings3D)
                open.onUserMove = { [weak self] in self?.guidanceMap.userMovedMap() }
                open.show(marks: guidanceMap.marks)
            }
            render(options: store.routeOptions, selected: store.selectedRouteIndex, phase: store.phase)
        } else if !enabled, let open = openMap {
            open.removeFromSuperview()
            openMap = nil
        }
        mapView.isHidden = enabled
    }


    func recenter() {
        if !compact && (store.phase == .guiding || store.phase == .rerouting) { guidanceMap.recenter(); return }
        if let openMap { openMap.follow(withHeading: store.phase == .guiding); return }
        mapView.setUserTrackingMode(store.phase == .guiding ? .followWithHeading : .follow, animated: true)
    }

    func zoom(by factor: Double) {
        // While following, + and - move the automatic zoom rather than leaving it.
        if !compact, guidanceMap.nudgeZoom(by: factor < 1 ? 1 : -1) { return }
        if let openMap { openMap.zoom(by: factor < 1 ? 1 : -1); return }
        var region = mapView.region
        region.span.latitudeDelta = min(max(region.span.latitudeDelta * factor, 0.002), 90)
        region.span.longitudeDelta = min(max(region.span.longitudeDelta * factor, 0.002), 90)
        mapView.setRegion(region, animated: true)
    }

    func pan(_ direction: CGVector) {
        if !compact { guidanceMap.userMovedMap() }
        if let openMap { openMap.pan(direction); return }
        let center = mapView.convert(CGPoint(x: mapView.bounds.midX + direction.dx * mapView.bounds.width / 3,
                                             y: mapView.bounds.midY + direction.dy * mapView.bounds.height / 3),
                                     toCoordinateFrom: mapView)
        mapView.setCenter(center, animated: true)
    }

    private func render(options: [RouteOption], selected: Int, phase: NavigationStore.Phase) {
        if let openMap {
            openMap.show(routes: options, selected: selected)
            if phase == .previewing { openMap.fitRoutes(padding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 260)) }
            if compact && (phase == .guiding || phase == .rerouting) { openMap.follow(withHeading: true) }
        }
        mapView.removeOverlays(mapView.overlays)
        // Unselected alternatives first, so the selected route draws on top.
        let ordered = options.enumerated().sorted { a, _ in a.offset != selected }
        for (index, option) in ordered where option.coordinates.count > 1 {
            let line = MKPolyline(coordinates: option.coordinates, count: option.coordinates.count)
            line.title = index == selected ? "selected" : "alternative"
            mapView.addOverlay(line, level: .aboveRoads)
        }
        switch phase {
        case .previewing:
            let rects = mapView.overlays.map(\.boundingMapRect)
            if let first = rects.first {
                let union = rects.dropFirst().reduce(first) { $0.union($1) }
                mapView.setVisibleMapRect(union, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 260), animated: true)
            }
        case .guiding, .rerouting:
            // The car screen's camera comes from `guidanceMap`; the cluster follows the car.
            if compact { mapView.setUserTrackingMode(.followWithHeading, animated: true) }
        default:
            break
        }
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: line)
        let selected = line.title == "selected"
        renderer.strokeColor = selected ? .systemCyan : UIColor.systemGray.withAlphaComponent(0.7)
        renderer.lineWidth = selected ? 8 : 6
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }
}

/// A mark on the Apple map, keeping the picture it is drawn with.
final class MarkAnnotation: NSObject, MKAnnotation {
    let mark: MapMark
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(mark: MapMark) {
        self.mark = mark
        coordinate = mark.coordinate
        super.init()
    }
}
