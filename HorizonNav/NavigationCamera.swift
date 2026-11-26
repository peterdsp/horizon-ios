import CoreLocation
import Foundation

extension AppSettings.Keys {
    static let navigationViewMode = "navigationViewMode"
    static let navigationZoom = "navigationZoom"
    static let buildings3D = "buildings3D"
}

/// The map settings for guiding (Android `VIEW_3D`, `NORTH_UP`, `JUNCTION_ZOOM` and `BUILDINGS_3D`).
extension AppSettings {
    static var navigationViewMode: NavigationViewMode {
        defaults.string(forKey: Keys.navigationViewMode).flatMap(NavigationViewMode.init(rawValue:)) ?? .tilted
    }

    static var navigationZoom: NavigationZoom {
        defaults.string(forKey: Keys.navigationZoom).flatMap(NavigationZoom.init(rawValue:)) ?? .standard
    }

    static var buildings3D: Bool { defaults.object(forKey: Keys.buildings3D) as? Bool ?? true }
}

/// How the map looks at the road while guiding, cycled by one button on the phone and in CarPlay. Android has the same
/// three views as its 2D / 3D switch and its North up button.
enum NavigationViewMode: String, CaseIterable {
    case tilted
    case headingUp
    case northUp

    /// The view after this one, for the one-tap switch.
    var next: NavigationViewMode {
        switch self {
        case .tilted: return .headingUp
        case .headingUp: return .northUp
        case .northUp: return .tilted
        }
    }

    /// Camera tilt in degrees (Android `tilt3d`: 55).
    var pitch: Double { self == .tilted ? 55 : 0 }

    /// Whether the map turns with the car, rather than keeping north at the top.
    var followsCourse: Bool { self != .northUp }

    var symbolName: String {
        switch self {
        case .tilted: return "view.3d"
        case .headingUp: return "view.2d"
        case .northUp: return "n.circle"
        }
    }

    var title: String {
        switch self {
        case .tilted: return String(localized: "Tilted view")
        case .headingUp: return String(localized: "Heading up")
        case .northUp: return String(localized: "North up")
        }
    }
}

/// How close the guiding camera sits, on top of its automatic zoom (Android Settings > Junction zoom, half a level a step).
enum NavigationZoom: String, CaseIterable {
    case closer
    case standard
    case wider

    var offset: Double {
        switch self {
        case .closer: return 0.5
        case .standard: return 0
        case .wider: return -0.5
        }
    }

    var title: String {
        switch self {
        case .closer: return String(localized: "Closer")
        case .standard: return String(localized: "Default")
        case .wider: return String(localized: "Wider")
        }
    }
}

/// Where the guiding camera looks: zoom levels are MapLibre's (512-point tiles), as in the Android app.
struct NavigationCameraTarget: Equatable {
    var center: CLLocationCoordinate2D
    var zoom: Double
    var pitch: Double
    var heading: Double

    static func == (a: NavigationCameraTarget, b: NavigationCameraTarget) -> Bool {
        a.center.latitude == b.center.latitude && a.center.longitude == b.center.longitude &&
            a.zoom == b.zoom && a.pitch == b.pitch && a.heading == b.heading
    }
}

/// The automatic guiding camera, ported from the Android `NavigationPolicy.routeSpeedZoom` and `NavEngine.autoZoom`:
/// closer when slow, further out at speed and on fast roads, easing in for the next manoeuvre.
enum NavigationCamera {
    private static let speedPoints: [Double] = [0, 4, 8, 11, 13.4, 17, 22, 27, 31, 36]
    private static let zoomPoints: [Double] = [18.7, 18.5, 18.2, 17.9, 17.6, 17.1, 16.6, 16.2, 15.9, 15.6]
    static let minZoom = 13.0
    static let maxZoom = 18.7

    /// The route zoom for a speed in metres per second, a little further out on motorways and dual carriageways.
    static func routeSpeedZoom(_ speed: Double, fastRoad: Bool) -> Double {
        let base: Double
        if !speed.isFinite || speed >= speedPoints[speedPoints.count - 1] {
            base = zoomPoints[zoomPoints.count - 1]
        } else if speed <= speedPoints[0] {
            base = zoomPoints[0]
        } else {
            let i = speedPoints.firstIndex { speed <= $0 } ?? speedPoints.count - 1
            let f = (speed - speedPoints[i - 1]) / (speedPoints[i] - speedPoints[i - 1])
            base = zoomPoints[i - 1] + (zoomPoints[i] - zoomPoints[i - 1]) * f
        }
        return fastRoad ? base - 0.35 : base
    }

    /// The guiding zoom: the speed zoom, closer over the last 650 m to a manoeuvre, a little further out while a manoeuvre is
    /// still far off at motorway speed, then the Settings choice on top.
    static func zoom(speed: Double, distanceToManeuver: CLLocationDistance?, fastRoad: Bool, preference: NavigationZoom) -> Double {
        var z = routeSpeedZoom(speed, fastRoad: fastRoad)
        if let d = distanceToManeuver, d.isFinite {
            z += 0.38 * min(max((650 - d) / 650, 0), 1)
            if speed > 18 { z -= 0.3 * min(max((d - 2500) / 2500, 0), 1) }
        }
        return min(max(z - 0.45 + preference.offset, minZoom), maxZoom)
    }

    /// Metres of ground per screen point at a zoom level (MapLibre's 512-point tiles).
    static func metersPerPoint(zoom: Double, latitude: Double) -> Double {
        cos(latitude * .pi / 180) * 2 * .pi * 6_378_137 / (512 * pow(2, zoom))
    }

    /// The eye distance that shows a zoom level in a view this tall, with the 30 degree field of view MapLibre uses.
    static func distance(zoom: Double, latitude: Double, viewHeight: Double) -> CLLocationDistance {
        metersPerPoint(zoom: zoom, latitude: latitude) * max(viewHeight, 1) / 2 / tan(15 * .pi / 180)
    }

    /// The same for MapKit's camera, which sees the same stretch of road from about twice as close (measured side by side
    /// with the MapLibre map in the simulator).
    static func appleDistance(zoom: Double, latitude: Double, viewHeight: Double) -> CLLocationDistance {
        distance(zoom: zoom, latitude: latitude, viewHeight: viewHeight) * appleDistanceScale
    }

    static let appleDistanceScale = 2.15

    /// The camera for one fix: the car low on the screen when the map turns with it (more road ahead is shown), centred when
    /// north stays up.
    static func target(location: CLLocationCoordinate2D, course: Double?, speed: Double, route: RouteOption?, update: GuidanceUpdate?,
                       mode: NavigationViewMode, preference: NavigationZoom, zoomNudge: Double = 0, viewHeight: Double) -> NavigationCameraTarget {
        var distanceToManeuver: CLLocationDistance?
        var fast = false
        var heading = course ?? 0
        if let route, let update {
            if let index = update.upcomingStepIndex, route.steps.indices.contains(index) {
                distanceToManeuver = update.distanceToManeuver
                fast = NavigationStore.isFastRoad(step: route.steps[index], route: route, progress: update.progress)
            }
            if course == nil, let along = route.point(atProgress: update.progress) { heading = along.bearing }
        }
        let zoom = min(max(Self.zoom(speed: speed, distanceToManeuver: distanceToManeuver, fastRoad: fast, preference: preference) + zoomNudge,
                           minZoom - 3), maxZoom)
        let mapHeading = mode.followsCourse ? heading : 0
        var center = location
        if mode.followsCourse {
            // Android puts the car at (1 + pad) / 2 of the height: about 0.8 tilted and 0.72 flat. Looking ahead along the road does
            // that on either map; tilted, the ground ahead is foreshortened, so it takes about twice as far.
            let ground = metersPerPoint(zoom: zoom, latitude: location.latitude) * viewHeight
            center = RouteGeometry.coordinate(from: location, bearing: heading, distance: ground * (mode == .tilted ? 0.45 : 0.22))
        }
        return NavigationCameraTarget(center: center, zoom: zoom, pitch: mode.pitch, heading: mapHeading)
    }

    /// The route still to drive, from the car to the destination, for the one-tap overview.
    static func remainingCoordinates(of route: RouteOption, progress: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard route.coordinates.count > 1 else { return route.coordinates }
        let clamped = min(max(progress, 0), route.length)
        let start = RouteGeometry.index(atProgress: clamped, cumulative: route.cumulative)
        var out: [CLLocationCoordinate2D] = []
        if let here = route.point(atProgress: clamped)?.coordinate { out.append(here) }
        out.append(contentsOf: route.coordinates[min(start + 1, route.coordinates.count - 1)...])
        return out
    }
}

extension RouteOption {
    /// The point a distance along the route and the way the route runs there.
    func point(atProgress progress: CLLocationDistance) -> (coordinate: CLLocationCoordinate2D, bearing: Double)? {
        guard coordinates.count > 1, cumulative.count == coordinates.count else { return nil }
        let p = min(max(progress, 0), length)
        let i = min(RouteGeometry.index(atProgress: p, cumulative: cumulative), coordinates.count - 2)
        let a = coordinates[i], b = coordinates[i + 1]
        let span = cumulative[i + 1] - cumulative[i]
        let t = span > 0 ? (p - cumulative[i]) / span : 0
        let coordinate = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                longitude: a.longitude + (b.longitude - a.longitude) * t)
        return (coordinate, RouteGeometry.bearing(a, b))
    }
}

extension RouteGeometry {
    /// The point a distance away along a bearing, on a sphere.
    static func coordinate(from start: CLLocationCoordinate2D, bearing: Double, distance: CLLocationDistance) -> CLLocationCoordinate2D {
        let r = 6_371_000.0
        let d = distance / r, b = bearing * .pi / 180
        let lat1 = start.latitude * .pi / 180, lon1 = start.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(b))
        let lon2 = lon1 + atan2(sin(b) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }
}
