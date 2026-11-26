import CoreLocation
import Foundation
import MapKit

/// A searched place whose provider gave a separate entrance to drive to (TomTom entry points, Mapbox routable points): the
/// placemark is the entrance, `building` the place itself.
final class EntrancePlaceItem: MKMapItem {
    var building = kCLLocationCoordinate2DInvalid
}

/// A car park near the destination, from OpenStreetMap.
struct ParkingSpot: Identifiable, Equatable {
    let id = UUID()
    var name: String
    /// Where to drive: the mapped vehicle entrance when there is one, otherwise the car park itself.
    var coordinate: CLLocationCoordinate2D
    var details: String
    /// Straight-line distance to the destination.
    var distance: CLLocationDistance
    var hasMappedEntrance: Bool

    static func == (a: ParkingSpot, b: ParkingSpot) -> Bool { a.id == b.id }

    /// "4 min walk" at 80 m a minute (Android `checkParking`).
    var walkMinutes: Int { max(1, Int((distance / 80).rounded())) }

    var mapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }
}

/// Parking near the destination, ported from the Android `NavEngine.checkParking` and `Overpass.nearby("parking")`: car parks
/// within 700 m from OpenStreetMap, nearest first, offered from 1.7 km out on trips of 3 km or more. The car park's mapped
/// vehicle entrance (`amenity=parking_entrance`), when there is one within 150 m, is used as the place to drive to.
enum ParkingSearch {
    static let radius = 700
    static let maxResults = 3
    static let offerFrom: CLLocationDistance = 1700
    static let offerUntil: CLLocationDistance = 150
    static let minimumTrip: CLLocationDistance = 3000
    static let attempts = 3
    static let retryAfter: TimeInterval = 40

    /// Whether to look for parking now: close to the destination, on a trip long enough, not already going to a car park.
    static func shouldOffer(remaining: CLLocationDistance, routeLength: CLLocationDistance, destinationName: String) -> Bool {
        remaining > offerUntil && remaining < offerFrom && routeLength >= minimumTrip && !isCarPark(destinationName)
    }

    /// A destination that is itself a car park needs no parking offer.
    static func isCarPark(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["parking", "car park", "multi-storey", "parkhaus", "parkplatz"].contains(where: lower.contains)
    }

    static func query(near c: CLLocationCoordinate2D) -> String {
        let at = String(format: "%.5f,%.5f", c.latitude, c.longitude)
        return "[out:json][timeout:20];(node(around:\(radius),\(at))[\"amenity\"=\"parking\"];way(around:\(radius),\(at))[\"amenity\"=\"parking\"];"
            + "node(around:\(radius + 150),\(at))[\"amenity\"=\"parking_entrance\"];);out center tags 80;"
    }

    static func find(near destination: CLLocationCoordinate2D) async -> [ParkingSpot] {
        let body = Data(("data=" + RouteStopSearch.percentEncoded(query(near: destination))).utf8)
        for endpoint in SpeedCameras.endpoints.prefix(3) {
            if let data = try? await ProviderHTTP.data(endpoint, provider: "Overpass", timeout: 25, body: body, contentType: "application/x-www-form-urlencoded"),
               let spots = try? parse(data, destination: destination) {
                return spots
            }
        }
        return []
    }

    static func parse(_ data: Data, destination: CLLocationCoordinate2D) throws -> [ParkingSpot] {
        let root = try JSON.object(data, provider: "Overpass")
        let remark = root.string("remark").lowercased()
        if remark.contains("error") || remark.contains("timed out") || remark.contains("timeout") { throw ProviderError.badResponse(provider: "Overpass") }
        var parks: [(CLLocationCoordinate2D, [String: Any])] = []
        var entrances: [CLLocationCoordinate2D] = []
        for e in root.array("elements") {
            let center = e.dict("center")
            guard let lat = e.double("lat") ?? center?.double("lat"), let lon = e.double("lon") ?? center?.double("lon") else { continue }
            let tags = e.dict("tags") ?? [:]
            let access = tags.string("access")
            guard access != "private" && access != "no" else { continue }
            let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            if tags.string("amenity") == "parking_entrance" { entrances.append(c) } else if tags.string("amenity") == "parking" { parks.append((c, tags)) }
        }
        let spots = parks.compactMap { c, tags -> ParkingSpot? in
            let distance = RouteGeometry.distance(c, destination)
            guard distance < 800 else { return nil }
            // An entrance belongs to the car park nearest it, and only within 150 m.
            let own = entrances.filter { e in
                RouteGeometry.distance(e, c) < 150 && !parks.contains { RouteGeometry.distance(e, $0.0) < RouteGeometry.distance(e, c) }
            }
            let entrance = own.min { RouteGeometry.distance($0, c) < RouteGeometry.distance($1, c) }
            let name = [tags.string("name"), tags.string("operator")].first { !$0.isEmpty } ?? String(localized: "Car park")
            return ParkingSpot(name: name, coordinate: entrance ?? c, details: details(tags), distance: distance, hasMappedEntrance: entrance != nil)
        }
        return Array(spots.sorted { $0.distance < $1.distance }.prefix(maxResults))
    }

    /// Price or paid/free, opening hours, spaces and the kind of car park, from the OpenStreetMap tags.
    static func details(_ tags: [String: Any]) -> String {
        var parts: [String] = []
        let charge = tags.string("charge"), fee = tags.string("fee")
        if !charge.isEmpty { parts.append(charge) } else if fee == "yes" { parts.append(String(localized: "Paid")) } else if fee == "no" { parts.append(String(localized: "Free")) }
        let hours = tags.string("opening_hours")
        if hours == "24/7" { parts.append(String(localized: "open 24 h")) } else if !hours.isEmpty { parts.append(hours) }
        if let spaces = Int(tags.string("capacity")) { parts.append(String(localized: "\(spaces) spaces")) }
        switch tags.string("parking") {
        case "multi-storey": parts.append(String(localized: "Multi-storey"))
        case "underground": parts.append(String(localized: "Underground"))
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

/// The entrance a provider gives for a searched place, used as the place to drive to (Android `TomTomRest.geocode` entry
/// points and `MapboxRest.feature` routable points): one within 200 m, TomTom's main entrance first. An entrance on the
/// place itself (under 3 m away) is not a separate one.
enum PlaceEntrance {
    static let maxDistance: CLLocationDistance = 200

    static func tomtom(_ entryPoints: [[String: Any]], place: CLLocationCoordinate2D) -> CLLocationCoordinate2D? {
        let points = entryPoints.compactMap { p -> (String, CLLocationCoordinate2D)? in
            guard let pos = p.dict("position"), let lat = pos.double("lat"), let lon = pos.double("lon") else { return nil }
            return (p.string("type"), CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }.filter { RouteGeometry.distance($0.1, place) <= maxDistance }
        guard let entrance = (points.first { $0.0 == "main" } ?? points.first)?.1 else { return nil }
        return RouteGeometry.distance(entrance, place) >= 3 ? entrance : nil
    }

    static func mapbox(_ routablePoints: [[String: Any]], place: CLLocationCoordinate2D) -> CLLocationCoordinate2D? {
        guard let p = routablePoints.first, let lat = p.double("latitude"), let lon = p.double("longitude") else { return nil }
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let d = RouteGeometry.distance(c, place)
        return d >= 3 && d <= maxDistance ? c : nil
    }
}
