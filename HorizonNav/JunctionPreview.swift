import Combine
import CoreLocation
import Foundation

/// A short drive through one manoeuvre of a previewed route: the car runs along the route from a little before the junction to
/// a little after it, at the road's speed played twice as fast, with the instruction and lanes it would get on the day.
struct JunctionPreview {
    struct Frame: Equatable {
        var progress: CLLocationDistance
        var coordinate: CLLocationCoordinate2D
        var bearing: Double
        var update: GuidanceUpdate

        static func == (a: Frame, b: Frame) -> Bool {
            a.progress == b.progress && a.update == b.update
        }
    }

    let route: RouteOption
    let stepIndex: Int
    let start: CLLocationDistance
    let end: CLLocationDistance
    /// The car's speed in metres per second: the posted limit before the junction, or a town or fast road speed.
    let speed: Double

    static let playbackRate = 2.0
    static let leadOut: CLLocationDistance = 120

    init?(route: RouteOption, stepIndex: Int) {
        guard route.steps.indices.contains(stepIndex), route.coordinates.count > 1 else { return nil }
        let step = route.steps[stepIndex]
        let at = step.startProgress
        let fast = NavigationStore.isFastRoad(step: step, route: route, progress: max(at - 100, 0))
        let limit = route.speedLimit(at: max(at - 100, 0))
        speed = min(max(limit ?? (fast ? 25 : 13.9), 8), 33)
        // Long enough to hear the lane call and see the lanes before the junction: 12 seconds of driving, at least 250 m.
        start = max(at - max(250, speed * 12), 0)
        end = min(at + Self.leadOut, route.length)
        guard end - start > 20 else { return nil }
        self.route = route
        self.stepIndex = stepIndex
    }

    var duration: TimeInterval { (end - start) / (speed * Self.playbackRate) }

    func frame(at elapsed: TimeInterval) -> Frame? {
        let progress = min(start + max(elapsed, 0) * speed * Self.playbackRate, end)
        guard let point = route.point(atProgress: progress) else { return nil }
        let upcoming = route.steps.firstIndex { $0.startProgress > progress + RouteGuidance.maneuverPassedTolerance || $0.isArrival }
        let toManeuver = upcoming.map { max(route.steps[$0].startProgress - progress, 0) } ?? 0
        let remaining = max(route.length - progress, 0)
        let update = GuidanceUpdate(status: .onRoute, upcomingStepIndex: upcoming, distanceToManeuver: toManeuver,
                                    remainingDistance: remaining,
                                    remainingTime: route.length > 0 ? route.expectedTravelTime * remaining / route.length : 0,
                                    distanceFromRoute: 0, progress: progress)
        return Frame(progress: progress, coordinate: point.coordinate, bearing: point.bearing, update: update)
    }

    /// Junctions worth a look before setting off (Android's junction close-up): forks, keeps, exits, slip roads, numbered exits and
    /// roundabouts, and any manoeuvre with lanes to pick.
    static func isComplex(_ step: RouteStep, in route: RouteOption) -> Bool {
        let m = step.maneuver.rawValue
        let lanes = route.laneSections.contains { $0.end > step.startProgress - 60 && $0.end < step.startProgress + 200 && $0.lanes.count >= 2 }
        return step.maneuver.isRoundabout || m.hasPrefix("KEEP") || m.contains("EXIT") || m.contains("RAMP") ||
            !step.exitNumber.isEmpty || lanes
    }

    /// Every manoeuvre that can be previewed: all but the arrival.
    static func candidates(in route: RouteOption) -> [Int] {
        route.steps.indices.filter { !route.steps[$0].isArrival && route.steps[$0].maneuver != .depart }
    }
}

/// Plays one junction preview at a time on the phone map.
@MainActor
final class JunctionPreviewPlayer: ObservableObject {
    @Published private(set) var preview: JunctionPreview?
    @Published private(set) var frame: JunctionPreview.Frame?
    private var task: Task<Void, Never>?

    var isPlaying: Bool { preview != nil }

    func play(_ preview: JunctionPreview) {
        stop()
        self.preview = preview
        frame = preview.frame(at: 0)
        task = Task { [weak self] in
            // A moment on the first frame for the camera to fly there, then the drive, then a moment past the junction.
            try? await Task.sleep(for: .seconds(1.2))
            let start = Date()
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                self?.frame = preview.frame(at: elapsed)
                if elapsed >= preview.duration { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        preview = nil
        frame = nil
    }
}
