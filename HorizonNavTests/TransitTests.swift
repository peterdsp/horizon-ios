import CoreLocation
import Foundation
import Testing
@testable import HorizonNav

/// Real Transitous answers, saved from api.transitous.org (trimmed to two itineraries each): Berlin Kreuzberg to
/// Charlottenburg Palace leaving now, Zürich HB to ETH Hönggerberg arriving by 08:30, Times Square to the Brooklyn Museum
/// with a realtime bus, and that bus's trip.
private func plan(_ name: String) throws -> TransitPlan { try TransitousClient.parsePlan(try fixture(name)) }
private func date(_ text: String) -> Date { TransitousClient.date(text)! }
private func fix(_ c: CLLocationCoordinate2D, at time: Date, accuracy: Double = 10) -> CLLocation {
    CLLocation(coordinate: c, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: time)
}

struct TransitousParsingTests {
    @Test func berlinLegsStopsPlatformsAndPaths() throws {
        let result = try plan("transitous-plan-berlin")
        #expect(result.itineraries.count == 2)
        #expect(result.laterCursor?.hasPrefix("LATER|") == true)
        #expect(result.earlierCursor?.hasPrefix("EARLIER|") == true)
        let trip = result.itineraries[1]
        #expect(trip.transfers == 1)
        #expect(trip.start == date("2026-11-26T22:51:00Z"))
        #expect(trip.end == date("2026-11-26T23:31:00Z"))
        #expect(trip.legs.map(\.mode) == ["WALK", "SUBWAY", "WALK", "BUS", "WALK"])
        let u7 = trip.legs[1]
        #expect(u7.line == "U7")
        #expect(u7.headsign == "S+U Rathaus Spandau (Berlin)")
        #expect(u7.routeColor == "009bd5")
        #expect(u7.from.track == "2" && u7.to.track == "2")
        #expect(u7.from.detail == "U Bahnsteig Gleis 2")
        #expect(u7.intermediateStops.count == 13)
        #expect(u7.path.count == 87)
        #expect(!u7.isCancelled && !u7.realTime)
        let walk = trip.legs[0]
        #expect(walk.isWalk && !walk.isTransit)
        #expect(walk.from.name == "START")
        #expect(walk.distance == 318)
        #expect(walk.steps.count == 21)
        #expect(walk.steps.contains { $0.direction == "STAIRS" && $0.toLevel == -1 })
        // The walking path ends at the platform it leads to.
        #expect(RouteGeometry.distance(walk.coordinates.last!, walk.to.coordinate) < 30)
        #expect(trip.legs[3].line == "M45")
        #expect(trip.legs[3].from.track.isEmpty)
    }

    @Test func zurichArriveByKeepsEveryPlatform() throws {
        let trip = try plan("transitous-plan-zurich-arriveby").itineraries[1]
        #expect(trip.transfers == 2)
        let rides = trip.transitLegs
        #expect(rides.map(\.line) == ["S15", "83", "69"])
        #expect(rides[0].from.track == "41/42" && rides[0].to.track == "3")
        #expect(rides[1].to.track == "G" && rides[2].from.track == "B")
        #expect(rides[0].from.timeZone == "Europe/Zurich")
        #expect(trip.end == date("2026-11-27T07:15:00Z"))
    }

    @Test func nycRealtimeBusLeavesEarly() throws {
        let trip = try plan("transitous-plan-nyc").itineraries[1]
        let bus = trip.legs[1]
        #expect(bus.line == "M104")
        #expect(bus.realTime)
        #expect(bus.departureDelay == -120)
        #expect(bus.start == date("2026-11-26T22:58:00Z"))
        #expect(bus.scheduledStart == date("2026-11-26T23:00:00Z"))
        #expect(trip.hasRealtime)
        #expect(!trip.isCancelled)
    }

    @Test func tripAnswerParsesAsOneRide() throws {
        let object = try JSON.object(try fixture("transitous-trip-nyc"), provider: "Transitous")
        let trip = try #require(TransitousClient.itinerary(object))
        #expect(trip.legs.count == 1)
        #expect(trip.legs[0].line == "M104")
        #expect(trip.legs[0].intermediateStops.count == 40)
        #expect(trip.legs[0].to.name == "7 AV/W 42 ST")
    }

    @Test func requestsFollowTheChosenTime() {
        var query = TransitQuery(origin: .init(latitude: 52.4895, longitude: 13.394), destination: .init(latitude: 52.5209, longitude: 13.2957))
        let now = TransitousClient.planURL(for: query, language: "en").absoluteString
        #expect(now.hasPrefix("https://api.transitous.org/api/v6/plan?"))
        #expect(now.contains("fromPlace=52.489500,13.394000"))
        #expect(now.contains("toPlace=52.520900,13.295700"))
        #expect(now.contains("detailedTransfers=true"))
        #expect(!now.contains("time=") && !now.contains("arriveBy"))
        query.timeMode = .arriveBy
        query.time = date("2026-11-27T07:30:00Z")
        let arriveBy = TransitousClient.planURL(for: query, cursor: "LATER|1", language: "en").absoluteString
        #expect(arriveBy.contains("time=2026-11-27T07:30:00Z"))
        #expect(arriveBy.contains("arriveBy=true"))
        #expect(arriveBy.contains("pageCursor=LATER%7C1"))
        query.timeMode = .departAt
        #expect(!TransitousClient.planURL(for: query).absoluteString.contains("arriveBy"))
        #expect(TransitousClient.tripURL(tripID: "a b").absoluteString.contains("tripId=a%20b"))
    }

    @Test func userAgentNamesTheAppAndItsProject() {
        #expect(TransitousClient.userAgent.hasPrefix("HorizonNav-iOS/"))
        #expect(TransitousClient.userAgent.contains("https://github.com/peterdsp/horizon-ios"))
    }
}

struct TransitComparisonTests {
    @Test func walkingAndTheShortestChange() throws {
        let berlin = try plan("transitous-plan-berlin").itineraries
        #expect(TransitComparison.walkingTime(berlin[0]) == 1200)
        #expect(TransitComparison.walkingTime(berlin[1]) == 840)
        #expect(TransitComparison.walkingDistance(berlin[1]) == 885)
        #expect(TransitComparison.shortestTransfer(berlin[0]) == nil)
        // U7 arrives 23:17, the M45 leaves 23:22.
        #expect(TransitComparison.shortestTransfer(berlin[1]) == 300)
        // Zürich: 5 minutes at Hardbrücke, then 2 at Bucheggplatz.
        let zurich = try plan("transitous-plan-zurich-arriveby").itineraries[1]
        #expect(TransitComparison.shortestTransfer(zurich) == 120)
    }

    @Test func sortingByArrivalChangesAndWalking() throws {
        let berlin = try plan("transitous-plan-berlin").itineraries
        let direct = berlin[0], withChange = berlin[1]
        #expect(TransitComparison.sorted(berlin, by: .arrival).map(\.id) == [withChange.id, direct.id])
        #expect(TransitComparison.sorted(berlin, by: .transfers).map(\.id) == [direct.id, withChange.id])
        #expect(TransitComparison.sorted(berlin, by: .walking).map(\.id) == [withChange.id, direct.id])
        let best = TransitComparison.best(berlin)
        #expect(best[withChange.id] == [.arrival, .walking])
        #expect(best[direct.id] == [.transfers])
    }

    @Test func cancelledTripsWinNothing() throws {
        var berlin = try plan("transitous-plan-berlin").itineraries
        berlin[1].legs[3].cancelled = true
        #expect(berlin[1].isCancelled)
        #expect(TransitComparison.best(berlin)[berlin[1].id] == nil)
        #expect(TransitComparison.best(berlin)[berlin[0].id] == [.arrival, .transfers, .walking])
    }

    @Test func realtimeDelayIsShownOnlyWhenKnown() throws {
        let nyc = try plan("transitous-plan-nyc").itineraries[1]
        #expect(TransitFormat.delay(nyc.legs[1]) == "-2 min")
        #expect(TransitFormat.delay(nyc.legs[3]) == nil)
    }
}

struct TransitWalkingTests {
    @Test func changeWalkCallsTheStairsAndArrives() throws {
        let walk = try plan("transitous-plan-berlin").itineraries[1].legs[2]
        let route = try #require(TransitWalkRoute(leg: walk, target: "U Richard-Wagner-Platz"))
        let steps = route.route.steps
        #expect(route.symbols.count == steps.count)
        #expect(steps.filter { $0.instruction == "Take the stairs up" }.count == 2)
        #expect(steps.last?.isArrival == true)
        #expect(steps.last?.instruction == "Arrive at U Richard-Wagner-Platz")
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.startProgress <= $1.startProgress })
        #expect(route.route.expectedTravelTime == 180)
        #expect(abs(route.route.length - 218) < 30)
    }

    @Test func walkToTheUndergroundGoesDownTheStairs() throws {
        let walk = try plan("transitous-plan-berlin").itineraries[1].legs[0]
        let route = try #require(TransitWalkRoute(leg: walk, target: "U Gneisenaustr. (Berlin), Platform 2"))
        #expect(route.route.steps.contains { $0.instruction == "Take the stairs down" })
        // The service marks every stretch; only real turns and level changes stay.
        #expect(route.route.steps.count < walk.steps.count)
    }

    @Test func guidanceFollowsTheWalkToTheStop() throws {
        let walk = try plan("transitous-plan-berlin").itineraries[1].legs[4]
        let route = try #require(TransitWalkRoute(leg: walk, target: "Destination")).route
        let engine = RouteGuidance(route: route)
        let start = Date()
        var last: GuidanceUpdate?
        for (i, c) in route.coordinates.enumerated() {
            last = engine.update(with: CLLocation(coordinate: c, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
                                                  course: -1, speed: 1.3, timestamp: start.addingTimeInterval(Double(i) * 10)))
        }
        #expect(last?.status == .arrived)
    }

    @Test func walkingCallsComeOnceAtFiftyMetresAndAtTheTurn() {
        var planner = WalkingPromptPlanner()
        let step = RouteStep(instruction: "Turn left onto Otto-Suhr-Allee", notice: nil, distance: 80, startProgress: 100, turnAngle: -90,
                             isArrival: false, maneuver: .turnLeft, street: "Otto-Suhr-Allee")
        var calls: [(Double, VoicePrompt)] = []
        var d = 120.0
        while d >= 0 {
            for p in planner.prompts(stepIndex: 0, step: step, distance: d, imperial: false) { calls.append((d, p)) }
            d -= 5
        }
        #expect(calls.map(\.1.key) == ["w0e", "w0n"])
        #expect(calls[0].0 == 60)
        #expect(calls[0].1.text == "In 50 metres, turn left onto Otto-Suhr-Allee")
        #expect(calls[1].1.text == "Turn left onto Otto-Suhr-Allee")
        let arrival = RouteStep(instruction: "Arrive", notice: nil, distance: 0, startProgress: 0, turnAngle: nil, isArrival: true)
        #expect(planner.prompts(stepIndex: 1, step: arrival, distance: 10, imperial: false).isEmpty)
    }
}

struct TransitRideTests {
    private func u7() throws -> TransitLeg { try plan("transitous-plan-berlin").itineraries[1].legs[1] }

    @Test func stopsToGoFromThePosition() throws {
        let leg = try u7()
        let line = TransitRide.line(leg)
        let offsets = TransitRide.stopOffsets(leg, line: line)
        #expect(offsets.count == 14)
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 })
        let now = date("2026-11-26T23:13:30Z")
        // At Adenauerplatz: Wilmersdorfer Str., Bismarckstr. and Richard-Wagner-Platz to go.
        let here = fix(leg.intermediateStops[10].coordinate, at: now)
        let progress = TransitRide.progress(leg, line: line, offsets: offsets, location: here, now: now)
        #expect(progress.stopsRemaining == 3)
        #expect(progress.nextStop?.name == "U Wilmersdorfer Str. (Berlin)")
        #expect(progress.departed)
        #expect(progress.secondsToArrival == 210)
        #expect((progress.metresToStop ?? 0) > 1000)
    }

    @Test func undergroundTheTimetableCounts() throws {
        let leg = try u7()
        let line = TransitRide.line(leg)
        let offsets = TransitRide.stopOffsets(leg, line: line)
        let now = date("2026-11-26T23:12:30Z")
        // A fix two minutes old, from the boarding stop, no longer counts.
        let stale = fix(leg.from.coordinate, at: now.addingTimeInterval(-120))
        let progress = TransitRide.progress(leg, line: line, offsets: offsets, location: stale, now: now)
        #expect(progress.stopsRemaining == 4)
        #expect(progress.nextStop?.name == "U Adenauerplatz (Berlin)")
        #expect(progress.metresToStop == nil)
        let before = TransitRide.progress(leg, line: line, offsets: offsets, location: nil, now: date("2026-11-26T22:50:00Z"))
        #expect(!before.departed)
        #expect(before.stopsRemaining == 14)
    }

    @Test func oneStopBeforeThenAsYouArrive() {
        var planner = StopAlertPlanner()
        func ride(_ stops: Int, metres: Double?, seconds: Double, departed: Bool = true) -> TransitRideProgress {
            TransitRideProgress(stopsRemaining: stops, nextStop: nil, secondsToArrival: seconds, departed: departed, metresToStop: metres)
        }
        #expect(planner.alerts(rideKey: "a", progress: ride(1, metres: 900, seconds: 150, departed: false), setting: .oneStop).isEmpty)
        #expect(planner.alerts(rideKey: "a", progress: ride(3, metres: 2500, seconds: 400), setting: .oneStop).isEmpty)
        #expect(planner.alerts(rideKey: "a", progress: ride(2, metres: 1600, seconds: 250), setting: .oneStop).isEmpty)
        #expect(planner.alerts(rideKey: "a", progress: ride(1, metres: 900, seconds: 110), setting: .oneStop) == [.approaching(stops: 1, minutes: 2)])
        #expect(planner.alerts(rideKey: "a", progress: ride(1, metres: 700, seconds: 90), setting: .oneStop).isEmpty)
        #expect(planner.alerts(rideKey: "a", progress: ride(1, metres: 300, seconds: 70), setting: .oneStop) == [.getOffNow])
        #expect(planner.alerts(rideKey: "a", progress: ride(1, metres: 100, seconds: 20), setting: .oneStop).isEmpty)
        // Off in Settings: nothing.
        var off = StopAlertPlanner()
        #expect(off.alerts(rideKey: "a", progress: ride(1, metres: 100, seconds: 20), setting: .off).isEmpty)
    }

    @Test func minutesBeforeAndStraightToArriving() {
        var planner = StopAlertPlanner()
        func ride(_ stops: Int, metres: Double?, seconds: Double) -> TransitRideProgress {
            TransitRideProgress(stopsRemaining: stops, nextStop: nil, secondsToArrival: seconds, departed: true, metresToStop: metres)
        }
        #expect(planner.alerts(rideKey: "b", progress: ride(4, metres: nil, seconds: 200), setting: .twoMinutes).isEmpty)
        #expect(planner.alerts(rideKey: "b", progress: ride(3, metres: nil, seconds: 115), setting: .twoMinutes) == [.approaching(stops: 3, minutes: 2)])
        #expect(planner.alerts(rideKey: "b", progress: ride(1, metres: nil, seconds: 50), setting: .twoMinutes) == [.getOffNow])
        // A ride where the stop comes up before the early alert was due: only the arrival alert.
        var late = StopAlertPlanner()
        #expect(late.alerts(rideKey: "c", progress: ride(1, metres: 200, seconds: 40), setting: .fiveMinutes) == [.getOffNow])
        #expect(late.alerts(rideKey: "c", progress: ride(1, metres: 100, seconds: 20), setting: .fiveMinutes).isEmpty)
    }

    @Test func timetableTimesForTheScheduledAlert() throws {
        let leg = try u7()
        #expect(StopAlertPlanner.scheduledTime(for: leg, setting: .fiveMinutes) == date("2026-11-26T23:12:00Z"))
        // Leaving Bismarckstr., the stop before Richard-Wagner-Platz.
        #expect(StopAlertPlanner.scheduledTime(for: leg, setting: .oneStop) == date("2026-11-26T23:16:00Z"))
        #expect(StopAlertPlanner.scheduledTime(for: leg, setting: .twoStops) == date("2026-11-26T23:15:00Z"))
        #expect(StopAlertPlanner.scheduledTime(for: leg, setting: .off) == nil)
    }
}

struct TransitConnectionTests {
    private func nyc() throws -> TransitItinerary { try plan("transitous-plan-nyc").itineraries[1] }

    @Test func aTripOnTimeHasNoProblem() throws {
        #expect(TransitConnectionCheck.problem(try nyc(), legIndex: 0, location: nil, rideProgress: nil, now: date("2026-11-26T22:56:30Z")) == nil)
    }

    @Test func aCancelledRideAhead() throws {
        var trip = try nyc()
        trip.legs[3].cancelled = true
        #expect(TransitConnectionCheck.problem(trip, legIndex: 0, location: nil, rideProgress: nil, now: date("2026-11-26T22:56:30Z"))
                == .cancelled(line: "3", stop: "Times Sq-42 St"))
    }

    @Test func aDelayThatBreaksTheChange() throws {
        var trip = try nyc()
        // The bus now arrives at 23:01; the walk to the subway takes a minute and the 3 leaves at 23:01.
        trip.legs[1].end = date("2026-11-26T23:01:00Z")
        #expect(TransitConnectionCheck.problem(trip, legIndex: 0, location: nil, rideProgress: nil, now: date("2026-11-26T22:56:30Z"))
                == .transferTooShort(line: "3", stop: "Times Sq-42 St"))
    }

    @Test func missedWhileStillWalking() throws {
        let trip = try nyc()
        // The bus has realtime data, so 3 minutes after it left counts as missed.
        #expect(TransitConnectionCheck.problem(trip, legIndex: 0, location: nil, rideProgress: nil, now: date("2026-11-26T23:00:30Z")) == nil)
        #expect(TransitConnectionCheck.problem(trip, legIndex: 0, location: nil, rideProgress: nil, now: date("2026-11-26T23:01:30Z"))
                == .missed(line: "M104", stop: "7 AV/W 44 ST"))
        // The subway runs on the timetable only: 5 minutes.
        #expect(TransitConnectionCheck.problem(trip, legIndex: 2, location: nil, rideProgress: nil, now: date("2026-11-26T23:05:00Z")) == nil)
        #expect(TransitConnectionCheck.problem(trip, legIndex: 2, location: nil, rideProgress: nil, now: date("2026-11-26T23:06:30Z"))
                == .missed(line: "3", stop: "Times Sq-42 St"))
    }

    @Test func missedWhenStillAtTheStop() throws {
        let trip = try nyc()
        let now = date("2026-11-26T23:01:30Z")
        let atStop = fix(trip.legs[1].from.coordinate, at: now)
        #expect(TransitConnectionCheck.problem(trip, legIndex: 1, location: atStop, rideProgress: 0, now: now)
                == .missed(line: "M104", stop: "7 AV/W 44 ST"))
        // On board, along the line: fine.
        let onBoard = fix(trip.legs[1].to.coordinate, at: now)
        #expect(TransitConnectionCheck.problem(trip, legIndex: 1, location: onBoard, rideProgress: 200, now: now) == nil)
        // A poor fix proves nothing.
        let poor = fix(trip.legs[1].from.coordinate, at: now, accuracy: 300)
        #expect(TransitConnectionCheck.problem(trip, legIndex: 1, location: poor, rideProgress: 0, now: now) == nil)
    }

    @Test func realtimeFromTheTripUpdatesTheRide() throws {
        let leg = try nyc().legs[1]
        let object = try JSON.object(try fixture("transitous-trip-nyc"), provider: "Transitous")
        var live = try #require(TransitousClient.itinerary(object))
        let merged = TransitRealtime.merge(leg, with: live)
        #expect(merged.start == date("2026-11-26T22:58:00Z"))
        #expect(merged.end == date("2026-11-26T23:00:00Z"))
        #expect(merged.realTime)
        // The same trip running 4 minutes late at the stop to get off, then cancelled.
        live.legs[0].to.arrival = date("2026-11-26T23:04:00Z")
        #expect(TransitRealtime.merge(leg, with: live).end == date("2026-11-26T23:04:00Z"))
        live.legs[0].cancelled = true
        #expect(TransitRealtime.merge(leg, with: live).isCancelled)
        // A trip that does not call at these stops changes nothing.
        live.legs[0].intermediateStops = []
        live.legs[0].from.stopID = "elsewhere"
        #expect(TransitRealtime.merge(leg, with: live) == leg)
    }
}

struct TransitOfflineTests {
    private var url: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("transit-\(UUID().uuidString)").appendingPathComponent("trip.json")
    }

    @Test func theStartedTripIsKeptWithEverythingToFollowIt() throws {
        let file = url
        let itinerary = try plan("transitous-plan-zurich-arriveby").itineraries[1]
        let saved = SavedTransitTrip(itinerary: itinerary, destinationName: "ETH Hönggerberg", savedAt: date("2026-11-27T06:30:00Z"))
        TransitTripCache.save(saved, to: file)
        let loaded = try #require(TransitTripCache.load(from: file))
        #expect(loaded == saved)
        #expect(loaded.itinerary.legs.map(\.from.track) == itinerary.legs.map(\.from.track))
        #expect(loaded.itinerary.legs[3].intermediateStops.count == 3)
        // The walks are followed from the saved copy as from the original.
        let original = try #require(TransitWalkRoute(leg: itinerary.legs[2], target: "Zürich Hardbrücke, Bahnhof"))
        let copy = try #require(TransitWalkRoute(leg: loaded.itinerary.legs[2], target: "Zürich Hardbrücke, Bahnhof"))
        #expect(copy.route.steps == original.route.steps)
        #expect(copy.route.coordinates.count == original.route.coordinates.count)
        #expect(loaded.isCurrent(now: date("2026-11-27T10:00:00Z")))
        #expect(!loaded.isCurrent(now: date("2026-11-28T10:00:00Z")))
        TransitTripCache.clear(at: file)
        #expect(TransitTripCache.load(from: file) == nil)
    }
}
