import Combine
import CoreLocation
import UIKit

/// Something drawn on the map while guiding: a road feature, the lane sign at the next junction, the destination, or the car
/// in a junction preview. The phone's two maps and CarPlay's draw the same marks.
struct MapMark: Identifiable, Equatable {
    /// Stable while the mark stays the same; a new id when its picture changes.
    var id: String
    var coordinate: CLLocationCoordinate2D
    var image: UIImage
    var label: String
    /// Stands on the point (a sign on its post, a pin) rather than being centred on it.
    var anchorsBottom = false
    /// Marks with the same picture share it (every traffic light); nil uses the id.
    var imageKey: String?

    static func == (a: MapMark, b: MapMark) -> Bool {
        a.id == b.id && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
    }
}

/// The lane picture standing at the junction, like a motorway gantry (Android `setLaneSign`). The providers give the lanes'
/// arrows but not where each lane runs, so the lanes are not painted on the road itself: Android does that only where it can read
/// the real lane lines off Mapbox's HD roads, which this map does not have.
struct LaneSign: Equatable {
    var coordinate: CLLocationCoordinate2D
    var section: LaneSection
    var maneuver: Maneuver

    static func == (a: LaneSign, b: LaneSign) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude &&
            a.section == b.section && a.maneuver == b.maneuver
    }

    /// The sign for the next manoeuvre: shown from 1.3 km out on fast roads and 400 m elsewhere (Android `updateLaneMarks`),
    /// 10 m before the junction, until the car is 15 m from it.
    static func ahead(route: RouteOption?, update: GuidanceUpdate?) -> LaneSign? {
        guard let route, let update, let index = update.upcomingStepIndex, route.steps.indices.contains(index) else { return nil }
        let step = route.steps[index]
        let fast = NavigationStore.isFastRoad(step: step, route: route, progress: update.progress)
        guard let section = route.laneSection(forStep: index, progress: update.progress, fastRoad: fast),
              section.lanes.count >= 2,
              update.distanceToManeuver < (fast ? 1300 : 400),
              update.progress < step.startProgress - 15,
              let at = route.point(atProgress: max(0, step.startProgress - 10))?.coordinate else { return nil }
        return LaneSign(coordinate: at, section: section, maneuver: step.maneuver)
    }

    var mark: MapMark? {
        let marked = LanePolicy.marked(section, maneuver: maneuver)
        guard let picture = LaneImage.image(marked) else { return nil }
        let key = marked.map { $0.map { "\($0.direction)\($0.use ? "+" : "-")" }.joined(separator: ",") }.joined(separator: "|")
        return MapMark(id: "lanes-\(key)", coordinate: coordinate, image: MapMarkImages.sign(picture),
                       label: LanePolicy.advice(section, maneuver: maneuver) ?? String(localized: "Lanes"), anchorsBottom: true)
    }
}

/// Pictures for the marks, drawn like the lane picture so they need no image assets.
enum MapMarkImages {
    private static var cache: [String: UIImage] = [:]

    static func image(for kind: RoadFeature.Kind) -> UIImage {
        if let cached = cache[kind.rawValue] { return cached }
        let image: UIImage
        switch kind {
        case .trafficLight: image = trafficLight()
        case .railwayCrossing: image = levelCrossing()
        case .stopSign: image = stopSign()
        }
        cache[kind.rawValue] = image
        return image
    }

    private static func renderer(_ size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    /// A signal head: red, amber and green in a dark case.
    static func trafficLight() -> UIImage {
        renderer(CGSize(width: 16, height: 34)).image { _ in
            let body = UIBezierPath(roundedRect: CGRect(x: 1, y: 1, width: 14, height: 32), cornerRadius: 4)
            UIColor(white: 0.12, alpha: 1).setFill()
            body.fill()
            UIColor.white.setStroke()
            body.lineWidth = 1.5
            body.stroke()
            for (i, color) in [UIColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                UIBezierPath(ovalIn: CGRect(x: 4, y: 4 + CGFloat(i) * 9, width: 8, height: 8)).fill()
            }
        }
    }

    /// The crossbuck: a white cross edged in red.
    static func levelCrossing() -> UIImage {
        renderer(CGSize(width: 30, height: 30)).image { context in
            let c = context.cgContext
            c.setLineCap(.butt)
            for (width, color) in [(CGFloat(9), UIColor.systemRed), (CGFloat(5), UIColor.white)] {
                c.setLineWidth(width)
                c.setStrokeColor(color.cgColor)
                c.move(to: CGPoint(x: 4, y: 4)); c.addLine(to: CGPoint(x: 26, y: 26))
                c.move(to: CGPoint(x: 26, y: 4)); c.addLine(to: CGPoint(x: 4, y: 26))
                c.strokePath()
            }
        }
    }

    /// A red octagon with a white rim.
    static func stopSign() -> UIImage {
        renderer(CGSize(width: 26, height: 26)).image { _ in
            let path = UIBezierPath()
            for i in 0..<8 {
                let angle = (CGFloat(i) * 45 + 22.5) * .pi / 180
                let point = CGPoint(x: 13 + 12 * cos(angle), y: 13 + 12 * sin(angle))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.close()
            UIColor.systemRed.setFill()
            path.fill()
            UIColor.white.setStroke()
            path.lineWidth = 2
            path.stroke()
            let text = NSAttributedString(string: "STOP", attributes: [.font: UIFont.systemFont(ofSize: 7, weight: .heavy), .foregroundColor: UIColor.white])
            let size = text.size()
            text.draw(at: CGPoint(x: 13 - size.width / 2, y: 13 - size.height / 2))
        }
    }

    /// The lane picture on a dark board with a post under it, 44 points tall.
    static func sign(_ picture: UIImage) -> UIImage {
        let boardHeight: CGFloat = 36
        let width = picture.size.width * boardHeight / picture.size.height + 8
        return renderer(CGSize(width: width, height: boardHeight + 8 + 10)).image { _ in
            UIColor(white: 0.85, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: width / 2 - 1.5, y: boardHeight + 8, width: 3, height: 10)).fill()
            let board = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: boardHeight + 8), cornerRadius: 6)
            UIColor(red: 0.05, green: 0.2, blue: 0.5, alpha: 0.92).setFill()
            board.fill()
            UIColor.white.setStroke()
            board.lineWidth = 1.5
            board.stroke()
            picture.draw(in: CGRect(x: 4, y: 4, width: width - 8, height: boardHeight))
        }
    }

    /// The car in a junction preview: an arrow pointing up the screen, which the preview camera turns to face the road.
    static let vehicle: UIImage = renderer(CGSize(width: 34, height: 34)).image { _ in
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 34, height: 34)).fill()
        UIColor.systemBlue.setFill()
        UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 30, height: 30)).fill()
        let arrow = UIBezierPath()
        arrow.move(to: CGPoint(x: 17, y: 6))
        arrow.addLine(to: CGPoint(x: 26, y: 27))
        arrow.addLine(to: CGPoint(x: 17, y: 22))
        arrow.addLine(to: CGPoint(x: 8, y: 27))
        arrow.close()
        UIColor.white.setFill()
        arrow.fill()
    }

    /// A red pin, drawn into a plain picture so SwiftUI does not tint it like a symbol.
    static let destination: UIImage = {
        let config = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
        guard let pin = UIImage(systemName: "mappin.circle.fill", withConfiguration: config) else { return UIImage() }
        return renderer(pin.size).image { _ in pin.draw(at: .zero) }
    }()
}

/// The guiding camera and marks for one map: the phone's or CarPlay's. Follows the car with the automatic zoom and the chosen
/// view, shows the rest of the route for the overview, and plays junction previews. Each screen keeps its own following and
/// overview state; the view and zoom choices are settings shared by both.
@MainActor
final class GuidanceMapModel: ObservableObject {
    /// Where the camera should look; nil when the map is not following the car.
    @Published private(set) var camera: NavigationCameraTarget?
    /// The route left to drive while the overview is on.
    @Published private(set) var overview: [CLLocationCoordinate2D]?
    /// Counts each time the overview should be fitted again: when it opens, and after a reroute.
    @Published private(set) var overviewFit = 0
    @Published private(set) var marks: [MapMark] = []
    @Published private(set) var viewMode = AppSettings.navigationViewMode
    @Published private(set) var buildings3D = AppSettings.buildings3D
    /// False once the map has been moved by hand, until the location button brings it back.
    @Published private(set) var following = true

    let player = JunctionPreviewPlayer()
    /// The map's height in points, for the camera distance.
    var viewHeight: Double = 700 { didSet { if abs(viewHeight - oldValue) > 1 { refresh() } } }
    /// Zoom steps added with the map's + and - buttons while following (CarPlay), until recentred.
    private var zoomNudge = 0.0
    /// The route the overview was fitted to: a reroute fits the new one.
    private var overviewRouteID: UUID?
    private let store: NavigationStore
    private var cancellables: Set<AnyCancellable> = []

    init(store: NavigationStore? = nil) {
        let store = store ?? .shared
        self.store = store
        store.$phase
            .removeDuplicates()
            .scan((NavigationStore.Phase.idle, NavigationStore.Phase.idle)) { ($0.1, $1) }
            .receive(on: RunLoop.main)
            .sink { [weak self] previous, phase in
                // A new trip, or a trip ended, starts out following the car again; a reroute keeps the overview or a moved map.
                if (phase == .guiding && previous != .rerouting) || phase == .idle || phase == .previewing { self?.resetFollowing() }
            }
            .store(in: &cancellables)
        store.$guidance.map { _ in () }
            .merge(with: store.$selectedRouteIndex.map { _ in () }, store.$routeOptions.map { _ in () },
                   RoadFeatureStore.shared.$placed.map { _ in () }, player.$frame.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)
        // Views watching this model also redraw for the junction preview.
        player.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private var guiding: Bool { store.phase == .guiding || store.phase == .rerouting }

    /// The one-tap switch: tilted, heading up, north up, and round again. Remembered for next time.
    func cycleViewMode() {
        AppSettings.defaults.set(viewMode.next.rawValue, forKey: AppSettings.Keys.navigationViewMode)
        settingsChanged()
    }

    /// Shows the rest of the route, or with the overview already on, goes back to following the car.
    func toggleOverview() {
        if overview != nil { recenter(); return }
        guard guiding else { return }
        following = false
        refresh(showOverview: true)
    }

    var showsOverview: Bool { overview != nil }

    func recenter() {
        following = true
        zoomNudge = 0
        overview = nil
        refresh()
    }

    /// The map was dragged, pinched or turned by hand: stop following until recentred.
    func userMovedMap() {
        guard following || overview != nil else { return }
        following = false
        overview = nil
        refresh()
    }

    /// The + and - buttons while following move the automatic zoom instead of leaving it.
    func nudgeZoom(by steps: Double) -> Bool {
        guard guiding, following, overview == nil else { return false }
        zoomNudge = min(max(zoomNudge + steps, -3), 2)
        refresh()
        return true
    }

    private func resetFollowing() {
        following = true
        zoomNudge = 0
        overview = nil
        refresh()
    }

    private func settingsChanged() {
        let mode = AppSettings.navigationViewMode, buildings = AppSettings.buildings3D
        if mode != viewMode { viewMode = mode }
        if buildings != buildings3D { buildings3D = buildings }
        refresh()
    }

    private func refresh(showOverview: Bool = false) {
        let route = store.selectedRoute
        var marks: [MapMark] = []
        if let route, store.phase != .idle, let end = route.coordinates.last {
            marks.append(MapMark(id: "destination", coordinate: end, image: MapMarkImages.destination,
                                 label: store.destination?.name ?? String(localized: "Destination"), anchorsBottom: true))
        }
        if let preview = player.preview, let frame = player.frame {
            // A junction preview: the car drives through the manoeuvre with the tilted view, whatever the view setting.
            if let sign = LaneSign.ahead(route: preview.route, update: frame.update)?.mark { marks.append(sign) }
            marks.append(MapMark(id: "preview-car", coordinate: frame.coordinate, image: MapMarkImages.vehicle, label: String(localized: "Preview")))
            setOverview(nil)
            setCamera(NavigationCamera.target(location: frame.coordinate, course: frame.bearing, speed: preview.speed, route: preview.route,
                                              update: frame.update, mode: .tilted, preference: AppSettings.navigationZoom, viewHeight: viewHeight))
        } else if guiding, let route {
            let progress = store.guidance?.progress ?? 0
            for placed in RoadFeatures.ahead(RoadFeatureStore.shared.placed, progress: progress) {
                let f = placed.feature
                marks.append(MapMark(id: "\(f.kind.rawValue)-\(f.latitude)-\(f.longitude)", coordinate: f.coordinate,
                                     image: MapMarkImages.image(for: f.kind), label: f.kind.title, imageKey: f.kind.rawValue))
            }
            if let sign = LaneSign.ahead(route: route, update: store.guidance)?.mark { marks.append(sign) }
            if showOverview || overview != nil {
                if overviewRouteID != route.id { overview = nil }
                overviewRouteID = route.id
                setOverview(NavigationCamera.remainingCoordinates(of: route, progress: progress))
                setCamera(nil)
            } else if following, let location = store.locationManager.location {
                setOverview(nil)
                setCamera(NavigationCamera.target(location: location.coordinate, course: location.course >= 0 && location.speed > 1 ? location.course : nil,
                                                  speed: max(location.speed, 0), route: route, update: store.guidance, mode: viewMode,
                                                  preference: AppSettings.navigationZoom, zoomNudge: zoomNudge, viewHeight: viewHeight))
            } else {
                setCamera(nil)
            }
        } else {
            setOverview(nil)
            setCamera(nil)
        }
        if marks != self.marks { self.marks = marks }
    }

    private func setCamera(_ target: NavigationCameraTarget?) {
        if target != camera { camera = target }
    }

    private func setOverview(_ coordinates: [CLLocationCoordinate2D]?) {
        // Fitted once when the overview opens, not again on every fix.
        if (coordinates == nil) != (overview == nil) {
            overview = coordinates
            if coordinates != nil { overviewFit += 1 }
        }
    }
}
