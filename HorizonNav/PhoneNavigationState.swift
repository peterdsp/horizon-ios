import Combine
import CoreLocation
import Foundation

struct VehiclePose {
    let coordinate: CLLocationCoordinate2D
    let bearing: Double
    let location: CLLocation
}

@MainActor
final class PhoneRoadEvents: ObservableObject {
    enum State: Equatable {
        case awaitingFix, loading, ready, unavailable
    }

    @Published private(set) var state = State.awaitingFix
    @Published private(set) var upcoming: [RoadEvent] = []
    @Published private(set) var progress: Double = 0

    private let service: RoadEventService
    private var task: Task<Void, Never>?
    private var routeID: UUID?
    private var routeGeometry: RoadCorridor?
    private var window: Int?
    private var loaded: [RoadEvent] = []
    private var loadedAt: Date?
    private var retryAfter = Date.distantPast
    private var validPosition = false
    private var wasOnline: Bool?
    private var generation = UUID()

    init(service: RoadEventService = .shared) {
        self.service = service
    }

    func reset() {
        task?.cancel()
        task = nil
        generation = UUID()
        routeID = nil
        routeGeometry = nil
        window = nil
        loaded = []
        loadedAt = nil
        upcoming = []
        progress = 0
        validPosition = false
        retryAfter = .distantPast
        wasOnline = nil
        state = .awaitingFix
    }

    func update(route: RouteOption, progress: Double, validPosition: Bool, online: Bool) {
        if routeID != route.id {
            reset()
            routeID = route.id
            routeGeometry = RoadCorridor(points: route.coordinates.map { RoadPoint(lat: $0.latitude, lon: $0.longitude) },
                                         progress: route.cumulative)
        }
        self.validPosition = validPosition
        guard validPosition else {
            if !upcoming.isEmpty { upcoming = [] }
            return
        }
        let advanced = max(self.progress, progress)
        if advanced != self.progress { self.progress = advanced }
        let expired = loadedAt.map { Date().timeIntervalSince($0) >= 3_600 } ?? false
        if expired { loaded = []; loadedAt = nil }
        refreshUpcoming()
        guard let routeGeometry, let length = routeGeometry.progress.last, length > 1 else { state = .unavailable; return }

        // Overlap windows so entering a new one never discards nearby valid events while the next request runs.
        let next = Int(self.progress / 2_500)
        let networkReturned = wasOnline == false && online
        wasOnline = online
        if window != next || expired || (state == .unavailable && (networkReturned || Date() >= retryAfter)) {
            window = next
            task?.cancel()
            let start = max(0, Double(next) * 2_500 - 100)
            let end = min(length, Double(next) * 2_500 + 4_750)
            guard start < end else { return }
            let corridor = routeGeometry.slice(from: start, to: end)
            let generation = UUID()
            self.generation = generation
            if upcoming.isEmpty { state = .loading }
            task = Task { [weak self, service] in
                do {
                    let events = try await service.events(along: corridor, online: online)
                    guard !Task.isCancelled, let self, self.generation == generation else { return }
                    self.loaded = events
                    self.loadedAt = Date()
                    self.state = .ready
                    self.refreshUpcoming()
                } catch {
                    guard !Task.isCancelled, let self, self.generation == generation else { return }
                    let rateLimited = (error as? RoadEventService.Failure) == .rateLimited
                    self.retryAfter = Date().addingTimeInterval(online && !rateLimited ? 90 : 300)
                    self.state = .unavailable
                    self.refreshUpcoming()
                }
            }
        }
    }

    private func refreshUpcoming() {
        let events = validPosition ? RoadEvent.upcoming(loaded, progress: progress) : []
        if events != upcoming { upcoming = events }
    }
}
