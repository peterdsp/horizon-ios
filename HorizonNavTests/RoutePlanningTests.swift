import CoreLocation
import Foundation
import MapKit
import Testing
@testable import HorizonNav

/// A straight north-bound road of about `meters`, one point every `spacing` metres, with an arrival at the end.
private func northRoute(meters: Double = 2000, longitude: Double = -0.1, time: TimeInterval = 200, spacing: Double = 50) -> RouteOption {
    let start = CLLocationCoordinate2D(latitude: 51.5, longitude: longitude)
    let coords = stride(from: 0.0, through: meters, by: spacing).map { CLLocationCoordinate2D(latitude: start.latitude + $0 / 111_320, longitude: longitude) }
    let length = RouteGeometry.cumulativeDistances(coords).last ?? meters
    let steps = [
        RouteStep(instruction: "Keep right onto the slip road", notice: nil, distance: length / 2, startProgress: length / 2,
                  turnAngle: 0, isArrival: false, maneuver: .keepRight, street: "Slip Road", exitNumber: "12"),
        RouteStep(instruction: "Arrive", notice: nil, distance: 0, startProgress: length, turnAngle: nil, isArrival: true, maneuver: .arrive),
    ]
    return RouteOption(name: "North", distance: meters, expectedTravelTime: time, coordinates: coords, steps: steps,
                       advisories: [], source: .online("test"))
}

private func request(_ to: CLLocationCoordinate2D = .init(latitude: 51.51, longitude: -0.1)) -> RouteRequest {
    RouteRequest(origin: .init(latitude: 51.5, longitude: -0.12), destination: MKMapItem(placemark: MKPlacemark(coordinate: to)), heading: 90)
}

struct SpeedLimitLookaheadTests {
    private let sections = [
        SpeedLimitSection(start: 0, end: 1000, metersPerSecond: 100 / 3.6),
        SpeedLimitSection(start: 1000, end: 2000, metersPerSecond: 50 / 3.6),
        SpeedLimitSection(start: 2000, end: 3000, metersPerSecond: 80 / 3.6),
    ]

    @Test func lowerLimitShowsAboutFifteenSecondsAhead() throws {
        // 25 m/s looks 375 m ahead: the 50 starts 300 m on.
        let drop = try #require(SpeedLimitLookahead.nextDrop(in: sections, progress: 700, speed: 25, showing: false))
        #expect(abs(drop.metersPerSecond - 50 / 3.6) < 0.001)
        #expect(drop.distance == 300)
        #expect(drop.start == 1000)
        // Too far yet, and at least 250 m when slow.
        #expect(SpeedLimitLookahead.nextDrop(in: sections, progress: 300, speed: 25, showing: false) == nil)
        #expect(SpeedLimitLookahead.nextDrop(in: sections, progress: 760, speed: 2, showing: false) != nil)
    }

    @Test func shownSignLooksFurtherSoItDoesNotFlicker() {
        // 400 m out at 25 m/s: beyond 375 m, inside 375 x 1.3 once shown.
        #expect(SpeedLimitLookahead.nextDrop(in: sections, progress: 590, speed: 25, showing: false) == nil)
        #expect(SpeedLimitLookahead.nextDrop(in: sections, progress: 590, speed: 25, showing: true) != nil)
    }

    @Test func aRiseOrAnUnknownStretchIsNotADrop() {
        #expect(SpeedLimitLookahead.nextDrop(in: sections, progress: 1700, speed: 20, showing: false) == nil)
        let unknown = [SpeedLimitSection(start: 0, end: 500, metersPerSecond: 50 / 3.6), SpeedLimitSection(start: 500, end: 600, metersPerSecond: 0.5)]
        #expect(SpeedLimitLookahead.nextDrop(in: unknown, progress: 300, speed: 15, showing: false) == nil)
        // No limit where the car is: nothing to compare with.
        #expect(SpeedLimitLookahead.nextDrop(in: [sections[1]], progress: 800, speed: 15, showing: false) == nil)
    }
}

struct FasterRouteTests {
    @Test func quickerDifferentRoadIsOfferedAgainstTheSameRoad() throws {
        let current = northRoute(time: 1200, spacing: 10)
        let same = northRoute(time: 1200, spacing: 10)
        let other = northRoute(longitude: -0.12, time: 800, spacing: 10)
        let offer = try #require(FasterRoutePolicy.offer(fresh: [same, other], ahead: current.coordinates))
        #expect(offer.same == same)
        #expect(offer.faster == other)
        #expect(offer.savedMinutes == 6)
    }

    @Test func smallSavingsOrTheSameRoadAreNotOffered() {
        let current = northRoute(time: 1200, spacing: 10)
        // Two minutes is under the three-minute rule.
        #expect(FasterRoutePolicy.offer(fresh: [northRoute(time: 1200, spacing: 10), northRoute(longitude: -0.12, time: 1080, spacing: 10)], ahead: current.coordinates) == nil)
        // A quicker time on the road already driven is not another route.
        #expect(FasterRoutePolicy.offer(fresh: [northRoute(time: 1200, spacing: 10), northRoute(time: 600, spacing: 10)], ahead: current.coordinates) == nil)
    }

    @Test func overlapCountsPointsNearTheRoadAhead() {
        let route = northRoute(spacing: 10)
        #expect(FasterRoutePolicy.overlap(route, with: route.coordinates) == 1)
        #expect(FasterRoutePolicy.overlap(northRoute(longitude: -0.12, spacing: 10), with: route.coordinates) == 0)
    }

    @Test func changeTextShowsDistanceAndTolls() {
        var current = northRoute(meters: 20_000)
        var candidate = northRoute(meters: 32_000)
        current.tollsKnown = true
        candidate.tollsKnown = true
        candidate.tollSections = [RouteSection(start: 100, end: 900)]
        let text = RouteChange.summary(savedMinutes: 4, current: current, candidate: candidate)
        #expect(text.hasPrefix("4 min faster · "))
        #expect(text.contains("farther"))
        #expect(text.hasSuffix(" · adds a toll road"))
        let back = RouteChange.summary(savedMinutes: 3, current: candidate, candidate: current)
        #expect(back.contains("shorter"))
        #expect(back.hasSuffix("avoids toll roads"))
    }

    @Test func unknownTollsAndSmallDistancesAreLeftOut() {
        var candidate = northRoute(meters: 2300)
        candidate.tollSections = [RouteSection(start: 0, end: 100)]
        #expect(RouteChange.summary(savedMinutes: 5, current: northRoute(meters: 2000), candidate: candidate) == "5 min faster")
    }
}

struct RouteStopTests {
    @Test func detourIsThereAndBackPlusAMinute() {
        #expect(RouteStopSearch.detourMinutes(offRoute: 0) == 1)
        #expect(RouteStopSearch.detourMinutes(offRoute: 330) == 2)
        #expect(RouteStopSearch.detourMinutes(offRoute: 1650) == 6)
    }

    @Test func onlyPlacesAheadAndNearTheRouteNearestFirst() {
        let route = northRoute()
        func at(_ m: Double, east: Double = 0) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: 51.5 + m / 111_320, longitude: -0.1 + east / (111_320 * cos(51.5 * .pi / 180)))
        }
        let found = [
            RouteStopSearch.Found(name: "Far ahead", subtitle: "", coordinate: at(1800, east: 200)),
            RouteStopSearch.Found(name: "Behind", subtitle: "", coordinate: at(200)),
            RouteStopSearch.Found(name: "Next", subtitle: "", coordinate: at(900, east: 330), detourSeconds: nil),
            RouteStopSearch.Found(name: "TomTom", subtitle: "", coordinate: at(1200, east: 50), detourSeconds: 170),
            RouteStopSearch.Found(name: "Off route", subtitle: "", coordinate: at(1000, east: 3000)),
        ]
        let stops = RouteStopSearch.place(found, on: route, progress: 500, maxOff: 1200)
        #expect(stops.map(\.name) == ["Next", "TomTom", "Far ahead"])
        #expect(abs(stops[0].distanceAhead - 400) < 5)
        #expect(stops[0].detourMinutes == 2)
        #expect(stops[1].detourMinutes == 3)
    }

    @Test func tomtomAlongRouteRequestAndAnswer() throws {
        let url = RouteStopSearch.tomtomURL(.fuel, key: "KEY").absoluteString
        #expect(url.hasPrefix("https://api.tomtom.com/search/2/searchAlongRoute/petrol%20station.json"))
        #expect(url.contains("maxDetourTime=900") && url.contains("spreadingMode=auto"))
        let body = try JSONSerialization.jsonObject(with: RouteStopSearch.tomtomBody(northRoute().coordinates)) as! [String: Any]
        #expect(((body["route"] as? [String: Any])?["points"] as? [Any])?.count == northRoute().coordinates.count)
        let answer = Data(#"{"results":[{"poi":{"name":"Shell"},"address":{"freeformAddress":"A1"},"position":{"lat":51.51,"lon":-0.1},"detourTime":125}]}"#.utf8)
        let found = RouteStopSearch.parseTomTom(answer)
        #expect(found.first?.name == "Shell")
        #expect(found.first?.detourSeconds == 125)
    }

    @Test func overpassQueryUsesTheCategoryTags() throws {
        let query = RouteStopSearch.overpassQuery(.services, line: [.init(latitude: 51.5, longitude: -0.1)])
        #expect(query == #"[out:json][timeout:25];(node(around:400,51.50000,-0.10000)["highway"~"^(services|rest_area)$"];way(around:400,51.50000,-0.10000)["highway"~"^(services|rest_area)$"];);out center tags 150;"#)
        let answer = Data(#"{"elements":[{"type":"way","center":{"lat":51.5,"lon":-0.1},"tags":{"brand":"Costa"}},{"type":"node","lat":51.6,"lon":-0.1,"tags":{}}]}"#.utf8)
        let found = try RouteStopSearch.parseOverpass(answer, fallbackName: "Coffee")
        #expect(found.map(\.name) == ["Costa", "Coffee"])
    }
}

struct RouteChangeRequestTests {
    @Test func tomtomTakesStopsAvoidedRoadsAndRestrictionSections() throws {
        var r = request()
        r.via = [.init(latitude: 51.505, longitude: -0.11)]
        let road = try #require(RouteAvoidance.piece(around: 500, on: northRoute(), name: "Exit 12"))
        r.avoid = [road]
        let urls = TomTomRoutingProvider.attemptURLs(for: r, key: "KEY")
        #expect(urls.count == 5)
        #expect(urls[0].path.contains("51.500000,-0.120000:51.505000,-0.110000:51.510000,-0.100000"))
        #expect(urls[0].absoluteString.contains("maxAlternatives=0"))
        #expect(urls[0].absoluteString.contains("sectionType=tollVignette"))
        #expect(!urls[1].absoluteString.contains("sectionType=tollRoad"))
        let body = try #require(TomTomRoutingProvider.avoidBody(for: r))
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let rectangles = (json["avoidAreas"] as? [String: Any])?["rectangles"] as? [[String: Any]]
        #expect(rectangles?.count == 1)
        #expect(TomTomRoutingProvider.avoidBody(for: request()) == nil)
    }

    @Test func tomtomParsesTollVignetteAndZoneSections() throws {
        let answer = Data(#"""
        {"routes":[{"summary":{"lengthInMeters":300,"travelTimeInSeconds":30},"legs":[{"points":[
        {"latitude":47.0,"longitude":13.0},{"latitude":47.001,"longitude":13.0},{"latitude":47.002,"longitude":13.0},{"latitude":47.003,"longitude":13.0}]}],
        "sections":[{"sectionType":"TOLL_ROAD","startPointIndex":0,"endPointIndex":1},
        {"sectionType":"TOLL_VIGNETTE","startPointIndex":1,"endPointIndex":3,"countryCode":"AUT"},
        {"sectionType":"LOW_EMISSION_ZONE","startPointIndex":2,"endPointIndex":3}],"guidance":{"instructions":[]}}]}
        """#.utf8)
        let route = try #require(try TomTomRoutingProvider.parse(answer).first)
        #expect(route.tollsKnown)
        #expect(route.tollSections.count == 1)
        #expect(RouteRestrictions.vignetteCountries(route) == ["AT"])
        #expect(RouteRestrictions.entersLowEmissionZone(route))
        #expect(RouteRestrictions.officialVignetteLink("AT") != nil)
        #expect(route.coordinates(from: route.vignetteSections[0].start, to: route.vignetteSections[0].end).count >= 2)
    }

    @Test func mapboxTakesStopsAndExcludedPoints() throws {
        var r = request()
        r.via = [.init(latitude: 51.505, longitude: -0.11)]
        r.avoid = [try #require(RouteAvoidance.piece(around: 500, on: northRoute(), name: "A"))]
        let url = try #require(MapboxRoutingProvider.attemptURLs(for: r, token: "pk").first)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path.hasSuffix("-0.120000,51.500000;-0.110000,51.505000;-0.100000,51.510000"))
        #expect(items.first { $0.name == "alternatives" }?.value == "false")
        #expect(items.first { $0.name == "bearings" }?.value == "90,45;;")
        #expect(items.first { $0.name == "exclude" }?.value?.hasPrefix("point(-0.100000 51.50") == true)
    }

    @Test func offlineRequestTakesStopsAndExcludedPolygons() throws {
        var r = request()
        r.via = [.init(latitude: 51.505, longitude: -0.11)]
        r.avoid = [try #require(RouteAvoidance.piece(around: 500, on: northRoute(), name: "A"))]
        let json = try JSONSerialization.jsonObject(with: Data(ValhallaRoutingProvider.requestJSON(for: r, language: "en-GB").utf8)) as! [String: Any]
        let locations = json["locations"] as? [[String: Any]]
        #expect(locations?.count == 3)
        #expect(locations?[1]["type"] as? String == "through")
        let polygons = json["exclude_polygons"] as? [[[Double]]]
        #expect(polygons?.first?.count == 5)
    }
}

struct AvoidRoadTests {
    @Test func roadAfterAManoeuvreIsAShortPieceInItsMiddle() throws {
        let route = northRoute()
        let road = try #require(RouteAvoidance.road(after: 0, on: route))
        #expect(road.name == "Exit 12")
        let p = try #require(RouteGeometry.project(road.point, onto: route))
        // From 40 m past the manoeuvre halfway to 40 m before the arrival: three quarters of the way.
        #expect(abs(p.progress - route.length * 0.75) < 2)
        #expect(road.north > road.south && road.east > road.west)
        #expect(RouteAvoidance.road(after: 1, on: route) == nil)
    }

    @Test func aNewRouteStillOnTheRoadIsCaught() throws {
        let road = try #require(RouteAvoidance.road(after: 0, on: northRoute()))
        #expect(RouteAvoidance.stillUsed([road], by: northRoute()).count == 1)
        #expect(RouteAvoidance.stillUsed([road], by: northRoute(longitude: -0.12)).isEmpty)
    }

    @Test func roadAheadRunsToTheNextManoeuvre() throws {
        let road = try #require(RouteAvoidance.roadAhead(progress: 100, on: northRoute(), name: "High Street"))
        let p = try #require(RouteGeometry.project(road.point, onto: northRoute()))
        // From 160 m to the slip road at 1000 m.
        #expect(abs(p.progress - 580) < 2)
    }
}

struct LegJoinTests {
    @Test func legsJoinWithTheStopAsAPlainManoeuvre() throws {
        let a = northRoute(meters: 1000, time: 100)
        let second = a.coordinates.last!
        let bCoords = (0...20).map { CLLocationCoordinate2D(latitude: second.latitude + Double($0) * 50 / 111_320, longitude: second.longitude) }
        let b = RouteOption(name: "B", distance: 1000, expectedTravelTime: 120, coordinates: bCoords,
                            steps: [RouteStep(instruction: "Arrive", notice: nil, distance: 0, startProgress: 1000, turnAngle: nil, isArrival: true)],
                            advisories: [], source: .online("Apple Maps"), speedLimits: [SpeedLimitSection(start: 0, end: 1000, metersPerSecond: 13)])
        let joined = try #require(RouteLegs.join([a, b]))
        #expect(joined.expectedTravelTime == 220)
        #expect(joined.distance == 2000)
        #expect(joined.coordinates.count == a.coordinates.count + bCoords.count - 1)
        #expect(joined.steps.filter(\.isArrival).count == 1)
        #expect(joined.steps[1].instruction == "Arrive at your stop")
        #expect(abs(joined.steps.last!.startProgress - (a.length + 1000)) < 1)
        #expect(abs(joined.speedLimits[0].start - a.length) < 1)
    }
}

struct ArrivalTests {
    private func offset(_ c: CLLocationCoordinate2D, east: Double, north: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: c.latitude + north / 111_320, longitude: c.longitude + east / (111_320 * cos(c.latitude * .pi / 180)))
    }

    @Test func sideFromTheLastStretchOfRoute() {
        let route = northRoute(meters: 500)
        let end = route.coordinates.last!
        #expect(ArrivalSide.side(route: route.coordinates, destination: offset(end, east: 20)) == .arriveRight)
        #expect(ArrivalSide.side(route: route.coordinates, destination: offset(end, east: -20)) == .arriveLeft)
        // Dead ahead, or right at the end of the route, says nothing.
        #expect(ArrivalSide.side(route: route.coordinates, destination: offset(end, east: 2, north: 30)) == nil)
        #expect(ArrivalSide.side(route: route.coordinates, destination: offset(end, east: 3)) == nil)
    }

    @Test func tomtomEntrancesBecomeThePlaceToDriveTo() throws {
        let places = try TomTomSearchProvider.parse(try fixture("tomtom-search"), query: "tate modern")
        #expect(places[0].coordinate.latitude == 51.50744)
        #expect(places[0].building?.latitude == 51.50758)
        #expect(places[0].mapItem is EntrancePlaceItem)
        #expect(places[1].building == nil)
    }

    @Test func parkingFromOpenStreetMapWithVehicleEntrances() throws {
        let destination = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1)
        let answer = Data(#"""
        {"elements":[
        {"type":"way","center":{"lat":51.502,"lon":-0.1},"tags":{"amenity":"parking","name":"Station Car Park","fee":"yes","parking":"multi-storey","capacity":"420"}},
        {"type":"node","lat":51.5021,"lon":-0.1003,"tags":{"amenity":"parking_entrance"}},
        {"type":"way","center":{"lat":51.5005,"lon":-0.1},"tags":{"amenity":"parking","access":"private"}},
        {"type":"node","lat":51.501,"lon":-0.1,"tags":{"amenity":"parking","opening_hours":"24/7"}},
        {"type":"node","lat":51.51,"lon":-0.1,"tags":{"amenity":"parking"}}
        ]}
        """#.utf8)
        let spots = try ParkingSearch.parse(answer, destination: destination)
        #expect(spots.map(\.name) == ["Car park", "Station Car Park"])
        #expect(spots[0].details == "open 24 h")
        // The entrance is nearer the station car park, so it is that one's.
        #expect(!spots[0].hasMappedEntrance)
        #expect(spots[1].hasMappedEntrance)
        #expect(spots[1].coordinate.latitude == 51.5021)
        #expect(spots[1].details == "Paid · 420 spaces · Multi-storey")
        #expect(spots[1].walkMinutes == 3)
    }

    @Test func parkingIsOfferedCloseToTheDestinationOnly() {
        #expect(ParkingSearch.shouldOffer(remaining: 1000, routeLength: 8000, destinationName: "Tate Modern"))
        #expect(!ParkingSearch.shouldOffer(remaining: 2500, routeLength: 8000, destinationName: "Tate Modern"))
        #expect(!ParkingSearch.shouldOffer(remaining: 1000, routeLength: 2000, destinationName: "Tate Modern"))
        #expect(!ParkingSearch.shouldOffer(remaining: 1000, routeLength: 8000, destinationName: "Bankside Car Park"))
    }
}

struct OfflinePreviewTests {
    @Test func coverageNeedsEveryCheckpointInOnePack() {
        let route = northRoute(meters: 25_000)
        let points = OfflineCoverage.checkpoints(of: route)
        #expect(points.count == 4)
        let whole = InstalledPack(id: "big", name: "Big", folder: URL(fileURLWithPath: "/"), bounds: [51, -1, 52, 1], bytes: 0)
        let part = InstalledPack(id: "small", name: "Small", folder: URL(fileURLWithPath: "/"), bounds: [51, -1, 51.6, 1], bytes: 0)
        #expect(OfflineCoverage.pack(covering: points, among: [part, whole])?.id == "big")
        #expect(OfflineCoverage.pack(covering: points, among: [part]) == nil)
    }

    @Test func packSuggestionPrefersARegionThenTheCountry() {
        #expect(PackSuggestion.suggest(country: "de", names: ["Upper Bavaria", "Bavaria", "Germany"])?.id == "germany-bayern")
        #expect(PackSuggestion.suggest(country: "DE", names: ["Nowhere", "Germany"])?.id == "germany")
        #expect(PackSuggestion.suggest(country: "GB", names: ["Kent", "England", "United Kingdom"])?.id == "united-kingdom-england-kent")
        #expect(PackSuggestion.suggest(country: "GB", names: ["Nowhere"])?.id == "ew")
        #expect(PackSuggestion.suggest(country: "US", names: ["Texas", "United States"])?.id == "us-texas")
        #expect(PackSuggestion.suggest(country: "US", names: ["Nowhere"]) == nil)
        #expect(PackSuggestion.normalize("County Durham") == "durham")
    }
}
