import CoreLocation
import Foundation
import MapKit

/// The one-tap stop categories of the Android "Find along the route" list.
enum StopKind: String, CaseIterable, Identifiable {
    case fuel, charging, coffee, food, services, toilets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fuel: return String(localized: "Fuel")
        case .charging: return String(localized: "Charging")
        case .coffee: return String(localized: "Coffee")
        case .food: return String(localized: "Food")
        case .services: return String(localized: "Services")
        case .toilets: return String(localized: "Toilets")
        }
    }

    var symbol: String {
        switch self {
        case .fuel: return "fuelpump.fill"
        case .charging: return "bolt.car.fill"
        case .coffee: return "cup.and.saucer.fill"
        case .food: return "fork.knife"
        case .services: return "parkingsign.circle.fill"
        case .toilets: return "toilet.fill"
        }
    }

    /// TomTom search text (Android `Geo.poiQuery`).
    var tomtomQuery: String {
        switch self {
        case .fuel: return "petrol station"
        case .charging: return "electric vehicle station"
        case .coffee: return "cafe"
        case .food: return "restaurant"
        case .services: return "rest area"
        case .toilets: return "toilet"
        }
    }

    /// Mapbox Search Box categories, tried in order (Android `mapboxAlong`).
    var mapboxCategories: [String] {
        switch self {
        case .fuel: return ["gas_station"]
        case .charging: return ["charging_station", "ev_charging_station"]
        case .coffee: return ["coffee", "cafe"]
        case .food: return ["restaurant", "food"]
        case .services: return ["rest_area"]
        case .toilets: return ["toilet", "public_toilet", "restroom"]
        }
    }

    /// OpenStreetMap tags (Android `Overpass.oneFilter`).
    var overpassFilter: String {
        switch self {
        case .fuel: return #"["amenity"="fuel"]"#
        case .charging: return #"["amenity"="charging_station"]"#
        case .coffee: return #"["amenity"="cafe"]"#
        case .food: return #"["amenity"~"^(restaurant|fast_food)$"]"#
        case .services: return #"["highway"~"^(services|rest_area)$"]"#
        case .toilets: return #"["amenity"="toilets"]"#
        }
    }

    /// How far from the route OpenStreetMap places are looked for (Android: 900 m, motorway services 400 m).
    var overpassRadius: Int { self == .services ? 400 : 900 }
}

/// A place found along the route ahead.
struct RouteStop: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var subtitle: String
    var coordinate: CLLocationCoordinate2D
    /// Distance along the route from the car to where the place is level with it.
    var distanceAhead: CLLocationDistance
    /// Extra minutes to drive there and back to the route.
    var detourMinutes: Int

    static func == (a: RouteStop, b: RouteStop) -> Bool { a.id == b.id }

    var mapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }
}

/// Places along the rest of the route, ported from the Android `NavEngine.loadNearby` along-route mode: TomTom's search along
/// the route with its own detour times when there is a TomTom key, Mapbox category search at points along the way with a
/// Mapbox token, and OpenStreetMap through Overpass otherwise or when those find nothing. Only places ahead of the car count.
/// Nil means no service answered, which is not the same as nothing ahead.
enum RouteStopSearch {
    static let maxResults = 15

    static func find(_ kind: StopKind, along route: RouteOption, progress: CLLocationDistance,
                     keys: ProviderKeys = .current) async -> [RouteStop]? {
        var answered = false
        if let key = keys.tomtom {
            let line = line(route, from: progress, to: progress + 80_000, maxPoints: 140)
            if let data = try? await ProviderHTTP.data(tomtomURL(kind, key: key), provider: "TomTom", timeout: 15, body: tomtomBody(line)) {
                answered = true
                let found = place(parseTomTom(data), on: route, progress: progress, maxOff: 3000)
                if !found.isEmpty { return found }
            }
        }
        if let token = keys.mapbox {
            let found = place(await mapbox(kind, token: token, line: line(route, from: progress, to: progress + 60_000, maxPoints: 45)),
                              on: route, progress: progress, maxOff: 1500)
            if !found.isEmpty { return found }
        }
        let line = line(route, from: progress, to: progress + 60_000, maxPoints: 45)
        for endpoint in SpeedCameras.endpoints.prefix(3) {
            let body = Data(("data=" + percentEncoded(overpassQuery(kind, line: line))).utf8)
            if let data = try? await ProviderHTTP.data(endpoint, provider: "Overpass", timeout: 30, body: body, contentType: "application/x-www-form-urlencoded"),
               let places = try? parseOverpass(data, fallbackName: kind.title) {
                return place(places, on: route, progress: progress, maxOff: 1200)
            }
        }
        return answered ? [] : nil
    }

    /// The route from `from` to `to` metres, thinned to at most `maxPoints` points.
    static func line(_ route: RouteOption, from: CLLocationDistance, to: CLLocationDistance, maxPoints: Int) -> [CLLocationCoordinate2D] {
        guard route.coordinates.count >= 2 else { return route.coordinates }
        let a = RouteGeometry.index(atProgress: max(from, 0), cumulative: route.cumulative)
        let b = min(RouteGeometry.index(atProgress: to, cumulative: route.cumulative) + 1, route.coordinates.count - 1)
        let part = Array(route.coordinates[a...max(a + 1, b)])
        return SpeedCameras.thinned(part, maxPoints: maxPoints)
    }

    /// Extra minutes for a place `offRoute` metres from the route: there and back at 11 m/s, plus a minute (Android `detour`).
    static func detourMinutes(offRoute: CLLocationDistance) -> Int {
        Int(((2 * offRoute / 11 + 60) / 60).rounded())
    }

    struct Found: Equatable {
        var name: String
        var subtitle: String
        var coordinate: CLLocationCoordinate2D
        /// The provider's own detour, when it gives one (TomTom).
        var detourSeconds: Double?

        static func == (a: Found, b: Found) -> Bool {
            a.name == b.name && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
        }
    }

    /// Places ahead of the car (no more than 100 m behind), within `maxOff` of the route, nearest along the route first.
    static func place(_ found: [Found], on route: RouteOption, progress: CLLocationDistance, maxOff: CLLocationDistance) -> [RouteStop] {
        var out: [RouteStop] = []
        for f in found {
            guard let p = RouteGeometry.project(f.coordinate, onto: route), p.distance <= maxOff, p.progress >= progress - 100 else { continue }
            if out.contains(where: { RouteGeometry.distance($0.coordinate, f.coordinate) < 80 }) { continue }
            let detour = f.detourSeconds.map { Int(($0 / 60).rounded()) } ?? detourMinutes(offRoute: p.distance)
            out.append(RouteStop(name: f.name, subtitle: f.subtitle, coordinate: f.coordinate,
                                 distanceAhead: max(p.progress - progress, 0), detourMinutes: max(detour, 0)))
        }
        return Array(out.sorted { $0.distanceAhead < $1.distanceAhead }.prefix(maxResults))
    }

    // MARK: TomTom

    static func tomtomURL(_ kind: StopKind, key: String) -> URL {
        let query = kind.tomtomQuery.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? kind.tomtomQuery
        var components = URLComponents(string: "https://api.tomtom.com/search/2/searchAlongRoute/\(query).json")!
        components.queryItems = [
            URLQueryItem(name: "key", value: key), URLQueryItem(name: "maxDetourTime", value: "900"),
            URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "spreadingMode", value: "auto"),
        ]
        return components.url!
    }

    static func tomtomBody(_ line: [CLLocationCoordinate2D]) -> Data {
        let points = line.map { ["lat": $0.latitude, "lon": $0.longitude] }
        return (try? JSONSerialization.data(withJSONObject: ["route": ["points": points]])) ?? Data()
    }

    static func parseTomTom(_ data: Data) -> [Found] {
        guard let root = try? JSON.object(data, provider: "TomTom") else { return [] }
        return root.array("results").compactMap { r in
            guard let pos = r.dict("position"), let lat = pos.double("lat"), let lon = pos.double("lon") else { return nil }
            let name = r.dict("poi")?.string("name") ?? ""
            return Found(name: name.isEmpty ? (r.dict("address")?.string("freeformAddress") ?? "") : name,
                         subtitle: r.dict("address")?.string("freeformAddress") ?? "",
                         coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), detourSeconds: r.double("detourTime"))
        }
    }

    // MARK: Mapbox

    /// Mapbox cannot search along a line: up to 5 points along the way are searched, 3.75 km apart, 2.5 km round each.
    static func mapbox(_ kind: StopKind, token: String, line: [CLLocationCoordinate2D]) async -> [Found] {
        let radius = 2500.0
        let probes = samples(line, every: min(8000, radius * 1.5), max: 5)
        for category in kind.mapboxCategories {
            let found = await withTaskGroup(of: [Found].self) { group in
                for probe in probes {
                    group.addTask {
                        guard let data = try? await ProviderHTTP.data(mapboxURL(category: category, near: probe, radius: radius, token: token), provider: "Mapbox", timeout: 10),
                              let places = try? MapboxSearchProvider.parse(data, query: kind.title) else { return [] }
                        return places.map { Found(name: $0.name, subtitle: $0.subtitle, coordinate: $0.coordinate) }
                    }
                }
                var all: [Found] = []
                for await part in group { all += part }
                return all
            }
            if !found.isEmpty { return found }
        }
        return []
    }

    static func mapboxURL(category: String, near: CLLocationCoordinate2D, radius: CLLocationDistance, token: String) -> URL {
        let dLat = radius / 111_320, dLon = radius / (111_320 * max(cos(near.latitude * .pi / 180), 0.01))
        var components = URLComponents(string: "https://api.mapbox.com/search/searchbox/v1/category/\(category)")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "language", value: MapboxRoutingProvider.languageCode),
            URLQueryItem(name: "proximity", value: String(format: "%.5f,%.5f", near.longitude, near.latitude)),
            URLQueryItem(name: "bbox", value: String(format: "%.5f,%.5f,%.5f,%.5f", near.longitude - dLon, near.latitude - dLat, near.longitude + dLon, near.latitude + dLat)),
            URLQueryItem(name: "access_token", value: token),
        ]
        return components.url!
    }

    /// Points `every` metres along a line, at most `max` of them, starting at its first point.
    static func samples(_ line: [CLLocationCoordinate2D], every gap: CLLocationDistance, max count: Int) -> [CLLocationCoordinate2D] {
        guard let first = line.first else { return [] }
        var out = [first]
        var run = 0.0
        for i in 1..<max(line.count, 1) where out.count < count {
            run += RouteGeometry.distance(line[i - 1], line[i])
            if run >= gap { out.append(line[i]); run = 0 }
        }
        return out
    }

    // MARK: OpenStreetMap

    /// Android `Overpass.nearbyAlong`: nodes and ways with the category's tags within the radius of the line.
    static func overpassQuery(_ kind: StopKind, line: [CLLocationCoordinate2D]) -> String {
        let points = line.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ",")
        let around = "(around:\(kind.overpassRadius),\(points))"
        return "[out:json][timeout:25];(node\(around)\(kind.overpassFilter);way\(around)\(kind.overpassFilter););out center tags 150;"
    }

    static func parseOverpass(_ data: Data, fallbackName: String) throws -> [Found] {
        let root = try JSON.object(data, provider: "Overpass")
        let remark = root.string("remark").lowercased()
        if remark.contains("error") || remark.contains("timed out") || remark.contains("timeout") { throw ProviderError.badResponse(provider: "Overpass") }
        return root.array("elements").compactMap { e in
            let center = e.dict("center")
            guard let lat = e.double("lat") ?? center?.double("lat"), let lon = e.double("lon") ?? center?.double("lon") else { return nil }
            let tags = e.dict("tags") ?? [:]
            let name = [tags.string("name"), tags.string("brand"), tags.string("operator")].first { !$0.isEmpty } ?? fallbackName
            let street = [tags.string("addr:street"), tags.string("addr:city")].filter { !$0.isEmpty }.joined(separator: ", ")
            return Found(name: name, subtitle: street, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
    }

    static func percentEncoded(_ query: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
    }
}
