import MapKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: NavigationStore
    @ObservedObject private var network = NetworkMonitor.shared
    @ObservedObject private var eventsModel: PhoneRoadEvents
    @State private var results: [MKMapItem] = []
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var followsVehicle = true
    @State private var lastAppleFix: Date?
    @State private var featureSheet: FeatureSheet.Kind? = FeatureSheet.kindToShow()
    @State private var showsSettings = false
    @State private var showsOfflineMaps = false
    @State private var mapboxToken = ProviderKeys.current.mapbox
    @State private var mapboxFailed = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searching = false
    @State private var searchCompleted = false
    @FocusState private var searchFocused: Bool
    @AppStorage(AppSettings.Keys.mapSource) private var mapSource = "apple"
    @AppStorage(AppSettings.Keys.mapPerspective) private var perspective = PhoneMapPerspective.automatic
    @AppStorage(AppSettings.Keys.vehicleScale) private var vehicleScale = 1.0
    @AppStorage(AppSettings.Keys.soundMode) private var soundMode = 0
    @Environment(\.colorScheme) private var colorScheme

    init(store: NavigationStore) {
        self.store = store
        self.eventsModel = store.roadEvents
    }

    private var isDriving: Bool { store.phase == .guiding || store.phase == .rerouting }
    private var accent: Color { colorScheme == .dark ? Color(red: 0.55, green: 0.77, blue: 1) : Color(red: 0.05, green: 0.31, blue: 0.74) }
    private var roadEvents: [RoadEvent] { isDriving ? eventsModel.upcoming : [] }
    private var renderer: PhoneMapSource {
        .resolve(choice: mapSource, online: network.isOnline,
                 mapboxAvailable: mapboxToken?.hasPrefix("pk.") == true && !mapboxFailed)
    }
    private var tracking: PhoneMapTracking {
        PhoneMapTracking(pose: store.vehiclePose, follows: followsVehicle && store.phase != .previewing,
                         navigating: isDriving, framing: PhoneMapTracking.framing(store: store, perspective: perspective),
                         vehicleScale: vehicleScale)
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height && !searchFocused
            ZStack {
                mapCanvas.ignoresSafeArea(.container)
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
                    footer
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: wide ? 720 : .infinity)
            }
        }
        .onChange(of: colorScheme) { NotificationCenter.default.post(name: .phoneAppearanceChanged, object: nil) }
        .onChange(of: network.isOnline) { _, online in if online { mapboxFailed = false } }
        .onChange(of: mapSource) { mapboxFailed = false; refreshAppleCamera(force: true) }
        .onChange(of: renderer, initial: true) { refreshAppleCamera(force: true) }
        .onChange(of: perspective) { refreshAppleCamera(force: true) }
        .onChange(of: store.vehiclePose?.location.timestamp) { refreshAppleCamera() }
        .onChange(of: store.selectedRoute?.id) { fitApplePreview() }
        .onChange(of: store.phase) { _, phase in
            if phase == .guiding || phase == .idle { followsVehicle = true; refreshAppleCamera(force: true) }
            if phase == .previewing { fitApplePreview() }
        }
        .sheet(item: $featureSheet) { kind in FeatureSheet(kind: kind) }
        .sheet(isPresented: $showsSettings, onDismiss: {
            mapboxFailed = false
            mapboxToken = ProviderKeys.current.mapbox
        }) { SettingsView() }
        .sheet(isPresented: $showsOfflineMaps) { OfflineMapsView(store: store) }
    }

    @ViewBuilder
    private var mapCanvas: some View {
        switch renderer {
        case .openstreetmap:
            OpenMap(routes: store.routeOptions, selected: store.selectedRouteIndex, tracking: tracking,
                    events: roadEvents, onGesture: { followsVehicle = false })
        case .mapbox:
            if let token = mapboxToken {
                MapboxPhoneMap(token: token, routes: store.routeOptions, selected: store.selectedRouteIndex,
                              events: roadEvents, tracking: tracking, onGesture: { followsVehicle = false },
                              onFailure: { mapboxFailed = true })
                    .id(token)
            }
        case .apple:
            appleMap
        }
    }

    private var appleMap: some View {
        Map(position: $cameraPosition) {
            if let pose = store.vehiclePose {
                Annotation("Vehicle", coordinate: pose.coordinate) {
                    Image(uiImage: PhoneMapArtwork.vehicle(scale: vehicleScale))
                        .rotationEffect(.degrees(pose.bearing - (followsVehicle ? tracking.bearing : (cameraPosition.camera?.heading ?? 0))))
                }
                .annotationTitles(.hidden)
            } else {
                UserAnnotation()
            }
            ForEach(Array(store.routeOptions.enumerated()), id: \.element.id) { index, option in
                if index != store.selectedRouteIndex {
                    MapPolyline(coordinates: option.coordinates).stroke(.gray.opacity(0.8), lineWidth: 5)
                }
            }
            if let route = store.selectedRoute { MapPolyline(coordinates: route.coordinates).stroke(Color.blue, lineWidth: 7) }
            ForEach(roadEvents) { event in
                Annotation(event.kind.title, coordinate: event.coordinate) {
                    Image(uiImage: PhoneMapArtwork.event(event.kind))
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .realistic, showsTraffic: true))
        .onChange(of: cameraPosition.positionedByUser) { _, user in if user { followsVehicle = false } }
    }

    private func refreshAppleCamera(force: Bool = false) {
        guard renderer == .apple else { return }
        if store.phase == .previewing { if force { fitApplePreview() }; return }
        guard tracking.follows else { return }
        guard let pose = tracking.pose else { if force { cameraPosition = .userLocation(fallback: .automatic) }; return }
        guard force || lastAppleFix != pose.location.timestamp else { return }
        lastAppleFix = pose.location.timestamp
        let distance = 820 * pow(2, 16.2 - tracking.zoom)
        withAnimation(.easeOut(duration: 0.50)) {
            cameraPosition = .camera(MapCamera(centerCoordinate: pose.coordinate, distance: distance,
                                               heading: tracking.bearing, pitch: tracking.pitch))
        }
    }

    private func fitApplePreview() {
        guard renderer == .apple, store.phase == .previewing else { return }
        let points = store.routeOptions.flatMap(\.coordinates).map(MKMapPoint.init)
        guard !points.isEmpty else { return }
        let box = points.reduce(MKMapRect.null) { $0.union(MKMapRect(x: $1.x, y: $1.y, width: 1, height: 1)) }
        withAnimation(.easeOut(duration: 0.45)) {
            cameraPosition = .rect(box.insetBy(dx: -max(600, box.width * 0.20), dy: -max(1_000, box.height * 0.48)))
        }
    }

    @ViewBuilder
    private func header(maxHeight: CGFloat) -> some View {
        if isDriving {
            maneuverBanner.frame(maxWidth: 490)
            if let alert = store.activeAlert {
                Label("\(alert.title) · \(alert.detail)", systemImage: alert.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.orange.gradient, in: Capsule())
            }
        } else {
            searchPanel(maxHeight: maxHeight)
        }
    }

    private func drivingOverlays(wide: Bool, height: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                if store.phase == .guiding && (!wide || height >= 310) {
                    RoadEventTimeline(model: eventsModel, compact: height < 460)
                }
                SpeedSignBadge(limit: store.speedLimit, speed: store.currentSpeed)
                    .padding(6)
                    .navigationSurface(radius: 15)
            }
            Spacer(minLength: 0)
            mapControls
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
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
                        .accessibilityLabel(LanePolicy.advice(lanes, maneuver: step.maneuver) ?? "Lane guidance")
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

    private var mapControls: some View {
        VStack(spacing: 6) {
            if isDriving {
                Button { VoiceGuidance.shared.toggleMute() } label: {
                    Image(systemName: soundMode == 2 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(soundMode == 2 ? "Unmute voice guidance" : "Mute voice guidance")
                Button {
                    perspective = perspective.next
                    recenter()
                } label: {
                    Text(perspective.label).font(.system(.caption, design: .monospaced, weight: .bold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Change map perspective")
                .accessibilityValue(perspective.label)
            } else {
                Button { showsOfflineMaps = true } label: {
                    Image(systemName: "arrow.down.to.line").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Offline maps")
            }
            Button(action: recenter) {
                Image(systemName: followsVehicle ? "location.fill" : "location")
                    .foregroundStyle(accent).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Center on vehicle")
        }
        .font(.system(size: 17, weight: .semibold))
        .buttonStyle(.plain)
        .navigationSurface(radius: 20)
    }

    private func recenter() {
        followsVehicle = true
        refreshAppleCamera(force: true)
    }

    private func searchPanel(maxHeight: CGFloat) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(accent).accessibilityHidden(true)
                TextField("Where to?", text: $store.searchText)
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
            if searching {
                ProgressView("Searching").padding(9).navigationSurface()
            } else if !results.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(results, id: \.self) { item in
                            Button {
                                searchFocused = false
                                clearSearchResults()
                                Task { await store.navigate(to: item) }
                            } label: {
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
                Label("Offline maps", systemImage: "wifi.slash").font(.caption).padding(8).navigationSurface(radius: 13)
            } else if mapSource == "mapbox" && renderer == .openstreetmap {
                Label("Using OpenStreetMap", systemImage: "map").font(.caption).padding(8).navigationSurface(radius: 13)
            }
        }
        .buttonStyle(.plain)
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

    @ViewBuilder
    private var footer: some View {
        if isDriving, let route = store.selectedRoute {
            if let faster = store.fasterRoute {
                HStack {
                    Button {
                        store.acceptFasterRoute()
                    } label: {
                        Label("Faster route · \(Self.duration(faster.expectedTravelTime))", systemImage: "arrow.triangle.branch")
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer(minLength: 4)
                    Button(action: store.dismissFasterRoute) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("Dismiss faster route")
                }
                .padding(.horizontal, 8)
                .navigationSurface()
            }
            tripSummary(route)
        } else if store.phase == .previewing {
            routeChoices
        } else if store.phase == .planning {
            ProgressView("Finding routes").padding(12).navigationSurface()
        } else if store.phase == .arrived {
            HStack {
                Label("You have arrived", systemImage: "flag.checkered").font(.headline)
                Spacer()
                Button("Done") { store.stopNavigating() }.buttonStyle(.borderedProminent)
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
            .accessibilityLabel("End navigation")
        }
        .padding(8)
        .navigationSurface()
    }

    private func stat(_ value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var routeChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(Array(store.routeOptions.enumerated()), id: \.element.id) { index, route in
                        let selected = index == store.selectedRouteIndex
                        Button { store.selectRoute(index) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Self.duration(route.expectedTravelTime)).font(.headline)
                                Text("\(Self.distance(route.distance)) · \(route.name)")
                                    .font(.caption).lineLimit(1)
                            }
                            .foregroundStyle(selected ? accent : .primary)
                            .padding(10)
                            .background(selected ? accent.opacity(0.14) : Color.secondary.opacity(0.10),
                                        in: RoundedRectangle(cornerRadius: 13))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            HStack {
                Button { store.stopNavigating() } label: { Image(systemName: "xmark").frame(width: 36, height: 30) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Cancel route")
                Button { store.startGuidance() } label: {
                    Label("Start navigation", systemImage: "location.fill").frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(9)
        .navigationSurface()
    }

    fileprivate static func distance(_ metres: Double) -> String {
        Measurement(value: max(metres, 0), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private static func duration(_ seconds: Double) -> String {
        Duration.seconds(max(60, seconds)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

private struct RoadEventTimeline: View {
    @ObservedObject var model: PhoneRoadEvents
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.upcoming.isEmpty {
                Text(status)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(8)
            } else {
                let events = Array(model.upcoming.prefix(compact ? 2 : 3))
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    HStack(spacing: 7) {
                        VStack(spacing: 0) {
                            Image(systemName: event.kind.symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(event.kind == .stop ? Color.red : Color.primary)
                                .frame(width: 26, height: 24)
                            if index < events.count - 1 {
                                Rectangle().fill(.secondary.opacity(0.45)).frame(width: 1, height: 8)
                            }
                        }
                        Text(ContentView.distance(event.progress - model.progress))
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(event.kind.title + crossingDetail(event))
                    .accessibilityValue(ContentView.distance(event.progress - model.progress))
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(model.upcoming.isEmpty ? 0 : 4)
        .frame(maxWidth: 125, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .navigationSurface(radius: 14)
    }

    private var status: String {
        switch model.state {
        case .awaitingFix: return "Waiting for route position"
        case .loading: return "Checking road events…"
        case .ready: return "No confirmed events nearby"
        case .unavailable: return "Road events unavailable"
        }
    }

    private func crossingDetail(_ event: RoadEvent) -> String {
        switch event.crossingBarrier {
        case "full": return ", full barriers"
        case "half", "double_half": return ", half barriers"
        case "yes": return ", barriers"
        case "no": return ", no barriers mapped"
        default: return ""
        }
    }
}

private extension View {
    func navigationSurface(radius: CGFloat = 19) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(.primary.opacity(0.08), lineWidth: 1).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 3)
    }
}

extension Notification.Name {
    static let phoneAppearanceChanged = Notification.Name("HorizonNavPhoneAppearanceChanged")
}
