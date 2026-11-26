import MapKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: NavigationStore
    @ObservedObject private var network = NetworkMonitor.shared
    @ObservedObject private var roadFeatures = RoadFeatureStore.shared
    @StateObject private var guidanceMap = GuidanceMapModel()
    @State private var results: [MKMapItem] = []
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var featureSheet: FeatureSheet.Kind? = FeatureSheet.kindToShow()
    @State private var showsSettings = false
    @State private var showsOfflineMaps = false
    @State private var showsJunctions = false
    @State private var searchingOrigin = false
    @State private var mapboxToken = ProviderKeys.current.mapbox
    @State private var mapboxFailed = false
    @State private var mapboxRecenter = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var searching = false
    @State private var searchCompleted = false
    @State private var previewDetailsHeight: CGFloat = 0
    @FocusState private var searchFocused: Bool
    @AppStorage(AppSettings.Keys.mapSource) private var mapSource = "apple"
    @AppStorage(AppSettings.Keys.soundMode) private var soundMode = 0
    @AppStorage(AppSettings.Keys.buildings3D) private var buildings3D = true
    @AppStorage(AppSettings.Keys.vehicleScale) private var vehicleScale = 1.0
    @Environment(\.colorScheme) private var colorScheme

    private var isDriving: Bool { store.phase == .guiding || store.phase == .rerouting }
    private var accent: Color { colorScheme == .dark ? Color(red: 0.55, green: 0.77, blue: 1) : Color(red: 0.05, green: 0.31, blue: 0.74) }
    private var renderer: PhoneMapSource {
        .resolve(choice: mapSource, online: network.isOnline,
                 mapboxAvailable: mapboxToken?.hasPrefix("pk.") == true && !mapboxFailed)
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height && !searchFocused
            ZStack {
                mapCanvas
                    .ignoresSafeArea(.container)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { guidanceMap.viewHeight = Double($0) }
                VStack(spacing: 8) {
                    header(maxHeight: geometry.size.height)
                    if isDriving {
                        drivingOverlays(wide: wide, height: geometry.size.height)
                    } else {
                        Spacer(minLength: 0)
                        HStack {
                            Spacer()
                            mapControls
                        }
                    }
                    footer(maxHeight: geometry.size.height)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: wide ? 720 : .infinity)
            }
        }
        .onChange(of: colorScheme) { NotificationCenter.default.post(name: .phoneAppearanceChanged, object: nil) }
        .onChange(of: network.isOnline) { _, online in if online { mapboxFailed = false } }
        .onChange(of: mapSource) { mapboxFailed = false }
        .sheet(item: $featureSheet) { kind in FeatureSheet(kind: kind) }
        .sheet(isPresented: $showsSettings, onDismiss: {
            mapboxFailed = false
            mapboxToken = ProviderKeys.current.mapbox
        }) { SettingsView() }
        .sheet(isPresented: $showsOfflineMaps) { OfflineMapsView(store: store) }
        .sheet(isPresented: $showsJunctions) {
            if let route = store.selectedRoute {
                JunctionPreviewList(route: route) { index in
                    if let preview = JunctionPreview(route: route, stepIndex: index) { guidanceMap.player.play(preview) }
                }
            }
        }
        .task { await store.runPhoneAutomationIfRequested() }
    }

    // MARK: Maps

    @ViewBuilder
    private var mapCanvas: some View {
        switch renderer {
        case .openstreetmap:
            OpenMap(routes: store.routeOptions, selected: store.selectedRouteIndex, following: store.phase == .guiding,
                    camera: guidanceMap.camera, overview: guidanceMap.overview, overviewFit: guidanceMap.overviewFit,
                    marks: guidanceMap.marks, buildings3D: buildings3D,
                    onUserMove: { guidanceMap.userMovedMap() })
        case .mapbox:
            if let token = mapboxToken {
                MapboxPhoneMap(token: token, routes: store.routeOptions, selected: store.selectedRouteIndex,
                               following: store.phase == .guiding, camera: guidanceMap.camera, overview: guidanceMap.overview,
                               overviewFit: guidanceMap.overviewFit, marks: guidanceMap.marks, buildings3D: buildings3D,
                               vehicle: store.vehiclePose, vehicleScale: vehicleScale, recenter: mapboxRecenter,
                               onUserMove: { guidanceMap.userMovedMap() }, onFailure: { mapboxFailed = true })
                    .id(token)
            }
        case .apple:
            appleMap
        }
    }

    /// Apple Maps with its live traffic, the map used online by default.
    private var appleMap: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()
            ForEach(Array(store.routeOptions.enumerated()), id: \.element.id) { index, option in
                if index != store.selectedRouteIndex {
                    MapPolyline(coordinates: option.coordinates).stroke(.gray.opacity(0.7), lineWidth: 6)
                }
            }
            if let route = store.selectedRoute {
                MapPolyline(coordinates: route.coordinates).stroke(.cyan, lineWidth: 7)
                // Vignette motorways and low-emission zones on the route, where TomTom reports them.
                ForEach(Array((route.vignetteSections + route.lowEmissionSections).enumerated()), id: \.offset) { _, section in
                    MapPolyline(coordinates: route.coordinates(from: section.start, to: section.end)).stroke(.orange, lineWidth: 7)
                }
            }
            ForEach(store.stops, id: \.self) { stop in
                Marker(stop.name ?? String(localized: "Stop"), systemImage: "mappin", coordinate: stop.placemark.coordinate)
            }
            if let entrance = store.destination as? EntrancePlaceItem {
                Marker("Entrance", systemImage: "door.left.hand.open", coordinate: entrance.placemark.coordinate).tint(.blue)
            }
            GuidanceMarks(marks: guidanceMap.marks)
        }
        .mapStyle(.standard(elevation: buildings3D ? .realistic : .flat, showsTraffic: true))
        .onChange(of: guidanceMap.camera) { _, target in
            if let target {
                withAnimation(.linear(duration: 1)) { cameraPosition = .camera(MapCamera(target, viewHeight: guidanceMap.viewHeight)) }
            } else if store.phase == .previewing {
                withAnimation { cameraPosition = .automatic }
            }
        }
        .onChange(of: guidanceMap.overviewFit) {
            if let overview = guidanceMap.overview { withAnimation { cameraPosition = .overview(overview) } }
        }
        .onMapCameraChange {
            if cameraPosition.positionedByUser { guidanceMap.userMovedMap() }
        }
    }

    // MARK: Top of the screen

    @ViewBuilder
    private func header(maxHeight: CGFloat) -> some View {
        if let preview = guidanceMap.player.preview, let frame = guidanceMap.player.frame {
            JunctionPreviewBanner(preview: preview, frame: frame) { guidanceMap.player.stop() }
                .clipShape(RoundedRectangle(cornerRadius: 19))
                .frame(maxWidth: 490)
        } else if isDriving {
            maneuverBanner.frame(maxWidth: 490)
            if let alert = store.activeAlert {
                Label("\(alert.title) · \(alert.detail)", systemImage: alert.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.orange.gradient, in: Capsule())
            }
            if guidanceMap.showsOverview, let route = store.selectedRoute {
                RouteOverviewCard(route: route, update: store.guidance, destinationName: store.destination?.name ?? String(localized: "Destination"))
                    .clipShape(RoundedRectangle(cornerRadius: 19))
                    .frame(maxWidth: 490)
            }
        } else {
            searchPanel(maxHeight: maxHeight)
        }
    }

    @ViewBuilder
    private var maneuverBanner: some View {
        if store.phase == .rerouting {
            Label("Rerouting", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(12)
                .navigationSurface()
        } else if let route = store.selectedRoute, let update = store.guidance,
                  let index = update.upcomingStepIndex, route.steps.indices.contains(index) {
            let step = route.steps[index]
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 13) {
                    Image(systemName: step.symbolName)
                        .font(.system(size: 31, weight: .bold))
                        .frame(width: 44)
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(Self.distance(update.distanceToManeuver))
                                .font(.title2.weight(.bold)).monospacedDigit()
                            if !step.exitNumber.isEmpty { exitBadge("Exit \(step.exitNumber)") }
                            else if step.roundaboutExit > 0 { exitBadge("Exit \(step.roundaboutExit)") }
                        }
                        Text(step.street.isEmpty ? step.instruction : step.street)
                            .font(.headline).lineLimit(2)
                        if !step.signpost.isEmpty && step.signpost != step.street {
                            Text(step.signpost).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if step.isArrival, let side = VoicePromptPlanner.arrivalSide(step.maneuver) {
                            Label(side, systemImage: "flag").font(.subheadline)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if let lanes = route.laneSection(forStep: index, progress: update.progress,
                                                fastRoad: NavigationStore.isFastRoad(step: step, route: route, progress: update.progress)),
                   let image = LaneImage.image(LanePolicy.marked(lanes, maneuver: step.maneuver)) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 33)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.105, green: 0.16, blue: 0.23), in: RoundedRectangle(cornerRadius: 11))
                        .accessibilityLabel(LanePolicy.advice(lanes, maneuver: step.maneuver) ?? String(localized: "Lane guidance"))
                }
            }
            .padding(11)
            .navigationSurface()
            .accessibilityElement(children: .combine)
        }
    }

    private func exitBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .foregroundStyle(accent)
            .background(accent.opacity(0.12), in: Capsule())
    }

    private func searchPanel(maxHeight: CGFloat) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(accent).accessibilityHidden(true)
                TextField(searchingOrigin ? "Search for a starting point" : "Where to?", text: $store.searchText)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .onSubmit { search() }
                    .onChange(of: store.searchText) { _, _ in clearSearchResults() }
                if !store.searchText.isEmpty {
                    Button { store.searchText = ""; clearSearchResults() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Clear search")
                }
                Button { showsSettings = true } label: {
                    Image(systemName: "gearshape").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
            }
            .padding(.leading, 14)
            .navigationSurface(radius: 22)
            if store.phase == .idle || store.phase == .previewing || store.phase == .planning {
                VStack(spacing: 6) {
                    OriginRow(store: store, searchingOrigin: $searchingOrigin)
                    if searchingOrigin && store.customOrigin != nil {
                        Button {
                            searchingOrigin = false
                            Task { await useMyLocation(store) }
                        } label: {
                            Label("My location", systemImage: "location.fill").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 10)
                .navigationSurface(radius: 16)
            }
            if searching {
                ProgressView("Searching").padding(9).navigationSurface()
            } else if !results.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(results, id: \.self) { item in
                            Button { pick(item) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name ?? "Unnamed place").font(.headline)
                                    Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(11)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 11)
                        }
                    }
                }
                .frame(height: min(CGFloat(results.count) * 66, maxHeight * 0.46))
                .navigationSurface()
            } else if searchCompleted {
                Label("No places found", systemImage: "magnifyingglass")
                    .font(.footnote).padding(9).navigationSurface()
            }
            if !network.isOnline {
                Label("No signal: using offline maps", systemImage: "wifi.slash").font(.caption).padding(8).navigationSurface(radius: 13)
            } else if mapSource == "mapbox" && renderer == .openstreetmap {
                Label("Using OpenStreetMap", systemImage: "map").font(.caption).padding(8).navigationSurface(radius: 13)
            }
        }
        .buttonStyle(.plain)
    }

    /// A search result: the starting point while choosing one (a route on show is planned again from it), otherwise the
    /// destination.
    private func pick(_ item: MKMapItem) {
        searchFocused = false
        clearSearchResults()
        Task {
            if searchingOrigin {
                searchingOrigin = false
                store.searchText = ""
                store.setOrigin(item)
                if store.phase == .previewing, let destination = store.destination { await store.navigate(to: destination) }
            } else {
                await store.navigate(to: item)
            }
        }
    }

    private func clearSearchResults() {
        searchTask?.cancel()
        searchTask = nil
        results = []
        searching = false
        searchCompleted = false
    }

    private func search() {
        clearSearchResults()
        let query = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searching = true
        searchFocused = false
        searchTask = Task {
            let matches = await store.search(query)
            guard !Task.isCancelled else { return }
            results = matches
            searching = false
            searchCompleted = true
        }
    }

    // MARK: Middle of the screen

    private func drivingOverlays(wide: Bool, height: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                if store.phase == .guiding && (!wide || height >= 310) {
                    RoadEventTimeline(features: roadFeatures, progress: store.guidance?.progress ?? 0, compact: height < 460)
                }
                SpeedSignBadge(limit: store.speedLimit, speed: store.currentSpeed, next: store.nextLimitDrop)
                    .padding(6)
                    .navigationSurface(radius: 15)
            }
            Spacer(minLength: 0)
            mapControls
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var mapControls: some View {
        VStack(spacing: 6) {
            if isDriving {
                Button { VoiceGuidance.shared.toggleMute() } label: {
                    Image(systemName: soundMode == 2 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(soundMode == 2 ? "Unmute voice guidance" : "Mute voice guidance")
                Button { guidanceMap.cycleViewMode() } label: {
                    Image(systemName: guidanceMap.viewMode.symbolName).frame(width: 44, height: 44)
                }
                .accessibilityLabel(guidanceMap.viewMode.title)
                .accessibilityHint(Text("Switches to \(guidanceMap.viewMode.next.title)"))
                Button { guidanceMap.toggleOverview() } label: {
                    Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath").frame(width: 44, height: 44)
                }
                .accessibilityLabel(guidanceMap.showsOverview ? Text("Back to following") : Text("Route overview"))
            } else {
                Button { showsOfflineMaps = true } label: {
                    Image(systemName: "arrow.down.to.line").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Offline maps")
            }
            Button(action: recenter) {
                Image(systemName: isDriving && !guidanceMap.following ? "location" : "location.fill")
                    .foregroundStyle(accent).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Show my location")
        }
        .font(.system(size: 17, weight: .semibold))
        .buttonStyle(.plain)
        .navigationSurface(radius: 20)
    }

    private func recenter() {
        if isDriving {
            guidanceMap.recenter()
        } else {
            cameraPosition = .userLocation(fallback: .automatic)
            mapboxRecenter += 1
        }
    }

    // MARK: Bottom of the screen

    @ViewBuilder
    private func footer(maxHeight: CGFloat) -> some View {
        if isDriving, let route = store.selectedRoute {
            if store.phase == .guiding || store.tripNotice != nil || store.lastError != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = store.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                    TripTools(store: store)
                }
                .padding(9)
                .navigationSurface()
            }
            tripSummary(route)
        } else if store.phase == .previewing {
            routeChoices(maxHeight: maxHeight)
        } else if store.phase == .planning {
            ProgressView("Finding a route").padding(12).navigationSurface()
        } else if store.phase == .arrived {
            VStack(spacing: 8) {
                HStack {
                    Label("You have arrived", systemImage: "flag.checkered").font(.headline)
                    Spacer()
                    Button("Done") { store.stopNavigating() }.buttonStyle(.borderedProminent)
                }
                if !store.parkingNearby.isEmpty { TripTools(store: store) }
            }
            .padding(12)
            .navigationSurface()
        } else if results.isEmpty && !searchFocused && !searching {
            if let message = store.lastError {
                Label(message, systemImage: "exclamationmark.triangle").font(.footnote).padding(12).navigationSurface()
            } else if let trip = store.savedTrip, !searchCompleted {
                HStack {
                    Button {
                        Task { await store.resumeSavedTrip() }
                    } label: {
                        Label("Resume trip to \(trip.destinationName)", systemImage: "arrow.uturn.forward.circle")
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button { store.forgetSavedTrip() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("Forget saved trip")
                }
                .buttonStyle(.plain)
                .padding(.leading, 11)
                .navigationSurface()
            }
        }
    }

    /// Time and distance left, the arrival time and the button that ends the route.
    private func tripSummary(_ route: RouteOption) -> some View {
        let remaining = store.guidance?.remainingTime ?? route.expectedTravelTime
        let distance = store.guidance?.remainingDistance ?? route.distance
        let arrival = Date().addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened)
        return HStack(spacing: 9) {
            stat(Self.duration(remaining), label: "Remaining")
            stat(Self.distance(distance), label: "Distance")
            stat(arrival, label: "Arrival")
            Button(role: .destructive) { store.stopNavigating() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.red)
                    .background(.red.opacity(0.11), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End route")
        }
        .padding(8)
        .navigationSurface()
    }

    private func stat(_ value: String, label: LocalizedStringKey) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Route preview: every alternative with its time, distance and flags, the trip tools, and the button that starts guidance.
    private func routeChoices(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 7) {
                            ForEach(Array(store.routeOptions.enumerated()), id: \.element.id) { index, route in
                                routeChip(route, selected: index == store.selectedRouteIndex) { store.selectRoute(index) }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    RoutePreviewExtras(store: store)
                    Button {
                        showsJunctions = true
                    } label: {
                        Label("Preview a junction", systemImage: "play.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(guidanceMap.player.isPlaying)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewDetailsHeight = $0 }
            }
            .frame(height: min(previewDetailsHeight, maxHeight * 0.34))
            .scrollBounceBehavior(.basedOnSize)
            TripTools(store: store)
            HStack {
                Button { store.stopNavigating() } label: { Image(systemName: "xmark").frame(width: 36, height: 30) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Cancel route")
                if let origin = store.customOrigin,
                   RouteGeometry.distance(origin.placemark.coordinate, store.currentCoordinate) > 300 {
                    // A route from somewhere else is for looking ahead; to drive, it is planned again from the car.
                    Button {
                        Task { await useMyLocation(store) }
                    } label: {
                        Label("Plan from my location to drive", systemImage: "location.fill").frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        guidanceMap.player.stop()
                        store.startGuidance()
                    } label: {
                        Label("Start navigation", systemImage: "location.north.line.fill").frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(9)
        .navigationSurface()
    }

    private func routeChip(_ route: RouteOption, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.duration(route.expectedTravelTime)).font(.headline)
                Text("\(Self.distance(route.distance)) · \(route.name)")
                    .font(.caption).lineLimit(1)
                if let flags = Self.restrictionFlags(route) {
                    Text(flags).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
            }
            .foregroundStyle(selected ? accent : .primary)
            .padding(10)
            .background(selected ? accent.opacity(0.14) : Color.secondary.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// "Toll roads · Vignette: Austria · Low-emission zone", for comparing alternatives.
    static func restrictionFlags(_ option: RouteOption) -> String? {
        var flags: [String] = []
        if option.tollsKnown && !option.tollSections.isEmpty { flags.append(String(localized: "Toll roads")) }
        let countries = RouteRestrictions.vignetteCountries(option)
        if !countries.isEmpty { flags.append(RouteRestrictions.vignetteText(countries)) }
        if RouteRestrictions.entersLowEmissionZone(option) { flags.append(String(localized: "Low-emission zone")) }
        return flags.isEmpty ? nil : flags.joined(separator: " · ")
    }

    fileprivate static func distance(_ metres: Double) -> String {
        Measurement(value: max(metres, 0), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private static func duration(_ seconds: Double) -> String {
        Duration.seconds(max(60, seconds)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

/// The next traffic lights, level crossings and stop signs on the route, nearest first, from the same lookups as the map's
/// marks (`RoadFeatureStore`), so the list, the phone maps and CarPlay agree.
private struct RoadEventTimeline: View {
    @ObservedObject var features: RoadFeatureStore
    let progress: Double
    let compact: Bool

    var body: some View {
        let upcoming = Array(features.placed.filter { $0.offset > progress && $0.offset <= progress + 2_000 }.prefix(compact ? 2 : 3))
        VStack(alignment: .leading, spacing: 0) {
            if upcoming.isEmpty {
                Text(status)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 109, alignment: .leading)
                    .padding(8)
            } else {
                ForEach(Array(upcoming.enumerated()), id: \.offset) { index, placed in
                    HStack(spacing: 7) {
                        VStack(spacing: 0) {
                            Image(uiImage: MapMarkImages.image(for: placed.feature.kind))
                                .resizable()
                                .scaledToFit()
                                .frame(width: 26, height: 22)
                            if index < upcoming.count - 1 {
                                Rectangle().fill(.secondary.opacity(0.45)).frame(width: 1, height: 8)
                            }
                        }
                        Text(ContentView.distance(placed.offset - progress))
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(placed.feature.kind.title)
                    .accessibilityValue(ContentView.distance(placed.offset - progress))
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(upcoming.isEmpty ? 0 : 4)
        .frame(maxWidth: 125, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .navigationSurface(radius: 14)
    }

    private var status: String {
        switch features.status {
        case .idle, .loading: return String(localized: "Checking road events")
        case .ready: return String(localized: "No road events in the next 2 km")
        case .unavailable: return String(localized: "Road events unavailable")
        }
    }
}

private extension View {
    /// The floating card look of the guidance controls and panels.
    func navigationSurface(radius: CGFloat = 19) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(.primary.opacity(0.08), lineWidth: 1).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 3)
    }
}

extension Notification.Name {
    /// The phone switched between light and dark, for the CarPlay map set to follow the phone.
    static let phoneAppearanceChanged = Notification.Name("HorizonNavPhoneAppearanceChanged")
}
