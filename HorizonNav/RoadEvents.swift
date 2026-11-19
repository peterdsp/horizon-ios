import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct RoadPoint: Codable, Hashable, Sendable {
    var lat: Double
    var lon: Double

    func offset(from other: Self) -> SIMD2<Double> {
        let longitude = (lon - other.lon + 540).truncatingRemainder(dividingBy: 360) - 180
        return SIMD2(longitude * 111_195 * cos(other.lat * .pi / 180), (lat - other.lat) * 111_195)
    }

    func distance(to other: Self) -> Double {
        let delta = offset(from: other)
        return hypot(delta.x, delta.y)
    }

    func interpolate(to other: Self, fraction: Double) -> Self {
        let longitude = (other.lon - lon + 540).truncatingRemainder(dividingBy: 360) - 180
        return Self(lat: lat + (other.lat - lat) * fraction,
                    lon: (lon + longitude * fraction + 540).truncatingRemainder(dividingBy: 360) - 180)
    }
}

struct RoadEvent: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case signal, stop, rail

        var title: String {
            switch self {
            case .signal: return "Traffic lights"
            case .stop: return "Stop sign"
            case .rail: return "Rail crossing"
            }
        }

        var symbol: String {
            switch self {
            case .signal: return "trafficlight"
            case .stop: return "octagon.fill"
            case .rail: return "tram.fill"
            }
        }
    }

    let nodeID: Int64
    let kind: Kind
    let point: RoadPoint
    let progress: Double
    let crossingBarrier: String?

    // The same OSM node can legitimately be traversed twice on a looping route.
    var id: String { "\(nodeID):\(Int(progress.rounded()))" }

    static func upcoming(_ events: [Self], progress: Double, within distance: Double = 2_000) -> [Self] {
        events.filter { $0.progress > progress && $0.progress <= progress + distance }
    }
}

struct RoadCorridor: Sendable {
    let points: [RoadPoint]
    let progress: [Double]

    func point(at distance: Double) -> RoadPoint? {
        guard let first = points.first, let last = points.last, let end = progress.last else { return nil }
        if distance <= progress[0] { return first }
        if distance >= end { return last }
        var lower = 0
        var upper = progress.count - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if progress[middle] <= distance { lower = middle } else { upper = middle }
        }
        let span = progress[upper] - progress[lower]
        return points[lower].interpolate(to: points[upper], fraction: span > 0 ? (distance - progress[lower]) / span : 0)
    }

    // Trim using the original route's progress so the result shares the guidance engine's metre scale.
    func slice(from start: Double, to end: Double) -> Self {
        guard let first = point(at: start), let last = point(at: end) else { return self }
        let interior = progress.indices.filter { progress[$0] > start && progress[$0] < end }
        return Self(points: [first] + interior.map { points[$0] } + [last],
                    progress: [start] + interior.map { progress[$0] } + [end])
    }

    var samples: [RoadPoint] {
        guard let start = progress.first, let end = progress.last else { return [] }
        return stride(from: start, to: end, by: 60).compactMap(point(at:)) + Array(points.suffix(1))
    }

    func candidates(near point: RoadPoint) -> [(progress: Double, offset: Double)] {
        var candidates: [(progress: Double, offset: Double)] = []
        for index in points.indices.dropLast() {
            let a = points[index].offset(from: point)
            let delta = points[index + 1].offset(from: point) - a
            let length = delta.x * delta.x + delta.y * delta.y
            guard length > 0.01 else { continue }
            let fraction = min(1, max(0, -(a.x * delta.x + a.y * delta.y) / length))
            let offset = hypot(a.x + delta.x * fraction, a.y + delta.y * fraction)
            guard offset <= 8 else { continue }
            let position = progress[index] + (progress[index + 1] - progress[index]) * fraction
            if let previous = candidates.last, position - previous.progress < 14 {
                if offset < previous.offset { candidates[candidates.count - 1] = (position, offset) }
            } else {
                candidates.append((position, offset))
            }
        }
        return candidates
    }
}

struct OverpassRoadData: Decodable, Sendable {
    struct Element: Decodable, Sendable {
        var type: String
        var id: Int64
        var lat: Double?
        var lon: Double?
        var nodes: [Int64]?
        var geometry: [RoadPoint]?
        var tags: [String: String]?

        var point: RoadPoint? {
            guard let lat, let lon, abs(lat) <= 90, abs(lon) <= 180 else { return nil }
            return RoadPoint(lat: lat, lon: lon)
        }

        var kind: RoadEvent.Kind? {
            guard type == "node" else { return nil }
            if tags?["railway"] == "level_crossing" { return .rail }
            if tags?["highway"] == "stop" { return .stop }
            if tags?["highway"] == "traffic_signals" { return .signal }
            return nil
        }
    }

    let elements: [Element]
    let remark: String?
}

enum RoadEventMatcher {
    private struct Approach {
        let score: Double
        let forward: Bool
        let oneWay: String?
    }

    static func match(_ data: OverpassRoadData, corridor: RoadCorridor) -> [RoadEvent] {
        let nodes = data.elements.filter { $0.kind != nil }
        let ids = Set(nodes.map(\.id))
        var parents: [Int64: [OverpassRoadData.Element]] = [:]
        for way in data.elements where way.type == "way" {
            guard let nodes = way.nodes, let geometry = way.geometry, nodes.count == geometry.count else { continue }
            for id in nodes where ids.contains(id) { parents[id, default: []].append(way) }
        }
        var events: [RoadEvent] = []
        for node in nodes {
            guard let point = node.point, let kind = node.kind, let ways = parents[node.id] else { continue }
            let tags = node.tags ?? [:]
            // Directional tags are relative to a single OSM way's node order.
            let direction = kind == .signal ? tags["traffic_signals:direction"] ?? tags["direction"] : tags["direction"]
            let explicitDirection = direction != nil && direction != "both"
            if kind != .rail, explicitDirection, ways.count != 1 { continue }
            if kind == .signal, direction == nil, ways.count < 2,
               ways.first?.tags?["oneway"].map({ !["yes", "1", "true", "-1"].contains($0) }) ?? true { continue }
            for candidate in corridor.candidates(near: point) {
                // Closely spaced carriageways can have identical bearings, so require centreline agreement too.
                guard candidate.offset <= 3 else { continue }
                guard let approach = bestApproach(for: node.id, on: ways, route: corridor, at: candidate.progress) else { continue }
                guard kind == .rail || applies(kind, tags: tags, direction: direction, approach: approach) else { continue }
                let barrier = tags["crossing:barrier"].flatMap {
                    ["yes", "full", "half", "double_half", "no"].contains($0) ? $0 : nil
                }
                events.append(RoadEvent(nodeID: node.id, kind: kind, point: point, progress: candidate.progress,
                                        crossingBarrier: kind == .rail ? barrier : nil))
            }
        }
        return events.sorted { ($0.progress, $0.nodeID) < ($1.progress, $1.nodeID) }
    }

    private static func applies(_ kind: RoadEvent.Kind, tags: [String: String], direction: String?, approach: Approach) -> Bool {
        switch direction {
        case "forward": return approach.forward
        case "backward": return !approach.forward
        case "both": return true
        case nil:
            // An unqualified STOP on a two-way road cannot tell us which approach is controlled.
            return kind == .signal || tags["stop"] == "all" || approach.oneWay != nil
        default: return false
        }
    }

    private static func bestApproach(for id: Int64, on ways: [OverpassRoadData.Element], route: RoadCorridor,
                                     at progress: Double) -> Approach? {
        guard let start = route.progress.first, progress - start >= 24,
              let near = route.point(at: progress - 10), let far = route.point(at: progress - 24) else { return nil }
        var matches: [Approach] = []
        for way in ways {
            guard let index = way.nodes?.firstIndex(of: id), let geometry = way.geometry else { continue }
            let rawOneWay = way.tags?["oneway"]
            let oneWay: String? = ["yes", "1", "true", "-1"].contains(rawOneWay ?? "") ? rawOneWay :
                (rawOneWay == nil && ["motorway", "motorway_link"].contains(way.tags?["highway"] ?? "") ? "yes" : nil)
            for forward in [true, false] {
                if let oneWay, forward == (oneWay == "-1") { continue }
                let approach = forward ? Array(geometry[...index].reversed()) : Array(geometry[index...])
                guard let a = point(on: approach, at: 10), let b = point(on: approach, at: 24) else { continue }
                let nearError = near.distance(to: a)
                let farError = far.distance(to: b)
                guard nearError <= 6, farError <= 7 else { continue }
                matches.append(Approach(score: nearError + farError, forward: forward, oneWay: oneWay))
            }
        }
        matches.sort { $0.score < $1.score }
        guard let best = matches.first else { return nil }
        if matches.count > 1, matches[1].score - best.score < 3 { return nil }
        return best
    }

    private static func point(on geometry: [RoadPoint], at distance: Double) -> RoadPoint? {
        var remaining = distance
        for (a, b) in zip(geometry, geometry.dropFirst()) {
            let length = a.distance(to: b)
            if length >= remaining { return a.interpolate(to: b, fraction: remaining / length) }
            remaining -= length
        }
        return nil
    }
}

/// A bounded cache of recent corridor responses. Cache entries are re-matched against each route's geometry.
actor RoadEventService {
    enum Failure: Error { case unavailable, partialResponse, rateLimited }

    static let shared = RoadEventService()
    private static let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
    ]
    private let download: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private var cache: [String: (date: Date, data: OverpassRoadData)] = [:]
    private var retryAfter = Date.distantPast

    init(download: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }) {
        self.download = download
    }

    func events(along corridor: RoadCorridor, online: Bool) async throws -> [RoadEvent] {
        try Task.checkCancellation()
        let points = corridor.samples.map {
            String(format: "%.5f,%.5f", locale: Locale(identifier: "en_US_POSIX"), $0.lat, $0.lon)
        }.joined(separator: ",")
        guard !points.isEmpty else { return [] }
        if let cached = cache[points], Date().timeIntervalSince(cached.date) < 3_600 {
            return RoadEventMatcher.match(cached.data, corridor: corridor)
        }
        guard online else { throw Failure.unavailable }
        guard Date() >= retryAfter else { throw Failure.rateLimited }
        let around = "(around:70,\(points))"
        let query = """
        [out:json][timeout:10];
        (node\(around)["highway"~"^(stop|traffic_signals)$"];
         node\(around)["railway"="level_crossing"];)->.events;
        .events out body;
        way(bn.events)["highway"];
        out body geom;
        """
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) else { throw Failure.unavailable }
        let decoded = try await fetch(Data("data=\(encoded)".utf8))
        if cache.count >= 12, let oldest = cache.min(by: { $0.value.date < $1.value.date })?.key {
            cache.removeValue(forKey: oldest)
        }
        cache[points] = (Date(), decoded)
        return RoadEventMatcher.match(decoded, corridor: corridor)
    }

    private func fetch(_ query: Data) async throws -> OverpassRoadData {
        var lastError: Error = Failure.unavailable
        for endpoint in Self.endpoints {
            try Task.checkCancellation()
            var request = URLRequest(url: endpoint, timeoutInterval: 14)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = query
            do {
                let (body, response) = try await download(request)
                try Task.checkCancellation()
                let http = response as? HTTPURLResponse
                let status = http?.statusCode
                if status == 429 {
                    let seconds = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 300
                    retryAfter = Date().addingTimeInterval(max(60, seconds))
                    throw Failure.rateLimited
                }
                guard status == 200, body.count <= 8_000_000 else { throw Failure.unavailable }
                let decoded = try JSONDecoder().decode(OverpassRoadData.self, from: body)
                guard decoded.remark == nil else { throw Failure.partialResponse }
                return decoded
            } catch Failure.rateLimited {
                throw Failure.rateLimited
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError
    }
}
