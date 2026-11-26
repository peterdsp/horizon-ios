import Combine
import CoreLocation
import Foundation
import os

/// A traffic light, railway level crossing or stop sign from OpenStreetMap.
struct RoadFeature: Equatable, Hashable {
    enum Kind: String {
        case trafficLight
        case railwayCrossing
        case stopSign

        var title: String {
            switch self {
            case .trafficLight: return String(localized: "Traffic lights")
            case .railwayCrossing: return String(localized: "Level crossing")
            case .stopSign: return String(localized: "Stop sign")
            }
        }
    }

    var kind: Kind
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// A feature placed on the route, `offset` metres from its start.
struct PlacedRoadFeature: Equatable {
    var feature: RoadFeature
    var offset: CLLocationDistance
}

/// Traffic lights, level crossings and stop signs along the route, ported from the Android `Overpass.routeFeatures` (lights
/// within 30 m of the route) and `RouteExtras.hazards` (level crossings and stop signs within 12 m, a stop sign only when it is
/// for the route's road, `stopForRoute`). One-way arrows come from the map style itself.
enum RoadFeatures {
    /// One Overpass request for a stretch of route, a line of "lat,lon" pairs.
    static func query(line: String) -> String {
        "[out:json][timeout:25];" +
            "node(around:30,\(line))[\"highway\"=\"traffic_signals\"]->.t;.t out 2000;" +
            "node(around:12,\(line))[\"railway\"=\"level_crossing\"]->.r;.r out 300;" +
            "node(around:12,\(line))[\"highway\"=\"stop\"]->.s;.s out body 300;way(bn.s)[\"highway\"]->.sw;.sw out body geom 600;"
    }

    /// The features along a stretch of route, trying each public Overpass server in turn.
    static func fetch(along coordinates: [CLLocationCoordinate2D]) async throws -> [RoadFeature] {
        let line = SpeedCameras.thinned(coordinates, maxPoints: 300).map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ",")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let q = query(line: line)
        let body = Data(("data=" + (q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q)).utf8)
        var last: Error = URLError(.cannotConnectToHost)
        for endpoint in SpeedCameras.endpoints {
            do {
                let data = try await ProviderHTTP.data(endpoint, provider: "Overpass", timeout: 35, body: body, contentType: "application/x-www-form-urlencoded")
                return try parse(data, route: coordinates)
            } catch {
                last = error
            }
        }
        throw last
    }

    /// Parses an Overpass answer. A busy server answers "OK" with a remark saying it gave up: that is a failure, not "none".
    static func parse(_ data: Data, route: [CLLocationCoordinate2D]) throws -> [RoadFeature] {
        let root = try JSON.object(data, provider: "Overpass")
        let remark = root.string("remark").lowercased()
        if remark.contains("error") || remark.contains("timed out") || remark.contains("timeout") || remark.contains("out of memory") {
            throw ProviderError.badResponse(provider: "Overpass")
        }
        var out: [RoadFeature] = []
        var ways: [[String: Any]] = []
        var stops: [(id: Int, at: CLLocationCoordinate2D, tags: [String: Any])] = []
        for e in root.array("elements") {
            if e.string("type") == "way" {
                if e["geometry"] != nil && e["nodes"] != nil { ways.append(e) }
                continue
            }
            guard let lat = e.double("lat"), let lon = e.double("lon") else { continue }
            let tags = e.dict("tags") ?? [:]
            if tags["highway"] as? String == "traffic_signals" {
                out.append(RoadFeature(kind: .trafficLight, latitude: lat, longitude: lon))
            } else if tags["railway"] as? String == "level_crossing" {
                out.append(RoadFeature(kind: .railwayCrossing, latitude: lat, longitude: lon))
            } else if tags["highway"] as? String == "stop", let id = e.int("id") {
                stops.append((id, CLLocationCoordinate2D(latitude: lat, longitude: lon), tags))
            }
        }
        for stop in stops where stopForRoute(id: stop.id, at: stop.at, tags: stop.tags, ways: ways, route: route) {
            out.append(RoadFeature(kind: .stopSign, latitude: stop.at.latitude, longitude: stop.at.longitude))
        }
        return out
    }

    /// Whether a stop sign is for the route's road, not a side road it passes (Android `RouteExtras.stopForRoute`): the road
    /// the sign is on has to run the same way as the route there, its direction tag has to face the way the route goes, and a
    /// sign on the junction itself with no direction only counts when it is a stop for everyone. With no road data, it is left out.
    static func stopForRoute(id: Int, at position: CLLocationCoordinate2D, tags: [String: Any], ways: [[String: Any]],
                             route: [CLLocationCoordinate2D]) -> Bool {
        guard route.count >= 2 else { return false }
        var best = Double.greatestFiniteMagnitude, bi = 0
        for i in 0..<(route.count - 1) {
            let d = RouteGeometry.distance(route[i], position) + RouteGeometry.distance(route[i + 1], position) - RouteGeometry.distance(route[i], route[i + 1])
            if d < best { best = d; bi = i }
        }
        guard RouteGeometry.distance(route[bi], route[bi + 1]) >= 0.5 else { return false }
        let routeBearing = RouteGeometry.bearing(route[bi], route[bi + 1])
        let direction = (tags["direction"] as? String ?? "").lowercased()
        let all = tags["stop"] as? String == "all"
        var onWays = 0
        var forUs = false
        for way in ways {
            guard let nodes = way["nodes"] as? [NSNumber], let geometry = way["geometry"] as? [[String: Any]], geometry.count >= 2,
                  let k = nodes.firstIndex(where: { $0.intValue == id }), k < geometry.count else { continue }
            onWays += 1
            let a = geometry[max(k - 1, 0)], b = geometry[min(k + 1, geometry.count - 1)]
            guard let alat = a.double("lat"), let alon = a.double("lon"), let blat = b.double("lat"), let blon = b.double("lon") else { continue }
            let wayBearing = RouteGeometry.bearing(CLLocationCoordinate2D(latitude: alat, longitude: alon), CLLocationCoordinate2D(latitude: blat, longitude: blon))
            let diff = abs(NavigationPolicy.angleDifference(from: routeBearing, to: wayBearing))
            if diff < 40 && direction != "backward" { forUs = true }
            if diff > 140 && direction != "forward" { forUs = true }
        }
        guard onWays > 0, forUs else { return false }
        if onWays >= 2 && direction != "forward" && direction != "backward" && !all { return false }
        return true
    }

    /// Features on the route: within 25 m of the line, one for a feature mapped twice (a light on each side of a junction).
    static func place(_ features: [RoadFeature], on route: RouteOption) -> [PlacedRoadFeature] {
        var out: [PlacedRoadFeature] = []
        for feature in features {
            guard let p = RouteGeometry.project(feature.coordinate, onto: route), p.distance < 25 else { continue }
            if out.contains(where: { $0.feature.kind == feature.kind && abs($0.offset - p.progress) < 15 }) { continue }
            out.append(PlacedRoadFeature(feature: feature, offset: p.progress))
        }
        return out.sorted { $0.offset < $1.offset }
    }

    /// The features from just behind the car to `within` metres ahead, nearest first: the stretch the map shows while guiding.
    static func ahead(_ placed: [PlacedRoadFeature], progress: CLLocationDistance, within: CLLocationDistance = 2500, limit: Int = 120) -> [PlacedRoadFeature] {
        Array(placed.filter { $0.offset >= progress - 20 && $0.offset <= progress + within }.prefix(limit))
    }
}

/// The features along the route being driven, looked up a stretch at a time ahead of the car (Android searches about 7.5 km per
/// request so a busy server can cope). Shared by the phone and CarPlay maps.
@MainActor
final class RoadFeatureStore: ObservableObject {
    static let shared = RoadFeatureStore()

    /// Whether the stretch ahead has been looked up, for the phone's list of what is coming.
    enum Status: Equatable { case idle, loading, ready, unavailable }

    @Published private(set) var placed: [PlacedRoadFeature] = []
    @Published private(set) var status = Status.idle

    /// Each request covers this much route, and the next is asked for this far before the car reaches the end of the last.
    static let stretch: CLLocationDistance = 10_000
    static let lookAhead: CLLocationDistance = 4_000

    private var routeID: UUID?
    private var loadedUntil: CLLocationDistance = 0
    private var task: Task<Void, Never>?
    private var retryAt: Date?
    private var cancellables: Set<AnyCancellable> = []
    private let log = Logger(subsystem: "com.horizonnav.ios", category: "roadfeatures")

    init(store: NavigationStore? = nil) {
        let store = store ?? .shared
        store.$guidance
            .receive(on: RunLoop.main)
            .sink { [weak self, weak store] update in
                guard let self, let store else { return }
                let guiding = store.phase == .guiding || store.phase == .rerouting
                self.update(route: guiding ? store.selectedRoute : nil, progress: update?.progress ?? 0)
            }
            .store(in: &cancellables)
    }

    /// Starts the next request when the car gets near the end of what has been looked up; clears everything off a route.
    func update(route: RouteOption?, progress: CLLocationDistance) {
        guard let route else {
            if routeID != nil { reset() }
            return
        }
        if route.id != routeID {
            reset()
            routeID = route.id
            loadedUntil = progress
        }
        guard task == nil, loadedUntil < route.length, progress >= loadedUntil - Self.lookAhead,
              retryAt.map({ Date() >= $0 }) ?? true else { return }
        guard NetworkMonitor.shared.isOnlineNow else {
            if placed.isEmpty { setStatus(.unavailable) }
            return
        }
        let from = max(loadedUntil, progress) - 50, to = min(max(loadedUntil, progress) + Self.stretch, route.length)
        let first = RouteGeometry.index(atProgress: max(from, 0), cumulative: route.cumulative)
        let last = min(RouteGeometry.index(atProgress: to, cumulative: route.cumulative) + 1, route.coordinates.count - 1)
        guard last > first else { return }
        let stretch = Array(route.coordinates[first...last])
        if placed.isEmpty { setStatus(.loading) }
        task = Task { [weak self] in
            do {
                let found = try await RoadFeatures.fetch(along: stretch)
                guard let self, self.routeID == route.id else { return }
                let merged = RoadFeatures.place(self.placed.map(\.feature) + found, on: route)
                self.placed = merged
                self.loadedUntil = to
                self.retryAt = nil
                self.setStatus(.ready)
                self.log.info("\(found.count, privacy: .public) road feature(s) up to \(Int(to), privacy: .public) m")
            } catch {
                guard let self, self.routeID == route.id else { return }
                // A busy server: try that stretch again in a little while, or after 5 minutes when it asked for less traffic.
                var limited = false
                if case .http(_, 429, _)? = error as? ProviderError { limited = true }
                self.retryAt = Date().addingTimeInterval(limited ? 300 : 30)
                if self.placed.isEmpty { self.setStatus(.unavailable) }
                self.log.error("Road features failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.task = nil
        }
    }

    private func setStatus(_ new: Status) {
        if status != new { status = new }
    }

    private func reset() {
        task?.cancel()
        task = nil
        routeID = nil
        loadedUntil = 0
        retryAt = nil
        placed = []
        setStatus(.idle)
    }
}
