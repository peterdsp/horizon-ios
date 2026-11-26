import Foundation

/// The phone's map: the one chosen in Settings, with OpenStreetMap whenever there is no signal (only it draws saved areas)
/// and when the Mapbox map has no token or cannot load.
enum PhoneMapSource: String {
    case apple, openstreetmap, mapbox

    static func resolve(choice: String, online: Bool, mapboxAvailable: Bool) -> Self {
        guard online else { return .openstreetmap }
        switch Self(rawValue: choice) {
        case .mapbox: return mapboxAvailable ? .mapbox : .openstreetmap
        case .openstreetmap: return .openstreetmap
        default: return .apple
        }
    }
}

enum PhoneCameraPolicy {
    /// Turns part of the way from one heading to another, the short way round, so the car does not jitter with the course.
    static func easedBearing(from previous: Double, to bearing: Double, amount: Double) -> Double {
        let delta = NavigationPolicy.angleDifference(from: previous, to: bearing)
        return (previous + delta * amount + 360).truncatingRemainder(dividingBy: 360)
    }
}
