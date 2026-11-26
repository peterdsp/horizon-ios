import CoreLocation
import Foundation
import MapKit

/// A walking leg as a route the guidance engine can follow: the service's path, with manoeuvres where the path really turns
/// or changes level. The service returns a step for every stretch of way, most of them "continue", so the turns are read
/// from the geometry and the small ones are dropped.
struct TransitWalkRoute {
    var route: RouteOption
    /// SF Symbol for each of `route.steps`.
    var symbols: [String]

    /// Turns under this many degrees are walked straight on without a call.
    static let minimumTurn = 35.0
    /// Manoeuvres closer than this to the one before are merged into it.
    static let minimumGap: CLLocationDistance = 8

    init(route: RouteOption, symbols: [String]) {
        self.route = route
        self.symbols = symbols
    }

    /// A route walked to `target` (a stop's name with its platform, or the destination).
    init?(leg: TransitLeg, target: String) {
        var coordinates = leg.coordinates
        if coordinates.count < 2 { coordinates = [leg.from.coordinate, leg.to.coordinate] }
        let cumulative = RouteGeometry.cumulativeDistances(coordinates)
        guard let length = cumulative.last, length > 0 else { return nil }
        var steps: [RouteStep] = []
        var symbols: [String] = []
        var offset: CLLocationDistance = 0
        for (i, step) in leg.steps.enumerated() {
            let points = step.path.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
            let stepLength = points.count > 1 ? (RouteGeometry.cumulativeDistances(points).last ?? step.distance) : step.distance
            defer { offset += stepLength }
            guard i > 0, offset < length - Self.minimumGap else { continue }
            let vertex = RouteGeometry.index(atProgress: offset, cumulative: cumulative)
            guard let call = Self.call(for: step, angle: RouteGeometry.turnAngle(in: coordinates, at: vertex, reach: 8)) else { continue }
            if let last = steps.last, offset - last.startProgress < Self.minimumGap, call.symbol != "figure.stairs" { continue }
            steps.append(RouteStep(instruction: call.text, notice: nil, distance: stepLength, startProgress: offset,
                                   turnAngle: call.angle, isArrival: false, maneuver: call.maneuver, street: step.street))
            symbols.append(call.symbol)
        }
        // Each manoeuvre's distance runs to the next one.
        for i in steps.indices { steps[i].distance = (i + 1 < steps.count ? steps[i + 1].startProgress : length) - steps[i].startProgress }
        steps.append(RouteStep(instruction: String(localized: "Arrive at \(target)"), notice: nil, distance: 0, startProgress: length,
                               turnAngle: nil, isArrival: true, maneuver: .arrive))
        symbols.append("flag.checkered")
        route = RouteOption(name: String(localized: "Walk"), distance: leg.walkedDistance, expectedTravelTime: leg.duration,
                            coordinates: coordinates, steps: steps, advisories: [], source: .online(TransitousClient.provider))
        self.symbols = symbols
    }

    /// A walk rerouted by Apple Maps after the walker left the path.
    init(appleRoute: MKRoute) {
        route = MapKitRoutingProvider.option(from: appleRoute, source: .online("Apple Maps"))
        symbols = route.steps.map(\.symbolName)
    }

    private struct Call {
        var text: String
        var symbol: String
        var maneuver: Maneuver
        var angle: Double?
    }

    /// What to say at the start of one walking step: stairs and lifts always, turns when the path turns enough.
    private static func call(for step: TransitWalkStep, angle: Double?) -> Call? {
        let up = step.toLevel > step.fromLevel, down = step.toLevel < step.fromLevel
        if step.direction == "ELEVATOR" {
            let text = up ? String(localized: "Take the lift up") : down ? String(localized: "Take the lift down") : String(localized: "Take the lift")
            return Call(text: text, symbol: "arrow.up.arrow.down.square", maneuver: .unknown, angle: angle)
        }
        if step.direction == "STAIRS" || up || down {
            let text = up ? String(localized: "Take the stairs up") : down ? String(localized: "Take the stairs down") : String(localized: "Take the stairs")
            return Call(text: text, symbol: "figure.stairs", maneuver: .unknown, angle: angle)
        }
        let maneuver: Maneuver
        switch step.direction {
        case "LEFT": maneuver = .turnLeft
        case "RIGHT": maneuver = .turnRight
        case "SLIGHTLY_LEFT": maneuver = .bearLeft
        case "SLIGHTLY_RIGHT": maneuver = .bearRight
        case "HARD_LEFT": maneuver = .sharpLeft
        case "HARD_RIGHT": maneuver = .sharpRight
        case "UTURN_LEFT", "UTURN_RIGHT": maneuver = .uTurn
        case "CIRCLE_CLOCKWISE", "CIRCLE_COUNTERCLOCKWISE": maneuver = .roundaboutCross
        default:
            guard let angle, abs(angle) >= minimumTurn else { return nil }
            switch abs(angle) {
            case ..<60: maneuver = angle > 0 ? .bearRight : .bearLeft
            case ..<135: maneuver = angle > 0 ? .turnRight : .turnLeft
            case ..<165: maneuver = angle > 0 ? .sharpRight : .sharpLeft
            default: maneuver = .uTurn
            }
        }
        let word = maneuver.phrase() ?? String(localized: "continue")
        let text = step.street.isEmpty ? word.capitalizedFirst : word.capitalizedFirst + String(localized: " onto \(step.street)")
        return Call(text: text, symbol: maneuver.symbolName ?? "arrow.up", maneuver: maneuver, angle: angle ?? maneuver.angle)
    }
}

/// Spoken walking directions: one call about 50 metres before a turn and one as it comes. Pure, so the timing is tested.
struct WalkingPromptPlanner {
    static let earlyFrom: CLLocationDistance = 60
    static let earlyUntil: CLLocationDistance = 25
    static let nowDistance: CLLocationDistance = 15

    private(set) var said: Set<String> = []

    mutating func reset() { said.removeAll() }

    mutating func prompts(stepIndex: Int, step: RouteStep, distance d: CLLocationDistance, imperial: Bool) -> [VoicePrompt] {
        guard !step.isArrival else { return [] }
        let phrase = VoicePromptPlanner.phrase(for: step)
        var out: [VoicePrompt] = []
        if d <= Self.earlyFrom, d > Self.earlyUntil, said.insert("w\(stepIndex)e").inserted {
            out.append(VoicePrompt(key: "w\(stepIndex)e", text: String(localized: "In \(VoicePromptPlanner.spokenDistance(d, imperial: imperial)), \(phrase)")))
        }
        if d <= Self.nowDistance, said.insert("w\(stepIndex)n").inserted {
            out.append(VoicePrompt(key: "w\(stepIndex)n", text: phrase.capitalizedFirst))
        }
        return out
    }
}

/// Where the rider is on a ride: the stops still to come, the next one, and the time to the stop to get off at.
struct TransitRideProgress: Equatable {
    /// Stops still ahead, counting the one to get off at.
    var stopsRemaining: Int
    var nextStop: TransitStop?
    var secondsToArrival: TimeInterval
    var departed: Bool
    /// Metres along the line to the stop to get off at, when the position is good enough to tell.
    var metresToStop: CLLocationDistance?
}

enum TransitRide {
    /// A fix counts for the position on the line when it is recent, reasonably accurate and close to the line. Underground,
    /// or with a stale fix, the timetable says where the vehicle is instead.
    static let freshFix: TimeInterval = 45
    static let usableAccuracy: CLLocationAccuracy = 100
    static let nearLine: CLLocationDistance = 150
    /// A stop counts as passed this far beyond it.
    static let passedBy: CLLocationDistance = 40

    /// The line of a ride as a route, to measure along. Nil when the service gave no geometry.
    static func line(_ leg: TransitLeg) -> RouteOption? {
        let coordinates = leg.coordinates
        guard coordinates.count >= 2 else { return nil }
        return RouteOption(name: leg.line, distance: 0, expectedTravelTime: leg.duration, coordinates: coordinates,
                           steps: [], advisories: [], source: .online(TransitousClient.provider))
    }

    /// The stops after boarding (the intermediate ones, then the one to get off at), each with its distance along the line.
    static func stopOffsets(_ leg: TransitLeg, line: RouteOption?) -> [CLLocationDistance] {
        let stops = leg.intermediateStops + [leg.to]
        guard let line else { return stops.map { _ in 0 } }
        var segment = 0
        return stops.map { stop in
            // Searched forward from the last stop, so a line that loops back does not match a stop to its earlier pass.
            let p = RouteGeometry.project(stop.coordinate, onto: line, segments: segment..<(line.coordinates.count - 1))
                ?? RouteGeometry.project(stop.coordinate, onto: line)
            segment = p?.segmentIndex ?? segment
            return p?.progress ?? line.length
        }
    }

    static func progress(_ leg: TransitLeg, line: RouteOption?, offsets: [CLLocationDistance], location: CLLocation?, now: Date) -> TransitRideProgress {
        let stops = leg.intermediateStops + [leg.to]
        let arrival = leg.to.arrival ?? leg.end
        if let line, let location, now.timeIntervalSince(location.timestamp) <= freshFix,
           location.horizontalAccuracy >= 0, location.horizontalAccuracy <= usableAccuracy,
           let p = RouteGeometry.project(location.coordinate, onto: line), p.distance <= nearLine {
            let ahead = stops.indices.filter { offsets.indices.contains($0) && offsets[$0] > p.progress + passedBy }
            let target = offsets.last ?? line.length
            return TransitRideProgress(stopsRemaining: ahead.count, nextStop: ahead.first.map { stops[$0] },
                                       secondsToArrival: arrival.timeIntervalSince(now),
                                       departed: now >= leg.start || p.progress > 100, metresToStop: max(target - p.progress, 0))
        }
        // By the timetable: a stop is still ahead until its arrival time.
        let ahead = stops.filter { ($0.arrival ?? $0.departure ?? arrival) > now }
        return TransitRideProgress(stopsRemaining: ahead.count, nextStop: ahead.first, secondsToArrival: arrival.timeIntervalSince(now),
                                   departed: now >= leg.start, metresToStop: nil)
    }
}

/// When to warn before the stop to get off at: a number of stops or minutes before, chosen in Settings.
enum StopAlertSetting: String, CaseIterable, Identifiable {
    case off
    case oneStop
    case twoStops
    case twoMinutes
    case fiveMinutes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .oneStop: return String(localized: "One stop before")
        case .twoStops: return String(localized: "Two stops before")
        case .twoMinutes: return String(localized: "Two minutes before")
        case .fiveMinutes: return String(localized: "Five minutes before")
        }
    }

    var stops: Int? {
        switch self {
        case .oneStop: return 1
        case .twoStops: return 2
        default: return nil
        }
    }

    var minutes: Int? {
        switch self {
        case .twoMinutes: return 2
        case .fiveMinutes: return 5
        default: return nil
        }
    }
}

enum StopAlert: Equatable {
    /// The stop is coming up: so many stops or minutes away.
    case approaching(stops: Int, minutes: Int)
    /// The next stop is the one, and it is close.
    case getOffNow
}

/// Each alert once per ride: the early one at the chosen number of stops or minutes, then one as the stop comes.
struct StopAlertPlanner {
    /// "Get off now" within this distance of the stop, or this long before its arrival time.
    static let arrivingDistance: CLLocationDistance = 350
    static let arrivingTime: TimeInterval = 60

    private(set) var said: Set<String> = []

    mutating func reset() { said.removeAll() }

    mutating func alerts(rideKey: String, progress: TransitRideProgress, setting: StopAlertSetting) -> [StopAlert] {
        guard setting != .off, progress.departed, progress.stopsRemaining > 0 else { return [] }
        var out: [StopAlert] = []
        // Rounded up, so "in 2 minutes" is never said with 2 minutes 40 to go.
        let minutes = max(Int((progress.secondsToArrival / 60).rounded(.up)), 0)
        let early: Bool
        if let stops = setting.stops {
            early = progress.stopsRemaining <= stops
        } else {
            early = progress.secondsToArrival <= Double(setting.minutes ?? 0) * 60
        }
        let arriving = progress.stopsRemaining == 1
            && ((progress.metresToStop.map { $0 <= Self.arrivingDistance } ?? false) || progress.secondsToArrival <= Self.arrivingTime)
        if arriving {
            // Arriving covers the early alert too, when both come due at once.
            if said.insert("\(rideKey)n").inserted {
                said.insert("\(rideKey)e")
                out.append(.getOffNow)
            }
            return out
        }
        if early, said.insert("\(rideKey)e").inserted {
            out.append(.approaching(stops: progress.stopsRemaining, minutes: minutes))
        }
        return out
    }

    /// When the early alert is due by the timetable alone, for a notification scheduled in case the position stops coming.
    static func scheduledTime(for leg: TransitLeg, setting: StopAlertSetting) -> Date? {
        let arrival = leg.to.arrival ?? leg.end
        if let minutes = setting.minutes { return arrival.addingTimeInterval(-Double(minutes) * 60) }
        guard let stops = setting.stops else { return nil }
        // Leaving the stop that is `stops` before the one to get off at.
        let before = leg.intermediateStops.dropLast(max(stops - 1, 0)).last
        return before.flatMap { $0.departure ?? $0.arrival } ?? leg.start
    }
}

/// Something wrong with the rest of the trip, found from realtime data or from where the rider is.
enum TransitProblem: Equatable {
    case cancelled(line: String, stop: String)
    case missed(line: String, stop: String)
    case transferTooShort(line: String, stop: String)

    var message: String {
        switch self {
        case let .cancelled(line, stop): return String(localized: "The \(line) from \(stop) is cancelled.")
        case let .missed(line, stop): return String(localized: "It looks like you missed the \(line) from \(stop).")
        case let .transferTooShort(line, stop): return String(localized: "With the delay, the change to the \(line) at \(stop) is no longer possible.")
        }
    }
}

enum TransitConnectionCheck {
    /// After its departure, a vehicle is taken as missed when the rider is still at the stop this long afterwards: longer
    /// without realtime data, since the vehicle may simply be late.
    static let missedAfterRealtime: TimeInterval = 180
    static let missedAfterTimetable: TimeInterval = 300
    static let atStop: CLLocationDistance = 150
    static let accurateFix: CLLocationAccuracy = 60

    /// The first problem in the trip from the current leg on, if any.
    static func problem(_ itinerary: TransitItinerary, legIndex: Int, location: CLLocation?, rideProgress: CLLocationDistance?, now: Date) -> TransitProblem? {
        let legs = itinerary.legs
        guard legs.indices.contains(legIndex) else { return nil }
        // A cancelled ride still ahead (or the one being waited for).
        for leg in legs[legIndex...] where leg.isTransit && leg.isCancelled {
            if leg.end > now { return .cancelled(line: leg.line, stop: leg.from.name) }
        }
        // A change that the delays made impossible: the next ride leaves before the walk to it can be done.
        let rides = legs.indices.filter { $0 >= legIndex && legs[$0].isTransit }
        for (a, b) in zip(rides, rides.dropFirst()) where !legs[b].interlined && legs[b].start > now {
            let walk = legs[(a + 1)..<b].filter(\.isWalk).reduce(0) { $0 + $1.duration }
            if legs[b].start.timeIntervalSince(legs[a].end) < walk {
                return .transferTooShort(line: legs[b].line, stop: legs[b].from.name)
            }
        }
        // Missed: still walking to a ride that has left, or still at its stop well after it left.
        let current = legs[legIndex]
        let next = legs.indices.contains(legIndex + 1) ? legs[legIndex + 1] : nil
        let wait = { (leg: TransitLeg) in leg.realTime ? missedAfterRealtime : missedAfterTimetable }
        if current.isWalk, let ride = next, ride.isTransit, now.timeIntervalSince(ride.start) > wait(ride) {
            return .missed(line: ride.line, stop: ride.from.name)
        }
        if current.isTransit, now.timeIntervalSince(current.start) > wait(current), let location,
           location.horizontalAccuracy >= 0, location.horizontalAccuracy <= accurateFix,
           now.timeIntervalSince(location.timestamp) < 60,
           RouteGeometry.distance(location.coordinate, current.from.coordinate) <= atStop, (rideProgress ?? 0) < atStop {
            return .missed(line: current.line, stop: current.from.name)
        }
        return nil
    }
}

/// Realtime for one ride from the trip as it runs now: the times, platforms and cancellations of the stops on it.
enum TransitRealtime {
    static func merge(_ leg: TransitLeg, with trip: TransitItinerary) -> TransitLeg {
        guard let ride = trip.legs.first(where: \.isTransit) ?? trip.legs.first else { return leg }
        let stops = [ride.from] + ride.intermediateStops + [ride.to]
        guard let a = stops.firstIndex(where: { $0.stopID == leg.from.stopID }),
              let b = stops.lastIndex(where: { $0.stopID == leg.to.stopID }), a < b else { return leg }
        var out = leg
        out.from = updated(leg.from, from: stops[a])
        out.to = updated(leg.to, from: stops[b])
        let between = Array(stops[(a + 1)..<b])
        if between.count == leg.intermediateStops.count {
            out.intermediateStops = zip(leg.intermediateStops, between).map { updated($0, from: $1) }
        }
        out.start = out.from.departure ?? leg.start
        out.end = out.to.arrival ?? leg.end
        out.realTime = ride.realTime || leg.realTime
        out.cancelled = ride.cancelled
        return out
    }

    private static func updated(_ stop: TransitStop, from live: TransitStop) -> TransitStop {
        var s = stop
        s.arrival = live.arrival ?? stop.arrival
        s.departure = live.departure ?? stop.departure
        if !live.track.isEmpty { s.track = live.track }
        s.cancelled = live.cancelled
        s.pickupNotAllowed = live.pickupNotAllowed
        s.dropoffNotAllowed = live.dropoffNotAllowed
        return s
    }
}

/// The trip being followed, kept on the phone with its legs, stops, times and walking paths so it opens and can be
/// followed with no connection. Its times are the ones known when it was saved.
struct SavedTransitTrip: Codable, Equatable {
    var itinerary: TransitItinerary
    var destinationName: String
    var savedAt: Date

    /// A trip that ended half a day ago is no longer offered.
    func isCurrent(now: Date = Date()) -> Bool { itinerary.end.addingTimeInterval(12 * 3600) > now }
}

enum TransitTripCache {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("saved-transit-trip.json")
    }

    static func save(_ trip: SavedTransitTrip, to url: URL = fileURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(trip).write(to: url, options: .atomic)
    }

    static func load(from url: URL = fileURL) -> SavedTransitTrip? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedTransitTrip.self, from: data)
    }

    static func clear(at url: URL = fileURL) { try? FileManager.default.removeItem(at: url) }
}

/// Transit choices kept with the app's other settings.
enum TransitSettings {
    enum Keys {
        static let travelMode = "travelMode"
        static let stopAlert = "transitStopAlert"
        static let stopHaptics = "transitStopHaptics"
    }

    static var stopAlert: StopAlertSetting {
        AppSettings.defaults.string(forKey: Keys.stopAlert).flatMap(StopAlertSetting.init(rawValue:)) ?? .oneStop
    }

    static var stopHaptics: Bool { AppSettings.defaults.object(forKey: Keys.stopHaptics) as? Bool ?? true }
}
