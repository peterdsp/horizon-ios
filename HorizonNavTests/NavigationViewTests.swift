import CoreLocation
import Testing
@testable import HorizonNav

private let start = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1)
private let metersPerDegreeLon = 111_320 * cos(start.latitude * .pi / 180)

/// An east-bound road with a right turn south at 500 m and 300 m more to the destination; lanes before the turn when asked.
private func route(lanes: Bool = false, maneuver: Maneuver = .turnRight) -> RouteOption {
    let corner = CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude + 500 / metersPerDegreeLon)
    var coords: [CLLocationCoordinate2D] = []
    for i in 0...10 { coords.append(CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude + Double(i) * 50 / metersPerDegreeLon)) }
    for i in 1...6 { coords.append(CLLocationCoordinate2D(latitude: corner.latitude - Double(i) * 50 / 111_320, longitude: corner.longitude)) }
    let cumulative = RouteGeometry.cumulativeDistances(coords)
    let steps = [
        RouteStep(instruction: "Turn right onto South Road", notice: nil, distance: 300, startProgress: cumulative[10],
                  turnAngle: 90, isArrival: false, maneuver: maneuver),
        RouteStep(instruction: "Arrive at destination", notice: nil, distance: 0, startProgress: cumulative[16],
                  turnAngle: nil, isArrival: true),
    ]
    let sections = lanes ? [LaneSection(start: 300, end: cumulative[10], lanes: [
        Lane(directions: ["STRAIGHT"], follow: nil), Lane(directions: ["RIGHT"], follow: "RIGHT"),
    ])] : []
    return RouteOption(name: "Test", distance: 800, expectedTravelTime: 80, coordinates: coords, steps: steps,
                       advisories: [], source: .online("test"), laneSections: sections)
}

private func update(_ route: RouteOption, progress: CLLocationDistance) -> GuidanceUpdate {
    let upcoming = route.steps.firstIndex { $0.startProgress > progress + 15 || $0.isArrival }
    return GuidanceUpdate(status: .onRoute, upcomingStepIndex: upcoming,
                          distanceToManeuver: upcoming.map { max(route.steps[$0].startProgress - progress, 0) } ?? 0,
                          remainingDistance: route.length - progress, remainingTime: 60, distanceFromRoute: 0, progress: progress)
}

struct NavigationViewModeTests {
    @Test func oneTapCyclesTiltedHeadingUpNorthUp() {
        #expect(NavigationViewMode.tilted.next == .headingUp)
        #expect(NavigationViewMode.headingUp.next == .northUp)
        #expect(NavigationViewMode.northUp.next == .tilted)
        #expect(NavigationViewMode.tilted.pitch == 55)
        #expect(NavigationViewMode.headingUp.pitch == 0 && NavigationViewMode.headingUp.followsCourse)
        #expect(NavigationViewMode.northUp.pitch == 0 && !NavigationViewMode.northUp.followsCourse)
    }

    @Test func settingsDefaultToTheTiltedViewAndDefaultZoom() {
        #expect(NavigationViewMode(rawValue: "nonsense") == nil)
        #expect(NavigationZoom.standard.offset == 0)
        #expect(NavigationZoom.closer.offset == 0.5)
        #expect(NavigationZoom.wider.offset == -0.5)
    }
}

struct NavigationCameraTests {
    @Test func speedZoomFollowsTheAndroidCurve() {
        #expect(NavigationCamera.routeSpeedZoom(0, fastRoad: false) == 18.7)
        #expect(abs(NavigationCamera.routeSpeedZoom(13.4, fastRoad: false) - 17.6) < 0.0001)
        #expect(abs(NavigationCamera.routeSpeedZoom(15.2, fastRoad: false) - 17.35) < 0.0001)
        #expect(NavigationCamera.routeSpeedZoom(60, fastRoad: false) == 15.6)
        #expect(abs(NavigationCamera.routeSpeedZoom(31, fastRoad: true) - 15.55) < 0.0001)
        #expect(NavigationCamera.routeSpeedZoom(.nan, fastRoad: false) == 15.6)
    }

    @Test func closerAndWiderMoveTheAutomaticZoomHalfAStep() {
        let standard = NavigationCamera.zoom(speed: 20, distanceToManeuver: 3000, fastRoad: false, preference: .standard)
        let closer = NavigationCamera.zoom(speed: 20, distanceToManeuver: 3000, fastRoad: false, preference: .closer)
        let wider = NavigationCamera.zoom(speed: 20, distanceToManeuver: 3000, fastRoad: false, preference: .wider)
        #expect(abs(closer - standard - 0.5) < 0.0001)
        #expect(abs(standard - wider - 0.5) < 0.0001)
        // Faster is further out; nearer the turn is closer in.
        #expect(NavigationCamera.zoom(speed: 30, distanceToManeuver: nil, fastRoad: false, preference: .standard) <
                NavigationCamera.zoom(speed: 10, distanceToManeuver: nil, fastRoad: false, preference: .standard))
        #expect(NavigationCamera.zoom(speed: 10, distanceToManeuver: 50, fastRoad: false, preference: .standard) >
                NavigationCamera.zoom(speed: 10, distanceToManeuver: 900, fastRoad: false, preference: .standard))
        #expect(NavigationCamera.zoom(speed: 0, distanceToManeuver: 0, fastRoad: false, preference: .closer) <= NavigationCamera.maxZoom)
    }

    @Test func cameraDistanceHalvesForEachZoomLevel() {
        let a = NavigationCamera.distance(zoom: 16, latitude: 51.5, viewHeight: 800)
        let b = NavigationCamera.distance(zoom: 17, latitude: 51.5, viewHeight: 800)
        #expect(abs(a / b - 2) < 0.0001)
        // MapLibre's metres per point at zoom 16 on the equator: 2 pi R / (512 * 2^16).
        #expect(abs(NavigationCamera.metersPerPoint(zoom: 16, latitude: 0) - 1.1943) < 0.001)
    }

    @Test func northUpCentresTheCarAndHeadingUpLooksAhead() {
        let r = route()
        let here = start
        let north = NavigationCamera.target(location: here, course: 90, speed: 10, route: r, update: update(r, progress: 0),
                                            mode: .northUp, preference: .standard, viewHeight: 800)
        #expect(north.heading == 0 && north.pitch == 0)
        #expect(north.center.latitude == here.latitude && north.center.longitude == here.longitude)
        let tilted = NavigationCamera.target(location: here, course: 90, speed: 10, route: r, update: update(r, progress: 0),
                                             mode: .tilted, preference: .standard, viewHeight: 800)
        #expect(tilted.heading == 90 && tilted.pitch == 55)
        #expect(tilted.center.longitude > here.longitude)
        // With no usable course the route's own direction is used.
        let still = NavigationCamera.target(location: here, course: nil, speed: 0, route: r, update: update(r, progress: 0),
                                            mode: .headingUp, preference: .standard, viewHeight: 800)
        #expect(abs(still.heading - 90) < 1)
    }

    @Test func overviewIsTheRouteLeftToDrive() {
        let r = route()
        let rest = NavigationCamera.remainingCoordinates(of: r, progress: 225)
        #expect(abs(RouteGeometry.distance(rest[0], r.point(atProgress: 225)!.coordinate)) < 0.01)
        #expect(rest.last!.latitude == r.coordinates.last!.latitude)
        #expect(rest.count == r.coordinates.count - 4)
        #expect(NavigationCamera.remainingCoordinates(of: r, progress: 0).count == r.coordinates.count)
    }

    @Test func pointAlongTheRouteAndAhead() throws {
        let r = route()
        let p = try #require(r.point(atProgress: 125))
        #expect(abs(RouteGeometry.distance(start, p.coordinate) - 125) < 0.5)
        #expect(abs(p.bearing - 90) < 1)
        let after = try #require(r.point(atProgress: 600))
        #expect(abs(after.bearing - 180) < 1)
        let ahead = RouteGeometry.coordinate(from: start, bearing: 0, distance: 1000)
        #expect(abs(RouteGeometry.distance(start, ahead) - 1000) < 5)
        #expect(ahead.latitude > start.latitude)
    }
}

struct RoadFeatureTests {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    @Test func parsesLightsCrossingsAndOnlyTheRoutesStopSigns() throws {
        let r = route()
        let lon = { (m: Double) in start.longitude + m / metersPerDegreeLon }
        // A stop sign on the route's own east-bound road, and one on a side street running north-south.
        let data = json("""
        {"elements":[
          {"type":"node","id":1,"lat":51.5,"lon":\(lon(100)),"tags":{"highway":"traffic_signals"}},
          {"type":"node","id":2,"lat":51.5,"lon":\(lon(200)),"tags":{"railway":"level_crossing"}},
          {"type":"node","id":3,"lat":51.5,"lon":\(lon(300)),"tags":{"highway":"stop"}},
          {"type":"node","id":4,"lat":51.5001,"lon":\(lon(400)),"tags":{"highway":"stop"}},
          {"type":"way","id":10,"nodes":[30,3,31],"geometry":[{"lat":51.5,"lon":\(lon(280))},{"lat":51.5,"lon":\(lon(300))},{"lat":51.5,"lon":\(lon(320))}],"tags":{"highway":"residential"}},
          {"type":"way","id":11,"nodes":[40,4,41],"geometry":[{"lat":51.5003,"lon":\(lon(400))},{"lat":51.5001,"lon":\(lon(400))},{"lat":51.4999,"lon":\(lon(400))}],"tags":{"highway":"residential"}}
        ]}
        """)
        let found = try RoadFeatures.parse(data, route: r.coordinates)
        #expect(found.map(\.kind) == [.trafficLight, .railwayCrossing, .stopSign])
        #expect(abs(found[2].longitude - lon(300)) < 1e-9)
    }

    @Test func aStopSignWithNoRoadDataIsLeftOut() {
        #expect(!RoadFeatures.stopForRoute(id: 3, at: start, tags: [:], ways: [], route: route().coordinates))
    }

    @Test func aBusyServersRemarkIsAFailure() {
        #expect(throws: (any Error).self) {
            try RoadFeatures.parse(json("{\"remark\":\"runtime error: Query timed out\",\"elements\":[]}"), route: route().coordinates)
        }
    }

    @Test func placesFeaturesOnTheRouteOnceAndShowsThoseAhead() {
        let r = route()
        let on = RoadFeature(kind: .trafficLight, latitude: 51.5, longitude: start.longitude + 100 / metersPerDegreeLon)
        let twin = RoadFeature(kind: .trafficLight, latitude: 51.50005, longitude: start.longitude + 108 / metersPerDegreeLon)
        let off = RoadFeature(kind: .trafficLight, latitude: 51.501, longitude: start.longitude + 100 / metersPerDegreeLon)
        let later = RoadFeature(kind: .railwayCrossing, latitude: 51.5, longitude: start.longitude + 450 / metersPerDegreeLon)
        let placed = RoadFeatures.place([later, on, twin, off], on: r)
        #expect(placed.map(\.feature) == [on, later])
        #expect(abs(placed[0].offset - 100) < 1)
        #expect(RoadFeatures.ahead(placed, progress: 200).map(\.feature) == [later])
        #expect(RoadFeatures.ahead(placed, progress: 0, within: 200).map(\.feature) == [on])
    }

    @Test func picturesAreDrawn() {
        for kind in [RoadFeature.Kind.trafficLight, .railwayCrossing, .stopSign] {
            #expect(MapMarkImages.image(for: kind).size.width > 10)
        }
    }
}

struct LaneSignTests {
    @Test func standsAtTheJunctionWhileItsLanesApply() throws {
        let r = route(lanes: true)
        #expect(LaneSign.ahead(route: r, update: update(r, progress: 50)) == nil)
        let sign = try #require(LaneSign.ahead(route: r, update: update(r, progress: 300)))
        #expect(abs(RouteGeometry.distance(sign.coordinate, r.coordinates[10]) - 10) < 0.5)
        let mark = try #require(sign.mark)
        #expect(mark.anchorsBottom && mark.label == "Use the right lane")
        // Gone in the last 15 m, and on a route without lanes.
        #expect(LaneSign.ahead(route: r, update: update(r, progress: 490)) == nil)
        #expect(LaneSign.ahead(route: route(), update: update(route(), progress: 300)) == nil)
    }
}

struct JunctionPreviewTests {
    @Test func drivesFromBeforeTheJunctionToJustAfterIt() throws {
        let r = route()
        let preview = try #require(JunctionPreview(route: r, stepIndex: 0))
        #expect(preview.speed == 13.9)
        // 12 seconds of driving before the junction, but at least 250 m.
        let junction = r.steps[0].startProgress
        #expect(abs(preview.start - (junction - 250)) < 0.01)
        #expect(abs(preview.end - (junction + JunctionPreview.leadOut)) < 0.01)
        #expect(abs(preview.duration - (preview.end - preview.start) / (13.9 * 2)) < 0.01)
        let first = try #require(preview.frame(at: 0))
        #expect(first.update.upcomingStepIndex == 0 && abs(first.update.distanceToManeuver - 250) < 0.5)
        let past = try #require(preview.frame(at: preview.duration))
        #expect(abs(past.progress - preview.end) < 0.01)
        #expect(past.update.upcomingStepIndex == 1)
        #expect(abs(past.bearing - 180) < 1)
        #expect(JunctionPreview(route: r, stepIndex: 5) == nil)
    }

    @Test func listsTheManoeuvresAndMarksTheComplexOnes() {
        #expect(JunctionPreview.candidates(in: route()) == [0])
        #expect(!JunctionPreview.isComplex(route().steps[0], in: route()))
        #expect(JunctionPreview.isComplex(route(lanes: true).steps[0], in: route(lanes: true)))
        let exit = route(maneuver: .motorwayExitRight)
        #expect(JunctionPreview.isComplex(exit.steps[0], in: exit))
    }
}
