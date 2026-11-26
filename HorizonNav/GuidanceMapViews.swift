import MapKit
import SwiftUI

/// The guiding map's marks on the Apple map: road features, the lane sign, the destination and the preview car.
struct GuidanceMarks: MapContent {
    var marks: [MapMark]

    var body: some MapContent {
        ForEach(marks) { mark in
            Annotation(mark.label, coordinate: mark.coordinate, anchor: mark.anchorsBottom ? .bottom : .center) {
                Image(uiImage: mark.image)
                    .accessibilityLabel(mark.label)
            }
            .annotationTitles(.hidden)
        }
    }
}

extension MapCamera {
    /// The Apple map camera for a guiding camera target, in a map this tall.
    init(_ target: NavigationCameraTarget, viewHeight: Double) {
        self.init(centerCoordinate: target.center,
                  distance: NavigationCamera.appleDistance(zoom: target.zoom, latitude: target.center.latitude, viewHeight: viewHeight),
                  heading: target.heading, pitch: target.pitch)
    }
}

extension MapCameraPosition {
    /// The route overview on the Apple map: the rest of the route with a margin round it.
    static func overview(_ coordinates: [CLLocationCoordinate2D]) -> MapCameraPosition {
        let rect = MKPolyline(coordinates: coordinates, count: coordinates.count).boundingMapRect
        let margin = max(rect.width, rect.height) * 0.15 + 400
        return .rect(rect.insetBy(dx: -margin, dy: -margin * 1.6))
    }
}

/// The view switch and the overview button on the guiding map.
struct GuidanceMapButtons: View {
    @ObservedObject var model: GuidanceMapModel

    var body: some View {
        VStack(spacing: 10) {
            Button {
                model.cycleViewMode()
            } label: {
                Image(systemName: model.viewMode.symbolName)
                    .font(.title3)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .guidanceGlassControl()
            .accessibilityLabel(model.viewMode.title)
            .accessibilityHint(Text("Switches to \(model.viewMode.next.title)"))

            Button {
                model.toggleOverview()
            } label: {
                Image(systemName: model.showsOverview ? "location.fill" : "point.bottomleft.forward.to.point.topright.scurvepath")
                    .font(.title3)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .guidanceGlassControl()
            .accessibilityLabel(model.showsOverview ? Text("Back to following") : Text("Route overview"))
        }
    }
}

/// What is left of the trip, shown with the route overview: distance, time, arrival and the traffic delay the route reported.
struct RouteOverviewCard: View {
    var route: RouteOption
    var update: GuidanceUpdate?
    var destinationName: String

    var body: some View {
        let remainingTime = update?.remainingTime ?? route.expectedTravelTime
        let remainingDistance = update?.remainingDistance ?? route.distance
        VStack(alignment: .leading, spacing: 4) {
            Label(destinationName, systemImage: "mappin.circle.fill")
                .font(.headline)
                .lineLimit(1)
            Text("\(Measurement(value: remainingDistance, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))) · \(Duration.seconds(remainingTime).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) · arrive \(Date().addingTimeInterval(remainingTime).formatted(date: .omitted, time: .shortened))")
                .font(.subheadline)
            if route.trafficDelay >= 60 {
                Label("Traffic delay on this route: \(Duration.seconds(route.trafficDelay).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))",
                      systemImage: "car.2.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial)
    }
}

/// The manoeuvres of the selected route, to pick one and watch a short drive through it before setting off.
struct JunctionPreviewList: View {
    var route: RouteOption
    var onPick: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(JunctionPreview.candidates(in: route), id: \.self) { index in
                let step = route.steps[index]
                Button {
                    dismiss()
                    onPick(index)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: step.symbolName).font(.title2).frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.instruction).font(.headline).lineLimit(2)
                            Text("After \(Measurement(value: step.startProgress, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if JunctionPreview.isComplex(step, in: route) {
                            Image(systemName: "road.lanes").foregroundStyle(.cyan).accessibilityLabel("Complex junction")
                        }
                        Image(systemName: "play.circle.fill").foregroundStyle(.cyan)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Preview a junction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }
}

/// The turn card during a junction preview: the instruction, the distance to it and the lanes, as on the drive.
struct JunctionPreviewBanner: View {
    var preview: JunctionPreview
    var frame: JunctionPreview.Frame
    var onStop: () -> Void

    var body: some View {
        let route = preview.route
        let index = frame.update.upcomingStepIndex ?? preview.stepIndex
        let step = route.steps[min(index, route.steps.count - 1)]
        HStack(spacing: 14) {
            Image(systemName: step.symbolName).font(.largeTitle.weight(.semibold))
            VStack(alignment: .leading) {
                Text(Measurement(value: frame.update.distanceToManeuver, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
                    .font(.title2.weight(.bold))
                Text(step.instruction).font(.headline).lineLimit(2)
                if let lanes = route.laneSection(forStep: index, progress: frame.progress,
                                                 fastRoad: NavigationStore.isFastRoad(step: step, route: route, progress: frame.progress)),
                   let image = LaneImage.image(LanePolicy.marked(lanes, maneuver: step.maneuver)) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 36)
                        .padding(4)
                        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel(LanePolicy.advice(lanes, maneuver: step.maneuver) ?? "")
                }
                Text("Preview").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onStop) {
                Image(systemName: "xmark.circle.fill").font(.title)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop preview")
        }
        .padding()
        .background(.regularMaterial)
    }
}

private extension View {
    /// The same Liquid Glass as the map's other floating controls.
    @ViewBuilder
    func guidanceGlassControl() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .circle)
        } else {
            background(.ultraThinMaterial, in: .circle)
        }
    }
}
