import MapKit
import SwiftUI

/// The planner's From row: the car's position, or a starting point searched for to look at a route ahead of time.
struct OriginRow: View {
    @ObservedObject var store: NavigationStore
    @Binding var searchingOrigin: Bool

    var body: some View {
        HStack {
            Image(systemName: store.customOrigin == nil ? "location.fill" : "mappin.circle.fill").foregroundStyle(.cyan)
            Text("From").foregroundStyle(.secondary)
            Button {
                searchingOrigin.toggle()
            } label: {
                Text(store.customOrigin?.name ?? String(localized: "My location"))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityHint("Search for a different starting point")
            if store.customOrigin != nil {
                Button {
                    Task { await useMyLocation(store) }
                } label: {
                    Label("My location", systemImage: "location")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Start from my location")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
    }
}

/// Plans from the car again, re-planning the route on show.
@MainActor
func useMyLocation(_ store: NavigationStore) async {
    store.setOrigin(nil)
    if store.phase == .previewing, let destination = store.destination { await store.navigate(to: destination) }
}

/// Under the route choices: vignettes and zones with their rules, the offline download, and the trip tools.
struct RoutePreviewExtras: View {
    @ObservedObject var store: NavigationStore
    @ObservedObject private var maps = OfflineMapStore.shared
    @ObservedObject private var packs = OfflinePackStore.shared
    @State private var areaID: String?
    @State private var suggestion: PackRegion?
    @State private var suggestionFor: UUID?

    var body: some View {
        if let route = store.selectedRoute {
            VStack(alignment: .leading, spacing: 8) {
                restrictions(route)
                offline(route)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: route.id) { await suggestPack(for: route) }
        }
    }

    /// Vignette motorways and low-emission zones, with links to the rules (TomTom routes only).
    @ViewBuilder
    private func restrictions(_ route: RouteOption) -> some View {
        let countries = RouteRestrictions.vignetteCountries(route)
        if !countries.isEmpty {
            Label(RouteRestrictions.vignetteText(countries), systemImage: "ticket").foregroundStyle(.orange)
            ForEach(countries.filter { RouteRestrictions.officialVignetteLink($0) != nil }, id: \.self) { code in
                Link(String(localized: "Vignette rules: \(Locale.current.localizedString(forRegionCode: code) ?? code)"),
                     destination: RouteRestrictions.officialVignetteLink(code)!)
            }
        }
        if RouteRestrictions.entersLowEmissionZone(route) {
            Label("Enters a low-emission zone", systemImage: "leaf").foregroundStyle(.orange)
            Link("Low-emission zone rules", destination: RouteRestrictions.lowEmissionZoneRules)
        }
    }

    /// One tap saves the map along the route; the line under it says whether routing packs cover the trip with no signal.
    @ViewBuilder
    private func offline(_ route: RouteOption) -> some View {
        let area = maps.areas.first { $0.id == areaID }
        if let area {
            if area.complete {
                Label("Map saved for offline use", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                ProgressView(value: area.fraction) { Text("Saving the map along the route") }
            }
        } else {
            Button {
                let name = String(localized: "Route to \(store.destination?.name ?? String(localized: "Destination"))")
                areaID = maps.downloadRoute(name: name, coordinates: route.coordinates)
            } label: {
                Label("Download for offline", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
        }
        let points = OfflineCoverage.checkpoints(of: route)
        if let pack = OfflineCoverage.pack(covering: points, among: packs.installed) {
            Label("Offline routing covered by \(pack.name)", systemImage: "checkmark.seal").foregroundStyle(.secondary)
        } else if let id = packs.downloadingID {
            ProgressView(value: packs.progress) { Text("Downloading \(PackCatalog.region(id)?.name ?? id)") }
        } else {
            Label("No routing pack covers this trip: with no signal, guidance follows the saved route only", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            if let suggestion, !packs.installed.contains(where: { $0.id == suggestion.id }) {
                Button {
                    packs.download(suggestion)
                } label: {
                    Label("Download routing pack: \(suggestion.name)", systemImage: "square.and.arrow.down")
                }
            }
        }
    }

    /// The pack for the first part of the trip no installed pack covers (Android "near you", for the route).
    private func suggestPack(for route: RouteOption) async {
        guard suggestionFor != route.id else { return }
        suggestionFor = route.id
        suggestion = nil
        let points = OfflineCoverage.checkpoints(of: route)
        guard OfflineCoverage.pack(covering: points, among: packs.installed) == nil,
              let uncovered = points.first(where: { p in !packs.installed.contains { $0.contains(p) } }) ?? points.last else { return }
        suggestion = await PackSuggestion.fetch(near: uncovered)
    }
}

/// Trip tools under the route summary: stops, avoiding a road, the last change with Undo, a quicker route and parking.
struct TripTools: View {
    @ObservedObject var store: NavigationStore
    @State private var showsStops = false
    @State private var showsAvoid = false

    var body: some View {
        VStack(spacing: 8) {
            if let offer = store.fasterOffer { fasterCard(offer) }
            if !store.parkingNearby.isEmpty { parkingCard }
            if let notice = store.tripNotice {
                HStack {
                    Text(notice).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    if store.canUndoAvoid { Button("Undo") { store.undoAvoid() }.font(.caption.weight(.semibold)) }
                    Button { store.tripNotice = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss")
                }
            }
            if store.phase == .previewing || store.phase == .guiding {
                HStack {
                    Button { showsStops = true } label: { Label("Stops", systemImage: "fuelpump") }
                    Button { showsAvoid = true } label: { Label("Avoid a road", systemImage: "nosign") }
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
            }
        }
        .sheet(isPresented: $showsStops) { StopsAlongRouteView(store: store) }
        .sheet(isPresented: $showsAvoid) { AvoidRoadView(store: store) }
        #if DEBUG
        // `-HNPhoneAutoSheet stops` or `avoid` opens that sheet once a route is shown, for simulator checks.
        .onChange(of: store.phase) {
            guard store.phase == .previewing else { return }
            switch UserDefaults.standard.string(forKey: "HNPhoneAutoSheet") {
            case "stops": showsStops = true
            case "avoid": showsAvoid = true
            default: break
            }
        }
        #endif
    }

    /// "Faster route found" with what changes, and Switch or Keep (Android `FasterStrip`).
    private func fasterCard(_ offer: NavigationStore.FasterRouteOffer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Faster route found", systemImage: "arrow.triangle.branch").font(.headline)
            Text(offer.summary).font(.subheadline)
            HStack {
                Button("Switch") { store.acceptFasterRoute() }.buttonStyle(.borderedProminent)
                Button("Keep") { store.dismissFasterRoute() }.buttonStyle(.bordered)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
    }

    /// "Parking near <destination>" with each car park's walk and details (Android parking chips).
    private var parkingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Parking near \(store.destination?.name ?? String(localized: "your destination"))").font(.subheadline.weight(.semibold))
            ForEach(store.parkingNearby) { spot in
                Button {
                    Task { await store.park(at: spot) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("P \(spot.name) · \(spot.walkMinutes) min walk").font(.subheadline)
                        let detail = spot.hasMappedEntrance ? [spot.details, String(localized: "to the vehicle entrance")].filter { !$0.isEmpty }.joined(separator: " · ") : spot.details
                        if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

/// Places along the rest of the route by category, each with how far ahead it is and the extra time, and Add stop.
struct StopsAlongRouteView: View {
    @ObservedObject var store: NavigationStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: StopKind?
    @State private var results: [RouteStop] = []
    @State private var searching = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                if !store.stops.isEmpty {
                    Section("Your stops") {
                        ForEach(store.stops, id: \.self) { stop in
                            HStack {
                                Text(stop.name ?? String(localized: "Stop"))
                                Spacer()
                                Button("Remove", role: .destructive) { Task { await store.removeStop(stop) } }
                            }
                        }
                    }
                }
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(StopKind.allCases) { k in
                                Button {
                                    kind = k
                                } label: {
                                    Label(k.title, systemImage: k.symbol)
                                }
                                .buttonStyle(.bordered)
                                .tint(kind == k ? .cyan : .secondary)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                } footer: {
                    Text("Places ahead on the route. The extra time includes getting back to the route.")
                }
                if searching {
                    ProgressView("Searching along the route")
                } else if failed {
                    Text("The place search did not answer. Check the connection and try again.").foregroundStyle(.secondary)
                } else if kind != nil && results.isEmpty {
                    Text("Nothing found ahead").foregroundStyle(.secondary)
                }
                ForEach(results) { stop in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stop.name).font(.headline)
                            Text("\(Measurement(value: stop.distanceAhead, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))) ahead · +\(stop.detourMinutes) min")
                                .font(.caption).foregroundStyle(.secondary)
                            if !stop.subtitle.isEmpty { Text(stop.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                        Button("Add stop") {
                            Task { await store.addStop(stop.mapItem) }
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Stops along the route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: kind) { await search() }
            #if DEBUG
            .onAppear { if kind == nil { kind = UserDefaults.standard.string(forKey: "HNPhoneAutoStop").flatMap(StopKind.init(rawValue:)) } }
            #endif
        }
    }

    private func search() async {
        guard let kind, let route = store.selectedRoute else { return }
        searching = true
        failed = false
        results = []
        let progress = store.phase == .guiding ? store.guidance?.progress ?? 0 : 0
        let found = await RouteStopSearch.find(kind, along: route, progress: progress)
        results = found ?? []
        failed = found == nil
        searching = false
    }
}

/// The roads and exits of the selected route, to avoid one for this trip (Android "Avoid road" and the turn list).
struct AvoidRoadView: View {
    @ObservedObject var store: NavigationStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let route = store.selectedRoute {
                    let progress = store.phase == .guiding ? store.guidance?.progress ?? 0 : 0
                    if store.phase == .guiding, let road = RouteAvoidance.roadAhead(progress: progress, on: route,
                                                                                    name: store.currentRoad.isEmpty ? String(localized: "the road ahead") : store.currentRoad) {
                        Button { avoid(road) } label: {
                            Label("Avoid the road ahead", systemImage: "arrow.up.circle")
                        }
                    }
                    Section {
                        ForEach(Array(route.steps.enumerated()), id: \.offset) { index, step in
                            if step.startProgress > progress, let road = RouteAvoidance.road(after: index, on: route) {
                                Button { avoid(road) } label: {
                                    HStack {
                                        Image(systemName: step.symbolName).frame(width: 28)
                                        VStack(alignment: .leading) {
                                            Text(road.name).lineLimit(1)
                                            Text(Measurement(value: step.startProgress - progress, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Roads and exits on this route")
                    } footer: {
                        Text(footer)
                    }
                }
            }
            .navigationTitle("Avoid a road")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    /// Says up front when the route's service cannot avoid one road.
    private var footer: String {
        if !NetworkMonitor.shared.isOnlineNow {
            return String(localized: "With no signal, only a routing pack can plan round a road.")
        }
        if store.routing.name == "Apple Maps" {
            return String(localized: "Apple Maps cannot avoid a single road. Add a TomTom or Mapbox key in Settings to use this.")
        }
        return String(localized: "The route is planned again without the road you pick, for this trip only. You can undo it.")
    }

    private func avoid(_ road: AvoidedRoad) {
        Task { await store.avoid(road) }
        dismiss()
    }
}

// MARK: - Simulator automation

extension NavigationStore {
    /// Debug builds only, like the CarPlay `-HNCarPlayAutoTest`: `-HNPhoneAutoTest "<destination>"` plans a route through the
    /// same calls the phone UI makes, with `-HNPhoneAutoOrigin "<place>"` as the starting point, for runtime checks of the
    /// route preview in a simulator where taps cannot be scripted.
    func runPhoneAutomationIfRequested() async {
        #if DEBUG
        guard let query = UserDefaults.standard.string(forKey: "HNPhoneAutoTest"), !query.isEmpty else { return }
        try? await Task.sleep(for: .seconds(2))
        if let from = UserDefaults.standard.string(forKey: "HNPhoneAutoOrigin"), let origin = await search(from).first { setOrigin(origin) }
        guard let destination = await search(query).first else { return }
        await navigate(to: destination)
        #endif
    }
}
