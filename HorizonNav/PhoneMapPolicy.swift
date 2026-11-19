import Foundation

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

enum PhoneMapPerspective: String, CaseIterable {
    case automatic, flat, perspective

    var label: String {
        switch self {
        case .automatic: return "Auto"
        case .flat: return "2D"
        case .perspective: return "3D"
        }
    }

    var next: Self {
        switch self {
        case .automatic: return .flat
        case .flat: return .perspective
        case .perspective: return .automatic
        }
    }
}

enum PhoneCameraPolicy {
    struct Framing: Equatable {
        var zoom: Double
        var pitch: Double
    }

    static func framing(mode: PhoneMapPerspective, speed: Double, fastRoad: Bool, maneuverDistance: Double?) -> Framing {
        let maneuverRange = max(90, speed * 8)
        let junction = maneuverDistance.map { min(max(1 - $0 / maneuverRange, 0), 1) } ?? 0
        let speedFactor = min(max(speed / 35, 0), 1)
        let zoom = 17.4 - 2.35 * speedFactor - (fastRoad ? 0.2 : 0) + junction * 0.65
        let pitch: Double
        switch mode {
        case .flat: pitch = 0
        case .perspective: pitch = 59 - junction * 12
        case .automatic: pitch = 45 + 13 * speedFactor - junction * 20
        }
        return Framing(zoom: zoom, pitch: pitch)
    }

    static func easedBearing(from previous: Double, to bearing: Double, amount: Double) -> Double {
        let delta = NavigationPolicy.angleDifference(from: previous, to: bearing)
        return (previous + delta * amount + 360).truncatingRemainder(dividingBy: 360)
    }
}
