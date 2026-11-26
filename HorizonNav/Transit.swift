import CoreLocation
import Foundation
import MapKit

/// A public transport trip from Transitous (the community-run MOTIS 2 service at transitous.org): walking and riding legs
/// with their times, stops, platforms and walking paths. Only what the service returns is kept; a field it leaves out
/// (a platform in some regions, a station exit everywhere) stays empty and is not shown.
struct TransitItinerary: Codable, Equatable, Identifiable {
    var id: String
    var start: Date
    var end: Date
    var duration: TimeInterval
    var transfers: Int
    var legs: [TransitLeg]

    var transitLegs: [TransitLeg] { legs.filter(\.isTransit) }
    /// Walking only, from the service's direct connections.
    var isWalkOnly: Bool { transitLegs.isEmpty }
    var hasRealtime: Bool { legs.contains(where: \.realTime) }
    var isCancelled: Bool { legs.contains { $0.isTransit && $0.isCancelled } }
}

struct TransitLeg: Codable, Equatable {
    /// MOTIS mode: WALK, BUS, TRAM, SUBWAY, SUBURBAN, RAIL, FERRY and so on.
    var mode: String
    var from: TransitStop
    var to: TransitStop
    var start: Date
    var end: Date
    var scheduledStart: Date
    var scheduledEnd: Date
    var duration: TimeInterval
    /// Whether the times come from realtime data rather than the timetable.
    var realTime: Bool
    var cancelled: Bool
    /// Metres walked, for walking legs.
    var distance: CLLocationDistance?
    var headsign: String
    /// The name riders know the line by ("U7", "M45", "S15").
    var line: String
    var routeColor: String
    var routeTextColor: String
    var agency: String
    var tripID: String
    /// Stay on board: the vehicle continues under another line name.
    var interlined: Bool
    var intermediateStops: [TransitStop]
    /// The leg's path as [latitude, longitude] pairs.
    var path: [[Double]]
    var steps: [TransitWalkStep]
    /// Service alerts for this leg, header text only.
    var alerts: [String]

    var isWalk: Bool { mode == "WALK" }
    var isTransit: Bool { !TransitLeg.streetModes.contains(mode) }
    var isCancelled: Bool { cancelled || from.cancelled || to.cancelled || from.pickupNotAllowed || to.dropoffNotAllowed }
    var coordinates: [CLLocationCoordinate2D] { path.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil } }
    /// How late the departure is, in seconds, when realtime data says so.
    var departureDelay: TimeInterval { start.timeIntervalSince(scheduledStart) }
    var walkedDistance: CLLocationDistance { distance ?? RouteGeometry.cumulativeDistances(coordinates).last ?? 0 }

    static let streetModes: Set<String> = ["WALK", "BIKE", "RENTAL", "CAR", "HGV", "CAR_PARKING", "CAR_DROPOFF", "DEBUG_BUS_ROUTE", "DEBUG_RAILWAY_ROUTE", "DEBUG_FERRY_ROUTE"]

    var symbolName: String {
        switch mode {
        case "WALK": return "figure.walk"
        case "BUS", "COACH": return "bus.fill"
        case "TRAM": return "tram.fill"
        case "SUBWAY", "METRO": return "tram.fill.tunnel"
        case "FERRY": return "ferry.fill"
        case "AIRPLANE": return "airplane"
        case "FUNICULAR", "AERIAL_LIFT", "AREAL_LIFT", "CABLE_CAR": return "cablecar.fill"
        case "BIKE", "RENTAL": return "bicycle"
        default: return "train.side.front.car"
        }
    }
}

struct TransitStop: Codable, Equatable {
    var name: String
    var stopID: String
    var latitude: Double
    var longitude: Double
    var arrival: Date?
    var departure: Date?
    var scheduledArrival: Date?
    var scheduledDeparture: Date?
    /// The platform or track, with realtime changes where the operator sends them.
    var track: String
    var scheduledTrack: String
    /// The operator's description of the stop point, such as "U Bahnsteig Gleis 2" or which side of the road a bus stops on.
    var detail: String
    /// The stop's time zone, for showing its times as the timetable does.
    var timeZone: String
    var cancelled: Bool
    var pickupNotAllowed: Bool
    var dropoffNotAllowed: Bool
    /// OpenStreetMap level of the stop point, when known (negative underground).
    var level: Double?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var trackChanged: Bool { !track.isEmpty && !scheduledTrack.isEmpty && track != scheduledTrack }
}

/// One stretch of a walking path from the service, with its relative direction, street and level change.
struct TransitWalkStep: Codable, Equatable {
    /// MOTIS direction: DEPART, LEFT, RIGHT, SLIGHTLY_LEFT, HARD_RIGHT, CONTINUE, STAIRS, ELEVATOR, UTURN_LEFT and so on.
    var direction: String
    var distance: CLLocationDistance
    var street: String
    var fromLevel: Double
    var toLevel: Double
    var path: [[Double]]
}

/// Leave now, depart at or arrive by a chosen time.
enum TransitTimeMode: String, CaseIterable, Codable {
    case now
    case departAt
    case arriveBy

    var title: String {
        switch self {
        case .now: return String(localized: "Leave now")
        case .departAt: return String(localized: "Depart at")
        case .arriveBy: return String(localized: "Arrive by")
        }
    }
}

struct TransitQuery: Equatable {
    var origin: CLLocationCoordinate2D
    var destination: CLLocationCoordinate2D
    var timeMode: TransitTimeMode = .now
    var time = Date()

    static func == (a: TransitQuery, b: TransitQuery) -> Bool {
        a.origin.latitude == b.origin.latitude && a.origin.longitude == b.origin.longitude
            && a.destination.latitude == b.destination.latitude && a.destination.longitude == b.destination.longitude
            && a.timeMode == b.timeMode && (a.timeMode == .now || a.time == b.time)
    }
}

struct TransitPlan: Equatable {
    var itineraries: [TransitItinerary]
    var earlierCursor: String?
    var laterCursor: String?
}

/// The Transitous client. Its usage policy asks for a User-Agent naming the app, its version and a contact, a light load
/// (so nothing here polls: a plan is asked for when the person searches, and a trip's realtime state at most every few
/// minutes while it is being followed), and a visible link to the data sources, which the transit screens show.
enum TransitousClient {
    static let base = URL(string: "https://api.transitous.org/api/")!
    static let sourcesURL = URL(string: "https://transitous.org/sources/")!
    static let homeURL = URL(string: "https://transitous.org")!
    static let openStreetMapCopyright = URL(string: "https://www.openstreetmap.org/copyright")!
    static let provider = "Transitous"

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "HorizonNav-iOS/\(version) (https://github.com/peterdsp/horizon-ios)"
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Answers kept for a short while, so going back to a list or reopening a trip does not ask again.
    private static let cache = NSCache<NSURL, CachedAnswer>()
    static let cacheLifetime: TimeInterval = 90

    private final class CachedAnswer {
        let data: Data
        let date: Date
        init(data: Data, date: Date) { self.data = data; self.date = date }
    }

    /// The `plan` request: walking at both ends, routed transfers so the path between platforms comes back with steps.
    static func planURL(for query: TransitQuery, cursor: String? = nil, language: String = AppLocale.current.language.languageCode?.identifier ?? "en") -> URL {
        var components = URLComponents(url: base.appendingPathComponent("v6/plan"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "fromPlace", value: coordinateText(query.origin)),
            URLQueryItem(name: "toPlace", value: coordinateText(query.destination)),
            URLQueryItem(name: "detailedTransfers", value: "true"),
            URLQueryItem(name: "useRoutedTransfers", value: "true"),
            URLQueryItem(name: "language", value: language),
        ]
        if query.timeMode != .now {
            items.append(URLQueryItem(name: "time", value: isoFormatter.string(from: query.time)))
            if query.timeMode == .arriveBy { items.append(URLQueryItem(name: "arriveBy", value: "true")) }
        }
        if let cursor { items.append(URLQueryItem(name: "pageCursor", value: cursor)) }
        components.queryItems = items
        return components.url!
    }

    static func tripURL(tripID: String, language: String = AppLocale.current.language.languageCode?.identifier ?? "en") -> URL {
        var components = URLComponents(url: base.appendingPathComponent("v6/trip"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "tripId", value: tripID), URLQueryItem(name: "language", value: language)]
        return components.url!
    }

    static func plan(_ query: TransitQuery, cursor: String? = nil) async throws -> TransitPlan {
        try parsePlan(try await data(planURL(for: query, cursor: cursor)))
    }

    /// A trip as it runs now, from its first stop to its last, for realtime times and cancellations.
    static func trip(_ tripID: String) async throws -> TransitItinerary {
        let object = try JSON.object(try await data(tripURL(tripID: tripID), cached: false), provider: provider)
        guard let itinerary = itinerary(object) else { throw ProviderError.badResponse(provider: provider) }
        return itinerary
    }

    private static func data(_ url: URL, cached: Bool = true) async throws -> Data {
        if cached, let answer = cache.object(forKey: url as NSURL), Date().timeIntervalSince(answer.date) < cacheLifetime { return answer.data }
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 25))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProviderError.http(provider: provider, status: status, body: String(decoding: data.prefix(400), as: UTF8.self))
        }
        cache.setObject(CachedAnswer(data: data, date: Date()), forKey: url as NSURL)
        return data
    }

    private static func coordinateText(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.6f,%.6f", c.latitude, c.longitude)
    }

    // MARK: Parsing

    static func parsePlan(_ data: Data) throws -> TransitPlan {
        let object = try JSON.object(data, provider: provider)
        guard object["itineraries"] != nil else { throw ProviderError.badResponse(provider: provider) }
        // Walking all the way, when the service offers it, is one more option to compare.
        let found = object.array("itineraries").compactMap(itinerary) + object.array("direct").compactMap(itinerary).filter(\.isWalkOnly)
        let earlier = object.string("previousPageCursor"), later = object.string("nextPageCursor")
        return TransitPlan(itineraries: found, earlierCursor: earlier.isEmpty ? nil : earlier, laterCursor: later.isEmpty ? nil : later)
    }

    static func itinerary(_ o: [String: Any]) -> TransitItinerary? {
        guard let start = date(o.string("startTime")), let end = date(o.string("endTime")) else { return nil }
        let legs = o.array("legs").compactMap(leg)
        guard !legs.isEmpty else { return nil }
        let id = o.string("id").isEmpty ? "\(start.timeIntervalSince1970)-\(legs.map(\.line).joined(separator: "-"))" : o.string("id")
        return TransitItinerary(id: id, start: start, end: end, duration: o.double("duration") ?? end.timeIntervalSince(start),
                                transfers: o.int("transfers") ?? 0, legs: legs)
    }

    static func leg(_ o: [String: Any]) -> TransitLeg? {
        guard let from = o.dict("from").map(stop), let to = o.dict("to").map(stop),
              let start = date(o.string("startTime")), let end = date(o.string("endTime")) else { return nil }
        let geometry = o.dict("legGeometry")
        let line = [o.string("displayName"), o.string("routeShortName"), o.string("tripShortName"), o.string("routeLongName")].first { !$0.isEmpty } ?? ""
        return TransitLeg(
            mode: o.string("mode"), from: from, to: to, start: start, end: end,
            scheduledStart: date(o.string("scheduledStartTime")) ?? start, scheduledEnd: date(o.string("scheduledEndTime")) ?? end,
            duration: o.double("duration") ?? end.timeIntervalSince(start), realTime: o.bool("realTime"), cancelled: o.bool("cancelled"),
            distance: o.double("distance"), headsign: o.string("headsign"), line: line,
            routeColor: o.string("routeColor"), routeTextColor: o.string("routeTextColor"), agency: o.string("agencyName"),
            tripID: o.string("tripId"), interlined: o.bool("interlineWithPreviousLeg"),
            intermediateStops: o.array("intermediateStops").map(stop),
            path: geometry.map(points) ?? [],
            steps: o.array("steps").map(walkStep),
            alerts: o.array("alerts").map { $0.string("headerText") }.filter { !$0.isEmpty })
    }

    static func stop(_ o: [String: Any]) -> TransitStop {
        TransitStop(name: o.string("name"), stopID: o.string("stopId"), latitude: o.double("lat") ?? 0, longitude: o.double("lon") ?? 0,
                    arrival: date(o.string("arrival")), departure: date(o.string("departure")),
                    scheduledArrival: date(o.string("scheduledArrival")), scheduledDeparture: date(o.string("scheduledDeparture")),
                    track: o.string("track"), scheduledTrack: o.string("scheduledTrack"), detail: o.string("description"),
                    timeZone: o.string("tz"), cancelled: o.bool("cancelled"),
                    pickupNotAllowed: o.string("pickupType") == "NOT_ALLOWED", dropoffNotAllowed: o.string("dropoffType") == "NOT_ALLOWED",
                    level: o.double("level"))
    }

    static func walkStep(_ o: [String: Any]) -> TransitWalkStep {
        TransitWalkStep(direction: o.string("relativeDirection"), distance: o.double("distance") ?? 0, street: o.string("streetName"),
                        fromLevel: o.double("fromLevel") ?? 0, toLevel: o.double("toLevel") ?? 0, path: o.dict("polyline").map(points) ?? [])
    }

    /// An encoded polyline at the precision the answer states (6 in this API version).
    static func points(_ polyline: [String: Any]) -> [[Double]] {
        let precision = polyline.int("precision") ?? 6
        let scale = pow(10, Double(precision - 6))
        return Polyline6.decode(polyline.string("points")).map { [$0.latitude / scale, $0.longitude / scale] }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        return isoFormatter.date(from: text) ?? fractionalFormatter.date(from: text)
    }
}

/// How itineraries compare: arrival, transfers, walking and the tightest change, for sorting and the list's badges.
enum TransitSort: String, CaseIterable {
    case arrival
    case transfers
    case walking

    var title: String {
        switch self {
        case .arrival: return String(localized: "Earliest arrival")
        case .transfers: return String(localized: "Fewest changes")
        case .walking: return String(localized: "Least walking")
        }
    }
}

enum TransitComparison {
    /// Seconds spent walking, from the walking legs' own durations.
    static func walkingTime(_ itinerary: TransitItinerary) -> TimeInterval {
        itinerary.legs.filter(\.isWalk).reduce(0) { $0 + $1.duration }
    }

    static func walkingDistance(_ itinerary: TransitItinerary) -> CLLocationDistance {
        itinerary.legs.filter(\.isWalk).reduce(0) { $0 + $1.walkedDistance }
    }

    /// The shortest time between arriving on one vehicle and leaving on the next, walk included. Nil with no change.
    static func shortestTransfer(_ itinerary: TransitItinerary) -> TimeInterval? {
        let rides = itinerary.legs.filter(\.isTransit)
        guard rides.count > 1 else { return nil }
        var windows: [TimeInterval] = []
        for i in 1..<rides.count where !rides[i].interlined {
            windows.append(rides[i].start.timeIntervalSince(rides[i - 1].end))
        }
        return windows.min()
    }

    static func sorted(_ itineraries: [TransitItinerary], by sort: TransitSort) -> [TransitItinerary] {
        itineraries.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            switch sort {
            case .arrival:
                if x.end != y.end { return x.end < y.end }
                if x.transfers != y.transfers { return x.transfers < y.transfers }
            case .transfers:
                if x.transfers != y.transfers { return x.transfers < y.transfers }
                if x.end != y.end { return x.end < y.end }
            case .walking:
                let wx = walkingTime(x), wy = walkingTime(y)
                if wx != wy { return wx < wy }
                if x.end != y.end { return x.end < y.end }
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Which comparisons each itinerary wins, so the list can say "Earliest" or "Least walking" on it. Cancelled ones win none.
    static func best(_ itineraries: [TransitItinerary]) -> [String: Set<TransitSort>] {
        let usable = itineraries.filter { !$0.isCancelled }
        var out: [String: Set<TransitSort>] = [:]
        for sort in TransitSort.allCases {
            if let first = sorted(usable, by: sort).first { out[first.id, default: []].insert(sort) }
        }
        return out
    }
}

/// Times as the timetable shows them: in the stop's own time zone when the service gives it.
enum TransitFormat {
    static func time(_ date: Date?, zone: String = "") -> String {
        guard let date else { return "" }
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        if let tz = TimeZone(identifier: zone) { style.timeZone = tz }
        return date.formatted(style)
    }

    static func dayAndTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(60, seconds.rounded())).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static func distance(_ metres: CLLocationDistance) -> String {
        Measurement(value: max(metres, 0), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    static func platform(_ stop: TransitStop) -> String? {
        guard !stop.track.isEmpty else { return nil }
        return String(localized: "Platform \(stop.track)")
    }

    /// "+3 min" for a late departure in realtime data, "-2 min" for an early one.
    static func delay(_ leg: TransitLeg) -> String? {
        guard leg.realTime else { return nil }
        let minutes = Int((leg.departureDelay / 60).rounded())
        guard minutes != 0 else { return nil }
        return minutes > 0 ? String(localized: "+\(minutes) min") : String(localized: "\(minutes) min")
    }
}
