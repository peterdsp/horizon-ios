import Combine
import CoreLocation
import MapKit
import os

/// Trip state shared by the phone UI and the CarPlay scene: planning, alternatives,
/// turn-by-turn guidance and the reroute lifecycle.
@MainActor
final class NavigationStore: NSObject, ObservableObject {
    static let shared = NavigationStore()

    enum Phase: Equatable {
        case idle
        case planning
        case previewing
        case guiding
        case rerouting
        case arrived
    }

    enum TripEvent {
        case guidanceStarted(RouteOption)
        case rerouteStarted
        case rerouteFinished(RouteOption)
        case rerouteFailed
        case arrived
        case ended
        case alert(NavigationAlert)
        /// A quicker route was found while driving; the store holds it in `fasterOffer`.
        case fasterRouteOffered(FasterRouteOffer)
        /// Car parks near the destination, offered from 1.7 km out.
        case parkingFound([ParkingSpot])
    }

    /// A quicker route found while driving, with what taking it changes besides the time.
    struct FasterRouteOffer: Equatable {
        var route: RouteOption
        var savedMinutes: Int
        var summary: String
    }

    /// A warning for the driver (Android `AlertInfo`): a speed camera ahead.
    struct NavigationAlert: Equatable {
        var kind: String
        var title: String
        var detail: String
        var symbol: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var destination: MKMapItem?
    @Published private(set) var routeOptions: [RouteOption] = []
    @Published private(set) var selectedRouteIndex = 0
    @Published private(set) var guidance: GuidanceUpdate?
    @Published private(set) var lastError: String?
    /// The posted limit where the car is, in metres per second, when the route carries limits.
    @Published private(set) var speedLimit: Double?
    @Published private(set) var currentSpeed: Double = 0
    /// The road the car is on: the road of the last manoeuvre passed.
    @Published private(set) var currentRoad = ""
    @Published private(set) var activeAlert: NavigationAlert?
    @Published var searchText = ""
    /// Where planning starts when it is not the car's position, to look at a route ahead of time.
    @Published private(set) var customOrigin: MKMapItem?
    /// Stops on the way, in order, and the roads avoided, for this trip only.
    @Published private(set) var stops: [MKMapItem] = []
    @Published private(set) var avoidedRoads: [AvoidedRoad] = []
    /// A plain message about the last trip change ("Avoiding Exit 12"), cleared with the trip.
    @Published var tripNotice: String?
    @Published private(set) var fasterOffer: FasterRouteOffer?
    /// The next lower limit ahead and how far it is, while the route carries limits.
    @Published private(set) var nextLimitDrop: SpeedLimitLookahead.Drop?
    @Published private(set) var parkingNearby: [ParkingSpot] = []
    /// Where to draw the car on the Mapbox map: on the route line while the fix agrees with it, with a steadied heading.
    @Published private(set) var vehiclePose: VehiclePose?

    let events = PassthroughSubject<TripEvent, Never>()
    let locationManager = CLLocationManager()
    var routing: RoutingProvider

    private var engine: RouteGuidance?
    private var voicePlanner = VoicePromptPlanner()
    private var cameras: [PlacedCamera] = []
    private var camerasRouteID: UUID?
    private var alertedCameras: Set<SpeedCamera> = []
    private var countryCode: String?
    private let log = Logger(subsystem: "com.horizonnav.ios", category: "guidance")
    /// The trip before the last avoided road, for Undo.
    private var beforeAvoid: (roads: [AvoidedRoad], options: [RouteOption], selected: Int)?
    private var spokenLimitDrops: Set<Double> = []
    private var lastFasterCheck = Date.distantPast
    private var fasterCheckRunning = false
    private var parkingAttempts = 0
    private var lastParkingAttempt = Date.distantPast
    private var cameraTask: Task<Void, Never>?
    /// Changes with each new plan, reroute or ended trip, so an answer that arrives late is dropped.
    private var planGeneration = UUID()

    static let fallbackCoordinate = CLLocationCoordinate2D(latitude: 51.5072, longitude: -0.1276)

    var selectedRoute: RouteOption? {
        routeOptions.indices.contains(selectedRouteIndex) ? routeOptions[selectedRouteIndex] : nil
    }

    var currentCoordinate: CLLocationCoordinate2D {
        locationManager.location?.coordinate ?? Self.fallbackCoordinate
    }

    var placeSearch = PlaceSearchService()

    /// The trip kept on the phone for guidance with no network, offered again after a restart.
    @Published private(set) var savedTrip: SavedTrip? = RouteCache.load()

    init(routing: RoutingProvider = FailoverRoutingProvider(
        online: KeyedRoutingProvider(),
        offline: OfflineRoutingChain(providers: [ValhallaRoutingProvider(), CachedRouteProvider()]),
        isOnline: { NetworkMonitor.shared.isOnlineNow })) {
        self.routing = routing
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .automotiveNavigation
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    func search(_ query: String) async -> [MKMapItem] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return await placeSearch.search(query, near: currentCoordinate)
    }

    /// Plans routes to a destination and enters route preview with the alternatives.
    func navigate(to item: MKMapItem) async {
        stopGuidance(notify: phase == .guiding || phase == .rerouting)
        phase = .planning
        let generation = UUID()
        planGeneration = generation
        lastError = nil
        stops = []
        avoidedRoads = []
        beforeAvoid = nil
        tripNotice = nil
        do {
            let options = withArrivalSide(try await routing.routes(for: planningRequest(to: item)), destination: item)
            guard planGeneration == generation, phase == .planning else { return }
            guard !options.isEmpty else { throw RoutingError.noRoute }
            destination = item
            routeOptions = options
            selectedRouteIndex = 0
            phase = .previewing
            saveTrip(options)
            log.info("Planned \(options.count, privacy: .public) route option(s)")
        } catch {
            guard planGeneration == generation, phase == .planning else { return }
            lastError = error.localizedDescription
            routeOptions = []
            destination = nil
            phase = .idle
            log.error("Route planning failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A request from the chosen start (or the car) with this trip's stops and avoided roads.
    private func planningRequest(to item: MKMapItem, alternatives: Bool = true) -> RouteRequest {
        RouteRequest(origin: customOrigin?.placemark.coordinate ?? currentCoordinate, destination: item,
                     heading: customOrigin == nil ? currentHeading : nil, wantsAlternatives: alternatives,
                     via: stops.map(\.placemark.coordinate), avoid: avoidedRoads)
    }

    /// The router's arrival side, corrected from the geometry when the destination is clearly to one side.
    private func withArrivalSide(_ options: [RouteOption], destination: MKMapItem) -> [RouteOption] {
        let place = (destination as? EntrancePlaceItem)?.building ?? destination.placemark.coordinate
        return options.map { option in
            var route = option
            if let last = route.steps.indices.last, route.steps[last].isArrival,
               let side = ArrivalSide.side(route: route.coordinates, destination: place) {
                route.steps[last].maneuver = side
            }
            return route
        }
    }

    /// Plans from somewhere other than the car, or from the car again with nil.
    func setOrigin(_ item: MKMapItem?) {
        customOrigin = item
    }

    /// Plans the current trip again in route preview after a stop or an avoided road changed, keeping the old routes on failure.
    private func replanPreview() async -> Bool {
        guard let destination, phase == .previewing else { return false }
        phase = .planning
        lastError = nil
        do {
            let options = withArrivalSide(try await routing.routes(for: planningRequest(to: destination)), destination: destination)
            routeOptions = options
            selectedRouteIndex = 0
            phase = .previewing
            saveTrip(options)
            return true
        } catch {
            lastError = error.localizedDescription
            phase = .previewing
            return false
        }
    }

    func selectRoute(_ index: Int) {
        guard routeOptions.indices.contains(index) else { return }
        selectedRouteIndex = index
        log.info("Selected route option \(index, privacy: .public)")
    }

    func startGuidance() {
        guard let route = selectedRoute, let start = route.coordinates.first, phase == .previewing || phase == .arrived else { return }
        engine = RouteGuidance(route: route)
        voicePlanner.reset()
        alertedCameras.removeAll()
        loadCameras(for: route)
        // A route planned from somewhere else is driven from the car.
        customOrigin = nil
        lastFasterCheck = Date()
        parkingAttempts = 0
        phase = .guiding
        locationManager.allowsBackgroundLocationUpdates = true
        if let location = locationManager.location { process(location) } else { guidance = engine?.update(with: CLLocation(latitude: start.latitude, longitude: start.longitude)) }
        events.send(.guidanceStarted(route))
        log.info("Guidance started with \(route.steps.count, privacy: .public) manoeuvres")
    }

    /// Keeps freshly planned routes for offline guidance. A route rebuilt from the saved trip is not saved over it.
    private func saveTrip(_ options: [RouteOption]) {
        guard let destination, let first = options.first else { return }
        if case .offline(let label) = first.source, label == String(localized: "Saved route") { return }
        RouteCache.save(destination: destination, routes: options)
        savedTrip = RouteCache.load()
    }

    /// Plans the saved trip again: online when there is signal, otherwise from the offline pack or the saved route itself.
    func resumeSavedTrip() async {
        guard let trip = savedTrip else { return }
        await navigate(to: trip.destinationItem)
    }

    func forgetSavedTrip() {
        RouteCache.clear()
        savedTrip = nil
    }

    func stopNavigating() {
        stopGuidance(notify: true)
        routeOptions = []
        destination = nil
        stops = []
        avoidedRoads = []
        beforeAvoid = nil
        tripNotice = nil
        phase = .idle
    }

    /// Speaks the call-outs due for the next manoeuvre.
    private func announce(_ update: GuidanceUpdate, speed: Double) {
        guard let route = selectedRoute,
              let index = update.upcomingStepIndex, route.steps.indices.contains(index) else { return }
        let step = route.steps[index]
        let fast = Self.isFastRoad(step: step, route: route, progress: update.progress)
        let lanes = route.laneSection(forStep: index, progress: update.progress, fastRoad: fast)
        for prompt in voicePlanner.prompts(stepIndex: index, step: step, distance: update.distanceToManeuver, speed: speed,
                                           lanes: lanes, fastRoad: fast, imperial: AppLocale.usesImperialDistances) {
            VoiceGuidance.shared.speak(prompt)
        }
    }

    /// Motorways and dual carriageways, where lanes are called much earlier: a numbered exit, or a limit of 80 km/h or more.
    nonisolated static func isFastRoad(step: RouteStep, route: RouteOption, progress: CLLocationDistance) -> Bool {
        !step.exitNumber.isEmpty || (route.speedLimit(at: progress) ?? 0) >= 80 / 3.6
    }

    /// Speed limit, current speed, current road and camera warnings for one fix.
    private func trackRoadState(_ update: GuidanceUpdate, location: CLLocation) {
        guard let route = selectedRoute else { return }
        currentSpeed = max(location.speed, 0)
        speedLimit = route.speedLimit(at: update.progress)
        trackLimitDrop(on: route, progress: update.progress)
        if let index = update.upcomingStepIndex, index > 0 { currentRoad = route.steps[index - 1].street } else if update.upcomingStepIndex == 0 { currentRoad = "" }
        guard camerasEnabled, let warning = SpeedCameras.warning(cameras, progress: update.progress, speed: currentSpeed,
                                                                 heading: location.course >= 0 ? location.course : nil),
              alertedCameras.insert(warning.0.camera).inserted else { return }
        let ahead = warning.1
        let distance = Measurement(value: ahead, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
        let alert = NavigationAlert(kind: "camera", title: String(localized: "Speed camera ahead"), detail: distance, symbol: "camera.fill")
        activeAlert = alert
        events.send(.alert(alert))
        VoiceGuidance.shared.speak(VoicePrompt(key: "camera", text: alert.title, isAlert: true))
        log.info("Speed camera warning at \(Int(ahead), privacy: .public) m")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.activeAlert == alert { self?.activeAlert = nil }
        }
    }

    /// Camera warnings follow Settings, and stay off where they are against the law.
    private var camerasEnabled: Bool {
        AppSettings.cameraWarnings && !SpeedCameras.bannedCountries.contains(countryCode ?? "")
    }

    /// Cameras along a new route: online from OpenStreetMap, and from the offline packs that cover it.
    private func loadCameras(for route: RouteOption) {
        guard camerasRouteID != route.id else { return }
        camerasRouteID = route.id
        cameras = []
        if let here = locationManager.location {
            CLGeocoder().reverseGeocodeLocation(here) { [weak self] placemarks, _ in
                let code = placemarks?.first?.isoCountryCode
                Task { @MainActor in if let code { self?.countryCode = code } }
            }
        }
        let lats = route.coordinates.map(\.latitude), lons = route.coordinates.map(\.longitude)
        guard let south = lats.min(), let north = lats.max(), let west = lons.min(), let east = lons.max() else { return }
        cameraTask?.cancel()
        cameraTask = Task { [weak self] in
            var found: [SpeedCamera] = []
            for pack in OfflinePackStorage.installedPacks() {
                if let text = try? String(contentsOf: pack.camerasURL, encoding: .utf8) {
                    found += SpeedCameras.parsePackFile(text, south: south, west: west, north: north, east: east)
                }
            }
            if NetworkMonitor.shared.isOnlineNow, let online = try? await SpeedCameras.fetch(along: route) { found += online }
            let placed = SpeedCameras.place(found, on: route)
            guard !Task.isCancelled, let self, self.camerasRouteID == route.id else { return }
            self.cameras = placed
            self.log.info("\(placed.count, privacy: .public) speed camera(s) on the route")
        }
    }

    private func stopGuidance(notify: Bool) {
        VoiceGuidance.shared.stop()
        speedLimit = nil
        nextLimitDrop = nil
        spokenLimitDrops = []
        fasterOffer = nil
        parkingNearby = []
        currentRoad = ""
        activeAlert = nil
        cameras = []
        camerasRouteID = nil
        cameraTask?.cancel()
        cameraTask = nil
        planGeneration = UUID()
        engine = nil
        guidance = nil
        locationManager.allowsBackgroundLocationUpdates = false
        if notify { events.send(.ended) }
    }

    private var currentHeading: CLLocationDirection? {
        guard let course = locationManager.location?.course, course >= 0 else { return nil }
        return course
    }

    func process(_ location: CLLocation) {
        guard CLLocationCoordinate2DIsValid(location.coordinate), location.horizontalAccuracy >= 0 else { return }
        guard phase == .guiding, let engine else {
            updateVehicle(with: location, matched: nil)
            return
        }
        let update = engine.update(with: location)
        guidance = update
        let onRouteLine = update.status == .onRoute && location.horizontalAccuracy <= 30 && update.distanceFromRoute <= 15
        updateVehicle(with: location, matched: onRouteLine ? engine.route.point(atProgress: update.progress)?.coordinate : nil)
        announce(update, speed: max(location.speed, 0))
        trackRoadState(update, location: location)
        passStops(progress: update.progress)
        checkFasterRoute(update, location: location)
        checkParking(update)
        switch update.status {
        case .arrived:
            phase = .arrived
            locationManager.allowsBackgroundLocationUpdates = false
            forgetSavedTrip()
            log.info("Arrived")
            events.send(.arrived)
            findParkingAtArrival()
        case .rerouteNeeded:
            log.info("Off route, rerouting")
            Task { await reroute(from: location) }
        case .onRoute, .offRoute:
            break
        }
    }

    /// Requests a fresh route from the current position, keeping the old one if that fails.
    @discardableResult
    func reroute(from location: CLLocation) async -> Bool {
        guard phase == .guiding, let destination else { return false }
        phase = .rerouting
        let generation = planGeneration
        events.send(.rerouteStarted)
        let heading = location.course >= 0 ? location.course : nil
        do {
            let options = withArrivalSide(try await routing.routes(for: RouteRequest(
                origin: location.coordinate, destination: destination, heading: heading, wantsAlternatives: false,
                via: stops.map(\.placemark.coordinate), avoid: avoidedRoads)), destination: destination)
            guard phase == .rerouting, planGeneration == generation else { return false }
            guard let route = options.first else { throw RoutingError.noRoute }
            routeOptions = [route]
            selectedRouteIndex = 0
            saveTrip([route])
            engine = RouteGuidance(route: route)
            voicePlanner.reset()
            loadCameras(for: route)
            phase = .guiding
            lastError = nil
            guidance = engine?.update(with: location)
            log.info("Reroute finished, \(route.steps.count, privacy: .public) manoeuvres")
            events.send(.rerouteFinished(route))
            return true
        } catch {
            guard phase == .rerouting, planGeneration == generation else { return false }
            phase = .guiding
            lastError = error.localizedDescription
            log.error("Reroute failed: \(error.localizedDescription, privacy: .public)")
            events.send(.rerouteFailed)
            return false
        }
    }

    /// Swaps in routes without asking the router (Undo, a quicker route), the way a finished reroute does while guiding.
    private func adopt(_ options: [RouteOption], selected: Int) {
        guard options.indices.contains(selected) else { return }
        routeOptions = options
        selectedRouteIndex = selected
        saveTrip(options)
        guard phase == .guiding, let route = selectedRoute else { return }
        engine = RouteGuidance(route: route)
        voicePlanner.reset()
        loadCameras(for: route)
        if let location = locationManager.location { guidance = engine?.update(with: location) }
        events.send(.rerouteFinished(route))
    }

    // MARK: Trip changes: stops, avoided roads, quicker routes, parking

    /// The trip's routes planned again with the current stops and avoided roads: in preview, or from the car while guiding.
    private func replanTrip() async -> Bool {
        if phase == .previewing { return await replanPreview() }
        guard phase == .guiding, let location = locationManager.location else { return false }
        return await reroute(from: location)
    }

    /// Adds a stop on the way and plans the trip through it (Android `NavEngine.addStop`).
    func addStop(_ item: MKMapItem) async {
        guard destination != nil else { return }
        let before = stops
        stops.append(item)
        if await replanTrip() {
            tripNotice = String(localized: "Stop added: \(item.name ?? String(localized: "Stop"))")
        } else {
            stops = before
        }
    }

    func removeStop(_ item: MKMapItem) async {
        let before = stops
        stops.removeAll { $0 === item }
        if !(await replanTrip()) { stops = before }
    }

    /// Stops the car has driven past are dropped, so a later reroute does not send it back to them.
    private func passStops(progress: CLLocationDistance) {
        guard !stops.isEmpty, let route = selectedRoute else { return }
        stops.removeAll { stop in
            guard let p = RouteGeometry.project(stop.placemark.coordinate, onto: route) else { return false }
            return p.progress < progress - 30 && p.distance < 300
        }
    }

    /// Plans the trip without one road and checks the new route really leaves it out. Apple Maps and the saved route cannot
    /// avoid a road, so the driver is told and the trip is left as it was.
    func avoid(_ road: AvoidedRoad) async {
        let previous = (roads: avoidedRoads, options: routeOptions, selected: selectedRouteIndex)
        avoidedRoads.append(road)
        guard await replanTrip(), let route = selectedRoute else {
            avoidedRoads = previous.roads
            return
        }
        guard RouteAvoidance.stillUsed([road], by: route).isEmpty else {
            avoidedRoads = previous.roads
            adopt(previous.options, selected: previous.selected)
            switch route.source {
            case .online("Apple Maps"):
                tripNotice = String(localized: "Apple Maps cannot avoid a single road. Add a TomTom or Mapbox key in Settings to avoid it.")
            case .offline:
                tripNotice = String(localized: "With no signal, the saved route cannot avoid a road. Download a routing pack in Offline maps.")
            default:
                tripNotice = String(localized: "No way round \(road.name) was found, so the route is unchanged.")
            }
            log.info("Avoiding a road failed with \(String(describing: route.source), privacy: .public)")
            return
        }
        beforeAvoid = previous
        tripNotice = String(localized: "Avoiding \(road.name) for this trip.")
        log.info("Avoiding a road, \(self.avoidedRoads.count, privacy: .public) avoided")
    }

    var canUndoAvoid: Bool { beforeAvoid != nil }

    /// Puts back the trip from before the last avoided road, without asking the router again.
    func undoAvoid() {
        guard let before = beforeAvoid else { return }
        beforeAvoid = nil
        avoidedRoads = before.roads
        adopt(before.options, selected: before.selected)
        tripNotice = nil
    }

    /// The next lower limit for the sign, and its spoken cue when chosen in Settings. Updated only when it changes by more
    /// than 15 m, as Android does, so the sign does not redraw on every fix.
    private func trackLimitDrop(on route: RouteOption, progress: CLLocationDistance) {
        let drop = SpeedLimitLookahead.nextDrop(in: route.speedLimits, progress: progress, speed: currentSpeed, showing: nextLimitDrop != nil)
        if drop?.metersPerSecond != nextLimitDrop?.metersPerSecond || abs((drop?.distance ?? 0) - (nextLimitDrop?.distance ?? 0)) > 15 {
            nextLimitDrop = drop
        }
        guard let drop, AppSettings.speakLimitDrops, spokenLimitDrops.insert(drop.start).inserted else { return }
        let distance = VoicePromptPlanner.spokenDistance(drop.distance, imperial: AppLocale.usesImperialDistances)
        VoiceGuidance.shared.speak(VoicePrompt(key: "limit", text: String(localized: "Speed limit \(SpeedDisplay.value(drop.metersPerSecond)) in \(distance)"), isAlert: true))
    }

    /// Every 2 minutes with 5 or more left, fresh routes are asked for from the car and a clearly quicker one is offered
    /// (Android `NavEngine.checkFaster`). Keep, or no answer within 25 seconds, waits 5 minutes before the next look.
    private func checkFasterRoute(_ update: GuidanceUpdate, location: CLLocation) {
        guard AppSettings.fasterRoutes, fasterOffer == nil, !fasterCheckRunning, update.status == .onRoute,
              update.remainingTime >= FasterRoutePolicy.minimumRemaining, NetworkMonitor.shared.isOnlineNow,
              Date().timeIntervalSince(lastFasterCheck) >= FasterRoutePolicy.checkInterval,
              let destination, let route = selectedRoute else { return }
        lastFasterCheck = Date()
        fasterCheckRunning = true
        let start = RouteGeometry.index(atProgress: update.progress, cumulative: route.cumulative)
        let ahead = Array(route.coordinates[start...])
        let request = RouteRequest(origin: location.coordinate, destination: destination, heading: location.course >= 0 ? location.course : nil,
                                   wantsAlternatives: true, via: stops.map(\.placemark.coordinate), avoid: avoidedRoads)
        let routing = self.routing
        Task { [weak self] in
            let fresh = (try? await routing.routes(for: request)) ?? []
            let offer = await Task.detached(priority: .utility) { FasterRoutePolicy.offer(fresh: fresh, ahead: ahead) }.value
            guard let self else { return }
            self.fasterCheckRunning = false
            // An answer that took so long the car is well past where it was asked from starts behind the car: drop it.
            guard let offer, self.phase == .guiding, self.selectedRoute?.id == route.id,
                  let latest = self.guidance, abs(latest.progress - update.progress) < 400 else { return }
            let shown = FasterRouteOffer(route: self.withArrivalSide([offer.faster], destination: destination)[0], savedMinutes: offer.savedMinutes,
                                         summary: RouteChange.summary(savedMinutes: offer.savedMinutes, current: offer.same, candidate: offer.faster))
            self.fasterOffer = shown
            self.events.send(.fasterRouteOffered(shown))
            VoiceGuidance.shared.speak(VoicePrompt(key: "faster", text: String(localized: "A faster route is available, saving \(offer.savedMinutes) minutes"), isAlert: true))
            self.log.info("Quicker route offered: \(shown.summary, privacy: .public)")
            try? await Task.sleep(for: .seconds(FasterRoutePolicy.offerDuration))
            if self.fasterOffer == shown { self.dismissFasterRoute() }
        }
    }

    /// Switches to the offered route (Android `acceptFaster`).
    func acceptFasterRoute() {
        guard let offer = fasterOffer, phase == .guiding else { return }
        // The car has to be on the offered route still; after a turn off it, the offer no longer applies.
        if let location = locationManager.location,
           (RouteGeometry.project(location.coordinate, onto: offer.route)?.distance ?? .infinity) > 40 {
            dismissFasterRoute()
            return
        }
        fasterOffer = nil
        adopt([offer.route], selected: 0)
        tripNotice = String(localized: "Switched to the faster route")
    }

    /// Keeps the current route and waits 5 minutes before looking again (Android `dismissFaster`).
    func dismissFasterRoute() {
        fasterOffer = nil
        lastFasterCheck = Date().addingTimeInterval(FasterRoutePolicy.cooldown)
    }

    /// The car for the Mapbox map: held still at a crawl so it does not wander, and turned smoothly with the course.
    private func updateVehicle(with location: CLLocation, matched: CLLocationCoordinate2D?) {
        let previous = vehiclePose
        if location.horizontalAccuracy > 65, previous != nil { return }
        let coordinate = matched ?? location.coordinate
        let previousBearing = previous?.bearing ?? max(location.course, 0)
        let bearing = location.speed > 2.3 && location.course >= 0
            ? PhoneCameraPolicy.easedBearing(from: previousBearing, to: location.course, amount: 0.55)
            : previousBearing
        let stableCoordinate: CLLocationCoordinate2D
        if location.speed < 1.5, let previous, RouteGeometry.distance(previous.coordinate, coordinate) < 6 {
            stableCoordinate = previous.coordinate
        } else {
            stableCoordinate = coordinate
        }
        vehiclePose = VehiclePose(coordinate: stableCoordinate, bearing: bearing, location: location)
    }

    /// Car parks near the destination, looked for from 1.7 km out, up to 3 times 40 seconds apart (Android `checkParking`).
    private func checkParking(_ update: GuidanceUpdate) {
        guard AppSettings.parkingPrompt, parkingNearby.isEmpty, parkingAttempts < ParkingSearch.attempts,
              Date().timeIntervalSince(lastParkingAttempt) >= ParkingSearch.retryAfter,
              let destination, let route = selectedRoute, NetworkMonitor.shared.isOnlineNow,
              ParkingSearch.shouldOffer(remaining: update.remainingDistance, routeLength: route.length, destinationName: destination.name ?? "") else { return }
        parkingAttempts += 1
        lastParkingAttempt = Date()
        let place = (destination as? EntrancePlaceItem)?.building ?? destination.placemark.coordinate
        Task { [weak self] in
            let spots = await ParkingSearch.find(near: place)
            guard let self, !spots.isEmpty, self.phase == .guiding, self.destination === destination else { return }
            self.parkingNearby = spots
            self.events.send(.parkingFound(spots))
            self.log.info("\(spots.count, privacy: .public) car park(s) near the destination")
        }
    }

    /// At arrival with no car park offered yet, the nearest ones are looked up once (Android `arrivalMoment`).
    private func findParkingAtArrival() {
        guard AppSettings.parkingPrompt, parkingNearby.isEmpty, NetworkMonitor.shared.isOnlineNow, let destination,
              !ParkingSearch.isCarPark(destination.name ?? "") else { return }
        let place = (destination as? EntrancePlaceItem)?.building ?? destination.placemark.coordinate
        Task { [weak self] in
            let spots = await ParkingSearch.find(near: place)
            guard let self, !spots.isEmpty, self.phase == .arrived, self.destination === destination else { return }
            self.parkingNearby = spots
        }
    }

    /// Drives to a car park instead of the destination (Android `parkAt`), keeping guidance running.
    func park(at spot: ParkingSpot) async {
        let item = spot.mapItem
        parkingNearby = []
        if phase == .arrived {
            await navigate(to: item)
            startGuidance()
            return
        }
        let before = (destination, stops)
        destination = item
        stops = []
        if !(await replanTrip()) { (destination, stops) = before }
    }
}

extension NavigationStore: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated { self.process(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { }
}
