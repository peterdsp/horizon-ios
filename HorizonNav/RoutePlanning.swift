import CoreLocation
import Foundation
import MapKit

/// A stretch of road the driver asked to avoid for this trip (Android `sessionAvoid`): a short piece of it, sent to TomTom
/// as a box (`avoidAreas`), to Mapbox as an excluded point and to the offline router as an excluded polygon.
struct AvoidedRoad: Equatable {
    var name: String
    /// The middle of the piece, on the road.
    var point: CLLocationCoordinate2D
    var south: Double
    var west: Double
    var north: Double
    var east: Double

    static func == (a: AvoidedRoad, b: AvoidedRoad) -> Bool {
        a.name == b.name && a.point.latitude == b.point.latitude && a.point.longitude == b.point.longitude
    }

    /// The box as a closed ring of longitude, latitude pairs, for Valhalla `exclude_polygons`.
    var ring: [[Double]] { [[west, south], [east, south], [east, north], [west, north], [west, south]] }
}

/// Picking the stretch to avoid and checking that a new route really avoids it.
enum RouteAvoidance {
    /// The road after the manoeuvre at `stepIndex`, from 40 m past it to 40 m before the next one and at most 3 km
    /// (Android `avoidTurnRoad`). Only a short piece in its middle is blocked, so crossing roads stay open.
    static func road(after stepIndex: Int, on route: RouteOption) -> AvoidedRoad? {
        guard route.steps.indices.contains(stepIndex), !route.steps[stepIndex].isArrival else { return nil }
        let step = route.steps[stepIndex]
        let next = route.steps.indices.contains(stepIndex + 1) ? route.steps[stepIndex + 1].startProgress : route.length
        let from = step.startProgress + 40
        let to = min(next - 40, step.startProgress + 3000)
        guard to > from else { return piece(around: (step.startProgress + next) / 2, on: route, name: name(of: step)) }
        return piece(around: (from + to) / 2, on: route, name: name(of: step))
    }

    /// The road the car is on, from 60 m ahead to the next manoeuvre, 300 m to 3 km long (Android `avoidRoadAhead`).
    static func roadAhead(progress: CLLocationDistance, on route: RouteOption, name: String) -> AvoidedRoad? {
        let next = route.steps.first { $0.startProgress > progress + 60 }?.startProgress ?? route.length
        let from = progress + 60
        let to = min(max(next, from + 300), from + 3000, route.length - 20)
        guard to > from else { return nil }
        return piece(around: (from + to) / 2, on: route, name: name)
    }

    static func name(of step: RouteStep) -> String {
        if !step.exitNumber.isEmpty { return String(localized: "Exit \(step.exitNumber)") }
        if !step.street.isEmpty { return step.street }
        return step.instruction
    }

    /// A box round the 60 m of route centred on `progress`, padded by 15 m.
    static func piece(around progress: CLLocationDistance, on route: RouteOption, name: String) -> AvoidedRoad? {
        guard route.coordinates.count >= 2 else { return nil }
        let points = [progress - 30, progress, progress + 30].map { point(at: min(max($0, 0), route.length), on: route) }
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let padLat = 15 / 111_320.0
        let padLon = 15 / (111_320.0 * max(cos(points[1].latitude * .pi / 180), 0.01))
        return AvoidedRoad(name: name, point: points[1], south: lats.min()! - padLat, west: lons.min()! - padLon,
                           north: lats.max()! + padLat, east: lons.max()! + padLon)
    }

    /// The point on the route geometry at a distance along it.
    static func point(at progress: CLLocationDistance, on route: RouteOption) -> CLLocationCoordinate2D {
        let i = min(RouteGeometry.index(atProgress: progress, cumulative: route.cumulative), route.coordinates.count - 2)
        let span = route.cumulative[i + 1] - route.cumulative[i]
        let t = span > 0 ? min(max((progress - route.cumulative[i]) / span, 0), 1) : 0
        let a = route.coordinates[i], b = route.coordinates[i + 1]
        return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// The avoided roads a route still drives along: within 12 m of the blocked point.
    static func stillUsed(_ avoided: [AvoidedRoad], by route: RouteOption) -> [AvoidedRoad] {
        avoided.filter { road in (RouteGeometry.project(road.point, onto: route)?.distance ?? .greatestFiniteMagnitude) < 12 }
    }
}

/// Joining routes planned leg by leg, for Apple Maps, which cannot take stops in one request.
enum RouteLegs {
    /// One route from consecutive legs. Each leg's arrival becomes a plain "arrive at your stop" manoeuvre.
    static func join(_ legs: [RouteOption]) -> RouteOption? {
        guard var joined = legs.first else { return nil }
        for leg in legs.dropFirst() {
            joined = join(joined, leg)
        }
        return joined
    }

    static func join(_ a: RouteOption, _ b: RouteOption) -> RouteOption {
        var coordinates = a.coordinates
        var offset = a.length
        if let last = a.coordinates.last, let first = b.coordinates.first {
            let gap = RouteGeometry.distance(last, first)
            if gap >= 1 { coordinates.append(first); offset += gap }
        }
        coordinates.append(contentsOf: b.coordinates.dropFirst())
        var steps = a.steps.map { step -> RouteStep in
            var s = step
            if s.isArrival {
                s.isArrival = false
                s.instruction = String(localized: "Arrive at your stop")
            }
            return s
        }
        steps += b.steps.map { step -> RouteStep in
            var s = step
            s.startProgress += offset
            return s
        }
        let lanes = a.laneSections + b.laneSections.map { LaneSection(start: $0.start + offset, end: $0.end + offset, lanes: $0.lanes) }
        let limits = a.speedLimits + b.speedLimits.map { SpeedLimitSection(start: $0.start + offset, end: $0.end + offset, metersPerSecond: $0.metersPerSecond) }
        let tolls = a.tollSections + b.tollSections.map { RouteSection(start: $0.start + offset, end: $0.end + offset) }
        var advisories = a.advisories
        for x in b.advisories where !advisories.contains(x) { advisories.append(x) }
        return RouteOption(name: a.name, distance: a.distance + b.distance, expectedTravelTime: a.expectedTravelTime + b.expectedTravelTime,
                           coordinates: coordinates, steps: steps, advisories: advisories, source: a.source,
                           trafficDelay: a.trafficDelay + b.trafficDelay, laneSections: lanes, speedLimits: limits,
                           tollSections: tolls, tollsKnown: a.tollsKnown && b.tollsKnown)
    }
}

/// The next lower posted limit ahead, ported from the look-ahead in the Android `NavEngine.applyRouteLimit`: about 15 seconds
/// ahead at the car's speed, 250 to 800 m, a third further once shown so the sign does not flicker while slowing down.
enum SpeedLimitLookahead {
    struct Drop: Equatable {
        var metersPerSecond: Double
        var distance: CLLocationDistance
        /// Where the lower limit starts along the route, so each change is spoken once.
        var start: CLLocationDistance
    }

    /// Only reductions are returned: when the first change ahead is a rise, there is nothing to slow down for.
    static func nextDrop(in sections: [SpeedLimitSection], progress: CLLocationDistance, speed: Double, showing: Bool) -> Drop? {
        let at = progress + min(max(speed, 0) * 0.8, 20)
        let ahead = min(max(max(speed, 0) * 15, 250), 800) * (showing ? 1.3 : 1)
        guard let current = sections.first(where: { at >= $0.start && at < $0.end })?.metersPerSecond else { return nil }
        for section in sections.sorted(by: { $0.start < $1.start }) {
            if section.start <= at || section.start - at > ahead { continue }
            // An unknown stretch is not "0 in 700 m".
            if section.metersPerSecond < 2 { continue }
            guard abs(section.metersPerSecond - current) > 0.5 else { continue }
            guard section.metersPerSecond < current else { return nil }
            return Drop(metersPerSecond: section.metersPerSecond, distance: max(section.start - progress, 0), start: section.start)
        }
        return nil
    }
}

/// When to offer a quicker route during guidance, ported from the Android `NavEngine.checkFaster` prompt: every 2 minutes
/// with at least 5 minutes left, ask for fresh routes from the car; the fresh route that follows the road ahead is the
/// yardstick, and another one is offered when it saves 3 minutes or more and over 5%.
enum FasterRoutePolicy {
    static let checkInterval: TimeInterval = 120
    static let minimumRemaining: TimeInterval = 300
    /// Unanswered offers go away after 25 seconds; Keep or no answer waits 5 minutes before the next check.
    static let offerDuration: TimeInterval = 25
    static let cooldown: TimeInterval = 300

    struct Offer {
        /// The fresh route along the road the car is already on, so both are compared from the same moment and place.
        var same: RouteOption
        var faster: RouteOption
        var savedMinutes: Int
    }

    /// Share of a candidate's points (every 10th) within 40 m of the road ahead (every 3rd point) (Android `overlap`).
    static func overlap(_ candidate: RouteOption, with ahead: [CLLocationCoordinate2D]) -> Double {
        guard !ahead.isEmpty, !candidate.coordinates.isEmpty else { return 0 }
        let probe = stride(from: 0, to: ahead.count, by: 3).map { MKMapPoint(ahead[$0]) }
        let samples = stride(from: 0, to: candidate.coordinates.count, by: 10).map { candidate.coordinates[$0] }
        let near = samples.filter { c in
            let p = MKMapPoint(c)
            return probe.contains { $0.distance(to: p) < 40 }
        }.count
        return Double(near) / Double(samples.count)
    }

    static func offer(fresh: [RouteOption], ahead: [CLLocationCoordinate2D]) -> Offer? {
        guard fresh.count >= 2 else { return nil }
        let scored = fresh.map { ($0, overlap($0, with: ahead)) }
        guard let same = scored.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        guard let best = scored.filter({ $0.0 != same && $0.1 < 0.8 }).map(\.0).min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else { return nil }
        let saved = Int((same.expectedTravelTime - best.expectedTravelTime) / 60)
        guard saved >= 3, best.expectedTravelTime < same.expectedTravelTime * 0.95 else { return nil }
        return Offer(same: same, faster: best, savedMinutes: saved)
    }
}

/// What taking another route changes besides the time: "4 min faster · 12 km farther · adds a toll road".
enum RouteChange {
    static func summary(savedMinutes: Int, current: RouteOption, candidate: RouteOption) -> String {
        var parts = [String(localized: "\(savedMinutes) min faster")]
        let difference = candidate.distance - current.distance
        if abs(difference) >= 500 {
            let text = Measurement(value: abs(difference), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
            parts.append(difference > 0 ? String(localized: "\(text) farther") : String(localized: "\(text) shorter"))
        }
        if current.tollsKnown && candidate.tollsKnown {
            let before = !current.tollSections.isEmpty, after = !candidate.tollSections.isEmpty
            if after && !before { parts.append(String(localized: "adds a toll road")) }
            if before && !after { parts.append(String(localized: "avoids toll roads")) }
        }
        return parts.joined(separator: " · ")
    }
}

/// Which side of the road the destination is on, from the geometry (Android `NavEngine.arrivalSide`): the last 25 m of the
/// route against the way to the destination. It overrides the router's side only when the destination is clearly to one side.
enum ArrivalSide {
    static func side(route coordinates: [CLLocationCoordinate2D], destination: CLLocationCoordinate2D) -> Maneuver? {
        guard coordinates.count >= 2, let end = coordinates.last else { return nil }
        var i = coordinates.count - 2
        while i > 0 && RouteGeometry.distance(coordinates[i], end) < 25 { i -= 1 }
        let a = MKMapPoint(coordinates[i]), b = MKMapPoint(end), d = MKMapPoint(destination)
        // Map points grow to the east and to the south; flip y so the cross product's sign is left (+) or right (-).
        let dir = (x: b.x - a.x, y: a.y - b.y), toDest = (x: d.x - b.x, y: b.y - d.y)
        let dirLength = (dir.x * dir.x + dir.y * dir.y).squareRoot()
        let destLength = (toDest.x * toDest.x + toDest.y * toDest.y).squareRoot()
        let metres = MKMetersPerMapPointAtLatitude(destination.latitude)
        guard dirLength > 0, destLength * metres >= 6 else { return nil }
        let lateral = (dir.x * toDest.y - dir.y * toDest.x) / dirLength
        guard abs(lateral) * metres >= 5, abs(lateral) / destLength >= 0.42 else { return nil }
        return lateral > 0 ? .arriveLeft : .arriveRight
    }
}

/// Whether installed routing packs cover a trip: the smallest pack whose area holds every point (Android `areaFor`).
enum OfflineCoverage {
    static func pack(covering points: [CLLocationCoordinate2D], among packs: [InstalledPack]) -> InstalledPack? {
        func area(_ p: InstalledPack) -> Double { p.bounds.map { ($0[2] - $0[0]) * ($0[3] - $0[1]) } ?? .greatestFiniteMagnitude }
        return packs.filter { pack in points.allSatisfy(pack.contains) }.min { area($0) < area($1) }
    }

    /// The route's ends and stops plus a point every 10 km, so a route leaving the pack's area in the middle is not covered.
    static func checkpoints(of route: RouteOption) -> [CLLocationCoordinate2D] {
        guard route.coordinates.count >= 2 else { return route.coordinates }
        let marks = stride(from: 0, through: route.length, by: 10_000).map { RouteAvoidance.point(at: $0, on: route) }
        return marks + [route.coordinates[route.coordinates.count - 1]]
    }
}

/// The routing pack to suggest for a place, ported from the Android `PackRegions.nearYou`: the place's county, region or state
/// from OpenStreetMap's Nominatim (in English) matched to a pack in the same country, a region before a whole area, else the
/// country's own pack (England & Wales for Great Britain; none for the United States and Canada, which only have states).
enum PackSuggestion {
    static func normalize(_ name: String) -> String {
        var s = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en")).lowercased()
        for word in ["state of ", " county", "county ", " province", "province of ", " oblast", " region"] {
            s = s.replacingOccurrences(of: word, with: " ")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func suggest(country: String, names: [String]) -> PackRegion? {
        let cc = country.uppercased()
        let wanted = Set(names.map(normalize).filter { $0.count >= 4 })
        let candidates = PackCatalog.all.filter { $0.country == cc }
        func matches(_ r: PackRegion) -> Bool { wanted.contains(normalize(r.name)) }
        if let region = candidates.first(where: { !$0.parent.isEmpty && matches($0) }) { return region }
        if let whole = candidates.first(where: { $0.parent.isEmpty && matches($0) }) { return whole }
        if cc == "US" || cc == "CA" { return nil }
        if cc == "GB" { return PackCatalog.region("ew") }
        return candidates.first { $0.parent.isEmpty }
    }

    static func fetch(near c: CLLocationCoordinate2D) async -> PackRegion? {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "jsonv2"), URLQueryItem(name: "zoom", value: "10"),
            URLQueryItem(name: "addressdetails", value: "1"), URLQueryItem(name: "accept-language", value: "en"),
            URLQueryItem(name: "lat", value: String(format: "%.5f", c.latitude)), URLQueryItem(name: "lon", value: String(format: "%.5f", c.longitude)),
        ]
        guard let url = components.url, let data = try? await ProviderHTTP.data(url, provider: "Nominatim", timeout: 12),
              let address = (try? JSON.object(data, provider: "Nominatim"))?.dict("address") else { return nil }
        let names = ["county", "state_district", "city", "state", "region", "province", "country"].map { address.string($0) }.filter { !$0.isEmpty }
        return suggest(country: address.string("country_code"), names: names)
    }
}

extension RouteOption {
    /// The part of the line from `start` to `end` metres along it, for drawing a stretch.
    func coordinates(from start: CLLocationDistance, to end: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 2, end > start else { return [] }
        let a = RouteGeometry.index(atProgress: start, cumulative: cumulative) + 1
        let b = RouteGeometry.index(atProgress: end, cumulative: cumulative)
        let middle = a <= b ? Array(coordinates[a...b]) : []
        return [RouteAvoidance.point(at: start, on: self)] + middle + [RouteAvoidance.point(at: end, on: self)]
    }
}
