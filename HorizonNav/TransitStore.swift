import Combine
import CoreLocation
import MapKit
import os
import UIKit
import UserNotifications

/// Public transport on the phone: planning with Transitous, comparing and opening itineraries, and following one with
/// walking guidance, stop alerts, realtime checks and a saved copy for no signal. Separate from `NavigationStore`, so
/// driving and CarPlay are not touched; it has its own location manager, which runs only while a trip is followed.
@MainActor
final class TransitStore: NSObject, ObservableObject {
    static let shared = TransitStore()

    enum Phase: Equatable {
        case idle
        case planning
        case results
        case navigating
    }

    @Published private(set) var phase: Phase = .idle
    @Published var timeMode: TransitTimeMode = .now
    @Published var time = Date()
    @Published var sort: TransitSort = .arrival
    @Published private(set) var itineraries: [TransitItinerary] = []
    /// The itinerary opened from the list.
    @Published var selected: TransitItinerary?
    @Published private(set) var error: String?
    @Published private(set) var loadingMore = false
    @Published private(set) var destinationName = ""
    @Published private(set) var originName = ""
    /// The search the list shows, with its time, so the choice stays visible while comparing.
    @Published private(set) var shownQuery: TransitQuery?

    // While following a trip
    @Published private(set) var trip: TransitItinerary?
    @Published private(set) var legIndex = 0
    /// Opened from the saved copy: the times are those known when it was saved.
    @Published private(set) var fromSavedCopy = false
    @Published private(set) var savedAt: Date?
    @Published private(set) var walk: TransitWalkRoute?
    @Published private(set) var walkUpdate: GuidanceUpdate?
    @Published private(set) var ride: TransitRideProgress?
    @Published private(set) var arrived = false
    @Published private(set) var problem: TransitProblem?
    @Published private(set) var replacement: TransitItinerary?
    @Published private(set) var findingReplacement = false
    /// The last stop alert, shown on the screen as well as spoken and notified.
    @Published private(set) var stopNotice: String?
    @Published private(set) var location: CLLocation?
    @Published private(set) var savedTrip: SavedTransitTrip? = TransitTripCache.load()

    private var query: TransitQuery?
    private var earlierCursor: String?
    private var laterCursor: String?
    private var planGeneration = UUID()
    private var destination = CLLocationCoordinate2D()
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        return manager
    }()
    private var engine: RouteGuidance?
    private var walkPrompts = WalkingPromptPlanner()
    private var stopAlerts = StopAlertPlanner()
    private var rideLine: RouteOption?
    private var rideOffsets: [CLLocationDistance] = []
    private var rerouting = false
    private var lastRefresh: [String: Date] = [:]
    private var refreshing = false
    private var dismissedProblems: [TransitProblem] = []
    private var lastReplacementSearch = Date.distantPast
    private var clock: Task<Void, Never>?
    private let log = Logger(subsystem: "com.horizonnav.ios", category: "transit")

    /// A ride's realtime state is asked for at most this often while waiting for it, and less often on board.
    static let refreshWhileWaiting: TimeInterval = 180
    static let refreshOnBoard: TimeInterval = 300
    /// Realtime is first asked for this long before the ride leaves.
    static let refreshLead: TimeInterval = 20 * 60
    /// At most one search for a new itinerary in this time.
    static let replacementInterval: TimeInterval = 120

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    var shownItineraries: [TransitItinerary] { TransitComparison.sorted(itineraries, by: sort) }
    var currentLeg: TransitLeg? { trip.flatMap { $0.legs.indices.contains(legIndex) ? $0.legs[legIndex] : nil } }
    var canSearchEarlier: Bool { earlierCursor != nil }
    var canSearchLater: Bool { laterCursor != nil }

    /// Whether the time options on screen differ from the search the list shows.
    var timeChanged: Bool {
        guard let shownQuery, var q = query else { return false }
        q.timeMode = timeMode
        q.time = time
        return q != shownQuery
    }

    // MARK: Planning

    /// Plans trips to a place, from a chosen start or from where the phone is. Only called when the person picks Transit.
    func plan(to item: MKMapItem, from origin: MKMapItem?, here: CLLocationCoordinate2D) async {
        destination = item.placemark.coordinate
        destinationName = item.name ?? String(localized: "Destination")
        originName = origin?.name ?? String(localized: "My location")
        query = TransitQuery(origin: origin?.placemark.coordinate ?? here, destination: destination)
        selected = nil
        await search()
    }

    /// Searches again with the time options on screen.
    func search() async {
        guard var q = query else { return }
        q.timeMode = timeMode
        q.time = timeMode == .now ? Date() : time
        query = q
        phase = .planning
        error = nil
        selected = nil
        let generation = UUID()
        planGeneration = generation
        do {
            let plan = try await TransitousClient.plan(q)
            guard planGeneration == generation else { return }
            itineraries = plan.itineraries.map(named)
            earlierCursor = plan.earlierCursor
            laterCursor = plan.laterCursor
            if plan.itineraries.isEmpty { error = String(localized: "No public transport trips were found for this time.") }
            log.info("Transit plan: \(plan.itineraries.count, privacy: .public) itineraries")
        } catch {
            guard planGeneration == generation else { return }
            itineraries = []
            earlierCursor = nil
            laterCursor = nil
            self.error = Self.explain(error)
            log.error("Transit plan failed: \(error.localizedDescription, privacy: .public)")
        }
        shownQuery = q
        phase = .results
    }

    /// The page of trips before or after the ones listed, using the cursor the service returned.
    func searchMore(later: Bool) async {
        guard let q = shownQuery, let cursor = later ? laterCursor : earlierCursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let plan = try await TransitousClient.plan(q, cursor: cursor)
            let known = Set(itineraries.map(\.id))
            let fresh = plan.itineraries.filter { !known.contains($0.id) && !$0.isWalkOnly }.map(named)
            itineraries = later ? itineraries + fresh : fresh + itineraries
            if later { laterCursor = plan.laterCursor } else { earlierCursor = plan.earlierCursor }
        } catch {
            self.error = Self.explain(error)
        }
    }

    /// The service calls the two ends START and END: they get the names of the places chosen.
    private func named(_ itinerary: TransitItinerary) -> TransitItinerary {
        var out = itinerary
        for i in out.legs.indices {
            if out.legs[i].from.name == "START" { out.legs[i].from.name = originName }
            if out.legs[i].to.name == "END" { out.legs[i].to.name = destinationName }
        }
        return out
    }

    static func explain(_ error: Error) -> String {
        if RoutingFallbackPolicy.shouldUseOffline(error) {
            return String(localized: "No connection. Public transport is planned online; a trip you started opens from the saved copy.")
        }
        return error.localizedDescription
    }

    func close() {
        planGeneration = UUID()
        if phase == .navigating { endTrip() }
        phase = .idle
        itineraries = []
        selected = nil
        error = nil
        shownQuery = nil
        query = nil
    }

    // MARK: Following a trip

    /// Starts a trip and keeps it on the phone for no signal.
    func start(_ itinerary: TransitItinerary) {
        let saved = SavedTransitTrip(itinerary: itinerary, destinationName: destinationName, savedAt: Date())
        TransitTripCache.save(saved)
        savedTrip = saved
        begin(itinerary, savedCopy: false, savedAt: saved.savedAt)
    }

    /// Opens the saved trip, with or without a connection. Its times are the saved ones until realtime updates them.
    func openSavedTrip() {
        guard let saved = savedTrip else { return }
        destinationName = saved.destinationName
        begin(saved.itinerary, savedCopy: true, savedAt: saved.savedAt)
    }

    func forgetSavedTrip() {
        TransitTripCache.clear()
        savedTrip = nil
    }

    private func begin(_ itinerary: TransitItinerary, savedCopy: Bool, savedAt: Date) {
        endTrip()
        trip = itinerary
        fromSavedCopy = savedCopy
        self.savedAt = savedAt
        destination = itinerary.legs.last?.to.coordinate ?? destination
        arrived = false
        problem = nil
        replacement = nil
        dismissedProblems = []
        lastRefresh = [:]
        stopAlerts.reset()
        phase = .navigating
        // Start where the rider is: past legs that have ended are skipped when the trip is opened late.
        let now = Date()
        legIndex = itinerary.legs.firstIndex { $0.end > now } ?? 0
        locationManager.requestWhenInUseAuthorization()
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.startUpdatingLocation()
        if TransitSettings.stopAlert != .off {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        enterLeg(announce: true)
        clock = Task { [weak self] in
            // Underground or with the screen off, fixes can stop: the timetable moves the trip on every 20 seconds.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.tick()
            }
        }
        log.info("Transit trip started with \(itinerary.legs.count, privacy: .public) legs")
    }

    func endTrip() {
        clock?.cancel()
        clock = nil
        if trip != nil {
            locationManager.stopUpdatingLocation()
            locationManager.allowsBackgroundLocationUpdates = false
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: (0..<(trip?.legs.count ?? 0)).map(Self.notificationID))
        VoiceGuidance.shared.stop()
        trip = nil
        walk = nil
        walkUpdate = nil
        engine = nil
        ride = nil
        rideLine = nil
        problem = nil
        replacement = nil
        stopNotice = nil
        arrived = false
        if phase == .navigating { phase = itineraries.isEmpty ? .idle : .results }
    }

    /// Moves to the next or previous leg by hand, for when the position cannot tell (underground, or a change of plan).
    func moveLeg(by step: Int) {
        guard let trip, trip.legs.indices.contains(legIndex + step) else { return }
        legIndex += step
        arrived = false
        enterLeg(announce: true)
    }

    private func enterLeg(announce: Bool) {
        guard let trip, let leg = currentLeg else { return }
        walk = nil
        walkUpdate = nil
        engine = nil
        ride = nil
        stopNotice = nil
        rideLine = nil
        walkPrompts.reset()
        if leg.isTransit {
            locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            locationManager.distanceFilter = 40
            rideLine = TransitRide.line(leg)
            rideOffsets = TransitRide.stopOffsets(leg, line: rideLine)
            ride = TransitRide.progress(leg, line: rideLine, offsets: rideOffsets, location: location, now: Date())
            scheduleStopNotification(for: leg)
            if announce { speak(Self.boardingText(leg), key: "board\(legIndex)") }
        } else {
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = 5
            let target = Self.walkTarget(trip, legIndex: legIndex)
            walk = TransitWalkRoute(leg: leg, target: target)
            if let route = walk?.route {
                engine = RouteGuidance(route: route)
                if let location { walkUpdate = engine?.update(with: location) }
                if announce {
                    speak(String(localized: "Walk to \(target), \(VoicePromptPlanner.spokenDistance(route.distance, imperial: AppLocale.usesImperialDistances))"),
                          key: "walk\(legIndex)")
                }
            }
        }
        refreshIfDue()
    }

    /// The stop to walk to with its platform, or the destination at the end.
    static func walkTarget(_ trip: TransitItinerary, legIndex: Int) -> String {
        let leg = trip.legs[legIndex]
        guard legIndex + 1 < trip.legs.count, let next = trip.legs[(legIndex + 1)...].first(where: \.isTransit) else {
            return leg.to.name.isEmpty || leg.to.name == "END" ? String(localized: "your destination") : leg.to.name
        }
        if let platform = TransitFormat.platform(next.from) { return "\(next.from.name), \(platform)" }
        return next.from.name
    }

    /// "Take the U7 towards Rathaus Spandau from platform 2 at 23:56. Get off at Richard-Wagner-Platz, 13 stops."
    static func boardingText(_ leg: TransitLeg) -> String {
        let towards = leg.headsign.isEmpty ? "" : String(localized: " towards \(leg.headsign)")
        let platform = leg.from.track.isEmpty ? "" : String(localized: " from platform \(leg.from.track)")
        let stops = leg.intermediateStops.count + 1
        let time = TransitFormat.time(leg.start, zone: leg.from.timeZone)
        return stops == 1
            ? String(localized: "Take the \(leg.line)\(towards)\(platform) at \(time). Get off at the next stop, \(leg.to.name).")
            : String(localized: "Take the \(leg.line)\(towards)\(platform) at \(time). Get off at \(leg.to.name), \(stops) stops.")
    }

    private func process(_ location: CLLocation) {
        guard CLLocationCoordinate2DIsValid(location.coordinate), location.horizontalAccuracy >= 0 else { return }
        self.location = location
        guard phase == .navigating, let leg = currentLeg, !arrived else { return }
        if leg.isTransit {
            updateRide(leg, now: Date())
        } else if let engine {
            let update = engine.update(with: location)
            walkUpdate = update
            if let index = update.upcomingStepIndex, engine.route.steps.indices.contains(index) {
                for prompt in walkPrompts.prompts(stepIndex: index, step: engine.route.steps[index], distance: update.distanceToManeuver,
                                                  imperial: AppLocale.usesImperialDistances) {
                    VoiceGuidance.shared.speak(prompt)
                }
            }
            switch update.status {
            case .arrived: finishWalk()
            case .rerouteNeeded: rerouteWalk(from: location, to: leg.to.coordinate)
            case .onRoute, .offRoute: break
            }
        }
        checkConnections()
    }

    /// Without fixes, the timetable keeps the ride's stops counting down, and realtime is checked when due.
    private func tick() {
        guard phase == .navigating, let leg = currentLeg, !arrived else { return }
        if leg.isTransit { updateRide(leg, now: Date()) }
        checkConnections()
        refreshIfDue()
    }

    private func updateRide(_ leg: TransitLeg, now: Date) {
        let progress = TransitRide.progress(leg, line: rideLine, offsets: rideOffsets, location: location, now: now)
        ride = progress
        for alert in stopAlerts.alerts(rideKey: "\(legIndex)-\(leg.tripID)", progress: progress, setting: TransitSettings.stopAlert) {
            deliver(alert, leg: leg)
        }
        // Off at the stop: close to it with a good position, or past its arrival time by the timetable.
        let atStop = progress.metresToStop.map { $0 <= 80 } ?? false
        let pastByTimetable = progress.metresToStop == nil && now > (leg.to.arrival ?? leg.end).addingTimeInterval(60)
        if progress.departed && (atStop || progress.stopsRemaining == 0 || pastByTimetable) { advance() }
    }

    private func finishWalk() {
        advance()
    }

    private func advance() {
        guard let trip else { return }
        if legIndex + 1 < trip.legs.count {
            legIndex += 1
            enterLeg(announce: true)
        } else {
            arrived = true
            walk = nil
            ride = nil
            engine = nil
            speak(String(localized: "You have arrived"), key: "arrived")
            locationManager.stopUpdatingLocation()
            locationManager.allowsBackgroundLocationUpdates = false
            clock?.cancel()
            log.info("Transit trip arrived")
        }
    }

    /// Off the walking path: a new walk from Apple Maps to the same stop, when there is a connection. With none, guidance
    /// stays on the saved path.
    private func rerouteWalk(from location: CLLocation, to target: CLLocationCoordinate2D) {
        guard !rerouting, NetworkMonitor.shared.isOnlineNow else { return }
        rerouting = true
        let index = legIndex
        Task { [weak self] in
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: target))
            request.transportType = .walking
            let route = try? await MKDirections(request: request).calculate().routes.first
            guard let self else { return }
            self.rerouting = false
            guard let route, self.legIndex == index, self.currentLeg?.isWalk == true else { return }
            let walk = TransitWalkRoute(appleRoute: route)
            self.walk = walk
            self.engine = RouteGuidance(route: walk.route)
            self.walkPrompts.reset()
            if let fix = self.location { self.walkUpdate = self.engine?.update(with: fix) }
            self.log.info("Walk rerouted")
        }
    }

    // MARK: Stop alerts

    private func deliver(_ alert: StopAlert, leg: TransitLeg) {
        let text: String
        switch alert {
        case let .approaching(stops, minutes):
            text = stops == 1
                ? String(localized: "Next stop: \(leg.to.name). Get ready to get off.")
                : String(localized: "\(stops) stops to \(leg.to.name), about \(minutes) min.")
        case .getOffNow:
            text = String(localized: "Get off at \(leg.to.name).")
        }
        stopNotice = text
        speak(text, key: "stop\(legIndex)\(alert == .getOffNow ? "n" : "e")")
        if TransitSettings.stopHaptics { UINotificationFeedbackGenerator().notificationOccurred(alert == .getOffNow ? .success : .warning) }
        // Shown at once, replacing the one scheduled by the timetable, so it is on the lock screen with the screen off.
        notify(id: Self.notificationID(legIndex), title: leg.line.isEmpty ? leg.to.name : "\(leg.line) · \(leg.to.name)", body: text, at: nil)
        log.info("Stop alert: \(text, privacy: .public)")
    }

    /// In case fixes stop coming with the phone in a pocket, the early alert is also scheduled by the timetable.
    private func scheduleStopNotification(for leg: TransitLeg) {
        let setting = TransitSettings.stopAlert
        guard setting != .off, let when = StopAlertPlanner.scheduledTime(for: leg, setting: setting), when > Date() else { return }
        let body = setting.stops == 1
            ? String(localized: "Next stop: \(leg.to.name). Get ready to get off.")
            : String(localized: "Get off soon at \(leg.to.name), at \(TransitFormat.time(leg.to.arrival ?? leg.end, zone: leg.to.timeZone)).")
        notify(id: Self.notificationID(legIndex), title: leg.line.isEmpty ? leg.to.name : "\(leg.line) · \(leg.to.name)", body: body, at: when)
    }

    nonisolated static func notificationID(_ legIndex: Int) -> String { "transit-stop-\(legIndex)" }

    private func notify(id: String, title: String, body: String, at date: Date?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = date.map { UNTimeIntervalNotificationTrigger(timeInterval: max($0.timeIntervalSinceNow, 1), repeats: false) }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private func speak(_ text: String, key: String) {
        VoiceGuidance.shared.speak(VoicePrompt(key: key, text: text, isAlert: true))
    }

    // MARK: Realtime, missed and cancelled connections

    /// Asks for the current or next ride's realtime state when it is due: from 20 minutes before it leaves until it
    /// arrives, every 3 minutes while waiting and every 5 on board. Nothing is asked with no connection.
    private func refreshIfDue() {
        guard let trip, !refreshing, NetworkMonitor.shared.isOnlineNow else { return }
        let now = Date()
        guard let index = trip.legs.indices.first(where: { $0 >= legIndex && trip.legs[$0].isTransit && trip.legs[$0].end > now }) else { return }
        let leg = trip.legs[index]
        guard !leg.tripID.isEmpty, now >= leg.start.addingTimeInterval(-Self.refreshLead) else { return }
        let interval = now >= leg.start ? Self.refreshOnBoard : Self.refreshWhileWaiting
        if let last = lastRefresh[leg.tripID], now.timeIntervalSince(last) < interval { return }
        lastRefresh[leg.tripID] = now
        refreshing = true
        Task { [weak self] in
            let live = try? await TransitousClient.trip(leg.tripID)
            guard let self else { return }
            self.refreshing = false
            guard let live, var current = self.trip, current.legs.indices.contains(index), current.legs[index].tripID == leg.tripID else { return }
            let merged = TransitRealtime.merge(current.legs[index], with: live)
            guard merged != current.legs[index] else { return }
            current.legs[index] = merged
            current.end = current.legs.last?.end ?? current.end
            self.trip = current
            self.fromSavedCopy = false
            if index == self.legIndex {
                self.rideOffsets = TransitRide.stopOffsets(merged, line: self.rideLine)
                self.scheduleStopNotification(for: merged)
            }
            self.checkConnections()
            self.log.info("Realtime updated for a ride")
        }
    }

    private func checkConnections() {
        guard let trip, phase == .navigating, !arrived else { return }
        let rideProgress: CLLocationDistance? = {
            guard let line = rideLine, let location, let p = RouteGeometry.project(location.coordinate, onto: line) else { return nil }
            return p.progress
        }()
        let found = TransitConnectionCheck.problem(trip, legIndex: legIndex, location: location, rideProgress: rideProgress, now: Date())
        guard found != problem else { return }
        guard let found, !dismissedProblems.contains(found) else {
            if found == nil { problem = nil; replacement = nil }
            return
        }
        problem = found
        replacement = nil
        speak(found.message, key: "problem")
        notify(id: "transit-problem", title: String(localized: "Public transport"), body: found.message, at: nil)
        log.info("Transit problem: \(found.message, privacy: .public)")
        findReplacement()
    }

    /// One search for a new itinerary from where the rider is (or the current stop), leaving now.
    func findReplacement() {
        guard !findingReplacement, NetworkMonitor.shared.isOnlineNow,
              Date().timeIntervalSince(lastReplacementSearch) >= Self.replacementInterval else { return }
        let origin = location?.coordinate ?? currentLeg?.from.coordinate ?? NavigationStore.shared.currentCoordinate
        let query = TransitQuery(origin: origin, destination: destination)
        findingReplacement = true
        lastReplacementSearch = Date()
        Task { [weak self] in
            let plan = try? await TransitousClient.plan(query)
            guard let self else { return }
            self.findingReplacement = false
            let now = Date()
            self.originName = String(localized: "My location")
            self.replacement = TransitComparison.sorted((plan?.itineraries ?? []).map(self.named).filter { !$0.isCancelled && $0.start >= now.addingTimeInterval(-60) }, by: .arrival).first
            if self.replacement == nil, self.problem != nil { self.error = String(localized: "No other trip was found from here.") }
        }
    }

    func acceptReplacement() {
        guard let replacement else { return }
        start(replacement)
    }

    func keepTrip() {
        if let problem { dismissedProblems.append(problem) }
        problem = nil
        replacement = nil
    }

    /// Phone automation for screenshots and checks: `-HNTransitAutoTest "lat,lon;lat,lon"` plans from the first point to the
    /// second, opens the first itinerary and, with `-HNTransitAutoStart`, starts it (debug builds only).
    func runAutomationIfRequested() async {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-HNTransitAutoTest"), i + 1 < arguments.count else { return }
        let points = arguments[i + 1].split(separator: ";").map { $0.split(separator: ",").compactMap { Double($0) } }
        guard points.count == 2, points.allSatisfy({ $0.count == 2 }) else { return }
        let from = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: points[0][0], longitude: points[0][1])))
        from.name = String(localized: "Start")
        let to = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: points[1][0], longitude: points[1][1])))
        to.name = arguments.firstIndex(of: "-HNTransitAutoName").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? String(localized: "Destination")
        if arguments.contains("-HNTransitAutoArriveBy") {
            timeMode = .arriveBy
            time = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.date(bySettingHour: 8, minute: 30, second: 0, of: Date()) ?? Date()) ?? Date()
        }
        await plan(to: to, from: from, here: from.placemark.coordinate)
        if arguments.contains("-HNTransitAutoDetail") || arguments.contains("-HNTransitAutoStart") { selected = shownItineraries.first { !$0.isWalkOnly } }
        if arguments.contains("-HNTransitAutoStart"), let selected { start(selected) }
        #endif
    }
}

extension TransitStore: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated { self.process(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { }
}

extension TransitStore: UNUserNotificationCenterDelegate {
    /// With the app open, the alert is already on screen and spoken: the notification only plays its sound.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.sound, .list]
    }
}
