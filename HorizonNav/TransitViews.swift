import MapKit
import SwiftUI

/// Public transport on the phone: the time options and the trips to compare, one trip's legs, and the screen that follows
/// it. Drawn over the driving screen while transit is in use, with its own map.
struct TransitScreen: View {
    @ObservedObject var transit: TransitStore
    @ObservedObject private var network = NetworkMonitor.shared
    @State private var camera: MapCameraPosition = .automatic
    @State private var showsTripDetails = false
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { colorScheme == .dark ? Color(red: 0.55, green: 0.77, blue: 1) : Color(red: 0.05, green: 0.31, blue: 0.74) }

    /// The itinerary on the map: the one followed, the one opened, or the first in the list.
    private var mapped: TransitItinerary? { transit.trip ?? transit.selected ?? transit.shownItineraries.first }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                TransitMap(itinerary: mapped, currentLeg: transit.phase == .navigating ? transit.legIndex : nil, camera: $camera)
                    .ignoresSafeArea(.container)
                VStack(spacing: 8) {
                    if transit.phase == .navigating {
                        TransitGuidanceHeader(transit: transit, accent: accent)
                        Spacer(minLength: 0)
                        HStack {
                            Spacer()
                            recenterButton
                        }
                        TransitTripBar(transit: transit, showsDetails: $showsTripDetails)
                    } else {
                        planHeader
                        Spacer(minLength: 0)
                        if let selected = transit.selected {
                            TransitItineraryDetail(itinerary: selected, transit: transit, accent: accent, maxHeight: geometry.size.height * 0.52)
                        } else {
                            results(maxHeight: geometry.size.height * 0.5)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: mapped?.id) { camera = transit.phase == .navigating ? .userLocation(fallback: .automatic) : .automatic }
        .onChange(of: transit.phase) { _, phase in
            withAnimation { camera = phase == .navigating ? .userLocation(fallback: .automatic) : .automatic }
        }
        .sheet(isPresented: $showsTripDetails) {
            if let trip = transit.trip {
                NavigationStack {
                    ScrollView { TransitLegList(itinerary: trip, current: transit.legIndex, accent: accent).padding() }
                        .navigationTitle(transit.destinationName)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsTripDetails = false } } }
                        .safeAreaInset(edge: .bottom) { TransitAttribution().padding(8) }
                }
            }
        }
    }

    private var recenterButton: some View {
        Button { withAnimation { camera = .userLocation(fallback: .automatic) } } label: {
            Image(systemName: "location.fill").foregroundStyle(accent).frame(width: 44, height: 44)
        }
        .font(.system(size: 17, weight: .semibold))
        .buttonStyle(.plain)
        .transitSurface(radius: 20)
        .accessibilityLabel("Show my location")
    }

    // MARK: Planning

    private var planHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { transit.close() } label: { Image(systemName: "chevron.backward").frame(width: 36, height: 36) }
                    .accessibilityLabel("Back to the map")
                VStack(alignment: .leading, spacing: 1) {
                    Text(transit.destinationName).font(.headline).lineLimit(1)
                    Text("From \(transit.originName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "tram.fill").foregroundStyle(accent).accessibilityHidden(true)
            }
            Picker("When", selection: $transit.timeMode) {
                ForEach(TransitTimeMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                if transit.timeMode != .now {
                    DatePicker("Time", selection: $transit.time, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
                Spacer(minLength: 0)
                if transit.timeChanged {
                    Button { Task { await transit.search() } } label: { Label("Find trips", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent)
                        .disabled(transit.phase == .planning)
                } else if let shown = transit.shownQuery {
                    Text(Self.shownTime(shown)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(11)
        .transitSurface()
    }

    /// "Arrive by Fri 28 Nov, 08:30", the time the list was searched for.
    static func shownTime(_ query: TransitQuery) -> String {
        switch query.timeMode {
        case .now: return String(localized: "Leaving now")
        case .departAt: return String(localized: "Depart at \(TransitFormat.dayAndTime(query.time))")
        case .arriveBy: return String(localized: "Arrive by \(TransitFormat.dayAndTime(query.time))")
        }
    }

    // MARK: Comparison

    private func results(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if transit.phase == .planning {
                ProgressView("Finding trips").frame(maxWidth: .infinity).padding(8)
            } else {
                if let error = transit.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                }
                if !transit.itineraries.isEmpty {
                    Picker("Sort by", selection: $transit.sort) {
                        ForEach(TransitSort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    let best = TransitComparison.best(transit.itineraries)
                    ScrollView {
                        VStack(spacing: 6) {
                            if transit.canSearchEarlier {
                                pageButton("Earlier trips", symbol: "chevron.up", later: false)
                            }
                            ForEach(transit.shownItineraries) { itinerary in
                                Button { transit.selected = itinerary } label: {
                                    TransitItineraryRow(itinerary: itinerary, wins: best[itinerary.id] ?? [], accent: accent)
                                }
                                .buttonStyle(.plain)
                            }
                            if transit.canSearchLater {
                                pageButton("Later trips", symbol: "chevron.down", later: true)
                            }
                        }
                    }
                    .frame(maxHeight: maxHeight)
                    .scrollBounceBehavior(.basedOnSize)
                }
                if let saved = transit.savedTrip, transit.itineraries.isEmpty, saved.isCurrent() {
                    Button { transit.openSavedTrip() } label: {
                        Label("Open the saved trip to \(saved.destinationName)", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                }
                TransitAttribution()
            }
        }
        .padding(9)
        .transitSurface()
    }

    private func pageButton(_ title: LocalizedStringKey, symbol: String, later: Bool) -> some View {
        Button { Task { await transit.searchMore(later: later) } } label: {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).frame(maxWidth: .infinity).padding(6)
        }
        .buttonStyle(.bordered)
        .disabled(transit.loadingMore)
    }
}

/// One trip in the list: times, the lines in order, changes, walking and the shortest change, and which comparison it wins.
struct TransitItineraryRow: View {
    let itinerary: TransitItinerary
    let wins: Set<TransitSort>
    let accent: Color

    var body: some View {
        let first = itinerary.transitLegs.first
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(TransitFormat.time(itinerary.start, zone: itinerary.legs.first?.from.timeZone ?? "")) – \(TransitFormat.time(itinerary.end, zone: itinerary.legs.last?.to.timeZone ?? ""))")
                    .font(.headline).monospacedDigit()
                Spacer()
                Text(TransitFormat.minutes(itinerary.duration)).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            TransitLineStrip(itinerary: itinerary)
            Text(Self.facts(itinerary)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                ForEach(TransitSort.allCases.filter { wins.contains($0) }, id: \.self) { sort in
                    Text(Self.badge(sort)).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(accent).background(accent.opacity(0.12), in: Capsule())
                }
                if itinerary.isCancelled {
                    Text("Cancelled").font(.caption2.weight(.bold)).foregroundStyle(.red)
                } else if let first, let delay = TransitFormat.delay(first) {
                    Text(delay).font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                } else if itinerary.hasRealtime {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right").font(.caption2).foregroundStyle(.green)
                }
                Spacer(minLength: 0)
                if let first, let platform = TransitFormat.platform(first.from) {
                    Text(platform).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .combine)
    }

    /// "1 change · 14 min walk (1.1 km) · shortest change 5 min"
    static func facts(_ itinerary: TransitItinerary) -> String {
        var parts: [String] = []
        if !itinerary.isWalkOnly {
            parts.append(itinerary.transfers == 0 ? String(localized: "No changes")
                         : itinerary.transfers == 1 ? String(localized: "1 change") : String(localized: "\(itinerary.transfers) changes"))
        }
        let walking = TransitComparison.walkingTime(itinerary)
        if walking > 0 {
            parts.append(String(localized: "\(TransitFormat.minutes(walking)) walk (\(TransitFormat.distance(TransitComparison.walkingDistance(itinerary))))"))
        }
        if let window = TransitComparison.shortestTransfer(itinerary) {
            parts.append(String(localized: "shortest change \(TransitFormat.minutes(window))"))
        }
        return parts.joined(separator: " · ")
    }

    static func badge(_ sort: TransitSort) -> String {
        switch sort {
        case .arrival: return String(localized: "Earliest")
        case .transfers: return String(localized: "Fewest changes")
        case .walking: return String(localized: "Least walking")
        }
    }
}

/// The lines of a trip in order, with a walking figure for long walks.
struct TransitLineStrip: View {
    let itinerary: TransitItinerary

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(Array(itinerary.legs.enumerated()), id: \.offset) { index, leg in
                    if leg.isTransit {
                        if index > 0 { Image(systemName: "chevron.compact.right").font(.caption2).foregroundStyle(.secondary) }
                        TransitLineBadge(leg: leg)
                    } else if leg.duration >= 120 || itinerary.isWalkOnly {
                        if index > 0 { Image(systemName: "chevron.compact.right").font(.caption2).foregroundStyle(.secondary) }
                        Label(TransitFormat.minutes(leg.duration), systemImage: "figure.walk").font(.caption2).labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

struct TransitLineBadge: View {
    let leg: TransitLeg

    var body: some View {
        Label(leg.line.isEmpty ? leg.mode.capitalized : leg.line, systemImage: leg.symbolName)
            .font(.caption.weight(.bold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(Color(hex: leg.routeTextColor) ?? .white)
            .background(Color(hex: leg.routeColor) ?? .gray, in: RoundedRectangle(cornerRadius: 6))
            .strikethrough(leg.isCancelled)
    }
}

/// One trip opened from the list: every leg, and the button that starts it.
struct TransitItineraryDetail: View {
    let itinerary: TransitItinerary
    @ObservedObject var transit: TransitStore
    let accent: Color
    let maxHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { transit.selected = nil } label: { Label("All trips", systemImage: "chevron.backward").font(.subheadline) }
                    .buttonStyle(.plain)
                Spacer()
                Text("\(TransitFormat.time(itinerary.start, zone: itinerary.legs.first?.from.timeZone ?? "")) – \(TransitFormat.time(itinerary.end, zone: itinerary.legs.last?.to.timeZone ?? "")) · \(TransitFormat.minutes(itinerary.duration))")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            Text(TransitItineraryRow.facts(itinerary)).font(.caption).foregroundStyle(.secondary)
            ScrollView { TransitLegList(itinerary: itinerary, current: nil, accent: accent) }
                .frame(maxHeight: maxHeight)
                .scrollBounceBehavior(.basedOnSize)
            Button { transit.start(itinerary) } label: {
                Label("Start navigation", systemImage: "location.north.line.fill").frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .disabled(itinerary.isCancelled)
            TransitAttribution()
        }
        .padding(9)
        .transitSurface()
    }
}

/// The legs of a trip: walks with their distance, time and stairs or lifts, and rides with line, direction, stops, times
/// and platforms. Platforms, stop descriptions and level changes appear only where the data has them.
struct TransitLegList: View {
    let itinerary: TransitItinerary
    /// The leg being followed, highlighted.
    let current: Int?
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(itinerary.legs.enumerated()), id: \.offset) { index, leg in
                Group {
                    if leg.isTransit { ride(leg) } else { walk(leg, index: index) }
                }
                .padding(8)
                .background(index == current ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func walk(_ leg: TransitLeg, index: Int) -> some View {
        let before = itinerary.legs[..<index].last(where: \.isTransit)
        let after = itinerary.legs[(index + 1)...].first(where: \.isTransit)
        let isChange = before != nil && after != nil
        let calls = TransitWalkRoute(leg: leg, target: leg.to.name).map { route in
            zip(route.route.steps, route.symbols).filter { $0.1 == "figure.stairs" || $0.1 == "arrow.up.arrow.down.square" }
        } ?? []
        return VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(isChange ? String(localized: "Change: walk \(TransitFormat.minutes(leg.duration)) · \(TransitFormat.distance(leg.walkedDistance))")
                     : String(localized: "Walk \(TransitFormat.minutes(leg.duration)) · \(TransitFormat.distance(leg.walkedDistance))"))
                    .font(.subheadline.weight(.semibold))
            } icon: { Image(systemName: "figure.walk").foregroundStyle(accent) }
            if isChange, let before, let after {
                // Arriving and leaving platforms, where the timetable gives them.
                let arrive = TransitFormat.platform(before.to), leave = TransitFormat.platform(after.from)
                if arrive != nil || leave != nil {
                    Text(Self.platformChange(arrive: arrive, leave: leave)).font(.caption)
                }
                Text("\(TransitFormat.minutes(after.start.timeIntervalSince(before.end))) to change")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("To \(leg.to.name)").font(.caption).foregroundStyle(.secondary)
            if !leg.to.detail.isEmpty, leg.to.detail != leg.to.name {
                Text(leg.to.detail).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                Label("\(call.0.instruction) after \(TransitFormat.distance(call.0.startProgress))", systemImage: call.1)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    static func platformChange(arrive: String?, leave: String?) -> String {
        switch (arrive, leave) {
        case let (a?, l?): return String(localized: "Arrive at \(a), leave from \(l)")
        case let (a?, nil): return String(localized: "Arrive at \(a)")
        case let (nil, l?): return String(localized: "Leave from \(l)")
        default: return ""
        }
    }

    private func ride(_ leg: TransitLeg) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                TransitLineBadge(leg: leg)
                if !leg.headsign.isEmpty { Text("towards \(leg.headsign)").font(.subheadline).lineLimit(2) }
            }
            if leg.isCancelled { Label("Cancelled", systemImage: "xmark.octagon").font(.caption.weight(.bold)).foregroundStyle(.red) }
            stopLine(leg.from, time: leg.start, scheduled: leg.scheduledStart, realTime: leg.realTime, verb: String(localized: "Board"))
            if !leg.intermediateStops.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(leg.intermediateStops.enumerated()), id: \.offset) { _, stop in
                            HStack {
                                Text(TransitFormat.time(stop.arrival ?? stop.departure, zone: stop.timeZone)).monospacedDigit().frame(width: 52, alignment: .leading)
                                Text(stop.name).strikethrough(stop.cancelled)
                            }
                            .font(.caption2)
                        }
                    }
                } label: {
                    Text(leg.intermediateStops.count == 1 ? String(localized: "1 stop on the way") : String(localized: "\(leg.intermediateStops.count) stops on the way"))
                        .font(.caption)
                }
            }
            stopLine(leg.to, time: leg.end, scheduled: leg.scheduledEnd, realTime: leg.realTime, verb: String(localized: "Get off"))
            if !leg.agency.isEmpty { Text(leg.agency).font(.caption2).foregroundStyle(.secondary) }
            ForEach(leg.alerts, id: \.self) { alert in
                Label(alert, systemImage: "exclamationmark.bubble").font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private func stopLine(_ stop: TransitStop, time: Date, scheduled: Date, realTime: Bool, verb: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TransitFormat.time(time, zone: stop.timeZone)).font(.subheadline.weight(.semibold)).monospacedDigit()
                if realTime, abs(time.timeIntervalSince(scheduled)) >= 60 {
                    Text(TransitFormat.time(scheduled, zone: stop.timeZone)).font(.caption).strikethrough().foregroundStyle(.secondary)
                }
                Text("\(verb): \(stop.name)").font(.subheadline).lineLimit(2)
            }
            HStack(spacing: 6) {
                if let platform = TransitFormat.platform(stop) {
                    Text(platform).font(.caption.weight(.semibold)).foregroundStyle(stop.trackChanged ? .orange : .primary)
                    if stop.trackChanged { Text("was \(stop.scheduledTrack)").font(.caption2).foregroundStyle(.orange) }
                }
                if !stop.detail.isEmpty, stop.detail != stop.name {
                    Text(stop.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

/// The top of the screen while following a trip: the next walking turn, or the ride with its stops to go.
struct TransitGuidanceHeader: View {
    @ObservedObject var transit: TransitStore
    @ObservedObject private var network = NetworkMonitor.shared
    let accent: Color

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if transit.arrived {
                    HStack {
                        Label("You have arrived", systemImage: "flag.checkered").font(.headline)
                        Spacer()
                        Button("Done") { transit.close() }.buttonStyle(.borderedProminent)
                    }
                } else if let leg = transit.currentLeg {
                    if leg.isTransit { rideCard(leg) } else { walkCard(leg) }
                }
            }
            .padding(11)
            .frame(maxWidth: 490)
            .transitSurface()
            if let notice = transit.stopNotice {
                Label(notice, systemImage: "bell.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(10).background(.orange.gradient, in: Capsule())
            }
            if let problem = transit.problem { problemCard(problem) }
            if transit.fromSavedCopy, let saved = transit.savedAt {
                Label(network.isOnline ? String(localized: "Saved trip: scheduled times as of \(TransitFormat.time(saved))")
                      : String(localized: "No signal: saved trip with scheduled times as of \(TransitFormat.time(saved))"),
                      systemImage: "arrow.down.circle")
                    .font(.caption).padding(8).transitSurface(radius: 13)
            }
        }
    }

    private func walkCard(_ leg: TransitLeg) -> some View {
        let target = transit.trip.map { TransitStore.walkTarget($0, legIndex: transit.legIndex) } ?? leg.to.name
        let update = transit.walkUpdate
        let steps = transit.walk?.route.steps ?? []
        let index = update?.upcomingStepIndex ?? (steps.isEmpty ? nil : 0)
        return VStack(alignment: .leading, spacing: 6) {
            if let index, steps.indices.contains(index) {
                HStack(spacing: 13) {
                    Image(systemName: transit.walk?.symbols[safe: index] ?? "figure.walk")
                        .font(.system(size: 30, weight: .bold)).frame(width: 44).foregroundStyle(accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TransitFormat.distance(update?.distanceToManeuver ?? steps[index].startProgress))
                            .font(.title2.weight(.bold)).monospacedDigit()
                        Text(steps[index].instruction).font(.headline).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
            }
            Label("Walk to \(target)", systemImage: "figure.walk").font(.subheadline)
            if let update {
                Text("\(TransitFormat.minutes(update.remainingTime)) · \(TransitFormat.distance(update.remainingDistance))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let next = transit.trip?.legs[(transit.legIndex + 1)...].first(where: \.isTransit) {
                Text(String(localized: "Then \(next.line) at \(TransitFormat.time(next.start, zone: next.from.timeZone))") + (TransitFormat.delay(next).map { " (\($0))" } ?? ""))
                    .font(.caption.weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func rideCard(_ leg: TransitLeg) -> some View {
        let ride = transit.ride
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TransitLineBadge(leg: leg)
                if !leg.headsign.isEmpty { Text("towards \(leg.headsign)").font(.headline).lineLimit(2) }
                Spacer(minLength: 0)
            }
            if ride?.departed != true {
                let minutes = Int((leg.start.timeIntervalSinceNow / 60).rounded(.down))
                Text(minutes > 0 ? String(localized: "Board at \(leg.from.name) · leaves in \(minutes) min")
                     : String(localized: "Board at \(leg.from.name) · leaving now"))
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    if let platform = TransitFormat.platform(leg.from) { Text(platform).font(.subheadline.weight(.bold)) }
                    Text(TransitFormat.time(leg.start, zone: leg.from.timeZone)).monospacedDigit()
                    if let delay = TransitFormat.delay(leg) { Text(delay).foregroundStyle(.orange) }
                }
                .font(.subheadline)
            } else if let ride {
                Text(ride.stopsRemaining == 1 ? String(localized: "Next stop is yours") : String(localized: "\(ride.stopsRemaining) stops to go"))
                    .font(.title3.weight(.bold))
                if let next = ride.nextStop, ride.stopsRemaining > 1 {
                    Text("Next: \(next.name)").font(.subheadline)
                }
            }
            HStack {
                Text("Get off at \(leg.to.name)").font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text(TransitFormat.time(leg.to.arrival ?? leg.end, zone: leg.to.timeZone)).font(.subheadline).monospacedDigit()
            }
            if let platform = TransitFormat.platform(leg.to) { Text("Arrives at \(platform)").font(.caption).foregroundStyle(.secondary) }
            if leg.isCancelled { Label("Cancelled", systemImage: "xmark.octagon").font(.caption.weight(.bold)).foregroundStyle(.red) }
        }
        .accessibilityElement(children: .combine)
    }

    private func problemCard(_ problem: TransitProblem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(problem.message, systemImage: "exclamationmark.triangle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            if transit.findingReplacement {
                ProgressView("Finding another trip from here").font(.caption)
            } else if let next = transit.replacement {
                let first = next.transitLegs.first
                Text(first.map { String(localized: "Next: \($0.line) at \(TransitFormat.time($0.start, zone: $0.from.timeZone)) from \($0.from.name)") }
                     ?? String(localized: "Walk from here"))
                    .font(.subheadline)
                Text("Arrive \(TransitFormat.time(next.end, zone: next.legs.last?.to.timeZone ?? "")) · \(TransitItineraryRow.facts(next))")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Take this") { transit.acceptReplacement() }.buttonStyle(.borderedProminent)
                    Button("Keep my trip") { transit.keepTrip() }.buttonStyle(.bordered)
                }
            } else {
                HStack {
                    Button("Find another trip") { transit.findReplacement() }.buttonStyle(.borderedProminent)
                    Button("Keep my trip") { transit.keepTrip() }.buttonStyle(.bordered)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: 490, alignment: .leading)
        .transitSurface()
    }
}

/// The bottom of the screen while following a trip: which leg, the arrival time, the trip's details and End.
struct TransitTripBar: View {
    @ObservedObject var transit: TransitStore
    @Binding var showsDetails: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 9) {
                Button { transit.moveLeg(by: -1) } label: { Image(systemName: "chevron.backward").frame(width: 36, height: 36) }
                    .disabled(transit.legIndex == 0)
                    .accessibilityLabel("Previous leg")
                VStack(spacing: 2) {
                    Text("Leg \(transit.legIndex + 1) of \(transit.trip?.legs.count ?? 0)").font(.subheadline.weight(.bold)).monospacedDigit()
                    if let trip = transit.trip {
                        Text("Arrive \(TransitFormat.time(trip.end, zone: trip.legs.last?.to.timeZone ?? ""))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                Button { transit.moveLeg(by: 1) } label: { Image(systemName: "chevron.forward").frame(width: 36, height: 36) }
                    .disabled(transit.legIndex + 1 >= (transit.trip?.legs.count ?? 0))
                    .accessibilityLabel("Next leg")
                Button { showsDetails = true } label: { Image(systemName: "list.bullet").frame(width: 36, height: 36) }
                    .accessibilityLabel("Trip details")
                Button(role: .destructive) { transit.close() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                        .foregroundStyle(.red).background(.red.opacity(0.11), in: Circle())
                }
                .accessibilityLabel("End trip")
            }
            .buttonStyle(.plain)
            TransitAttribution()
        }
        .padding(8)
        .transitSurface()
    }
}

/// The attribution Transitous asks for: a visible link to its data sources, and OpenStreetMap's copyright.
struct TransitAttribution: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Trips by")
            Link("Transitous", destination: TransitousClient.homeURL)
            Text("·")
            Link("Data sources", destination: TransitousClient.sourcesURL)
            Text("·")
            Link("© OpenStreetMap", destination: TransitousClient.openStreetMapCopyright)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity)
    }
}

/// The trip on Apple Maps: walks dotted, rides in their line colour, with the boarding and alighting stops.
struct TransitMap: View {
    let itinerary: TransitItinerary?
    let currentLeg: Int?
    @Binding var camera: MapCameraPosition

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()
            if let itinerary {
                ForEach(Array(itinerary.legs.enumerated()), id: \.offset) { index, leg in
                    let faded = currentLeg.map { index < $0 } ?? false
                    if leg.isTransit {
                        MapPolyline(coordinates: leg.coordinates.count > 1 ? leg.coordinates : [leg.from.coordinate, leg.to.coordinate])
                            .stroke((Color(hex: leg.routeColor) ?? .cyan).opacity(faded ? 0.35 : 1), lineWidth: 6)
                        Marker(leg.from.name, systemImage: leg.symbolName, coordinate: leg.from.coordinate)
                            .tint(Color(hex: leg.routeColor) ?? .cyan)
                    } else {
                        MapPolyline(coordinates: leg.coordinates.count > 1 ? leg.coordinates : [leg.from.coordinate, leg.to.coordinate])
                            .stroke(.blue.opacity(faded ? 0.35 : 0.9), style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [1, 8]))
                    }
                }
                if let last = itinerary.legs.last {
                    Marker(last.to.name, systemImage: "flag.checkered", coordinate: last.to.coordinate).tint(.red)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls { MapCompass() }
    }
}

extension Color {
    /// A colour from the service's "rrggbb" route colour. Nil when there is none.
    init?(hex: String) {
        let text = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private extension View {
    /// The same floating card look as the driving screen's panels.
    func transitSurface(radius: CGFloat = 19) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(.primary.opacity(0.08), lineWidth: 1).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 3)
    }
}
