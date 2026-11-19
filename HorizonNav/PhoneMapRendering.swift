import CoreLocation
import SwiftUI
import UIKit

struct PhoneMapTracking {
    var pose: VehiclePose?
    var follows: Bool
    var navigating: Bool
    var framing: PhoneCameraPolicy.Framing
    var vehicleScale: Double

    var bearing: Double { navigating ? (pose?.bearing ?? 0) : 0 }
    var pitch: Double { navigating ? framing.pitch : 0 }
    var zoom: Double { navigating ? framing.zoom : 14.5 }

    static let previewInsets = UIEdgeInsets(top: 110, left: 42, bottom: 250, right: 42)

    @MainActor
    static func framing(store: NavigationStore, perspective: PhoneMapPerspective) -> PhoneCameraPolicy.Framing {
        let update = store.guidance
        let step = update?.upcomingStepIndex.flatMap { index in store.selectedRoute?.steps[safe: index] }
        let fast = (store.speedLimit ?? 0) >= 22.2 || !(step?.exitNumber ?? "").isEmpty
        let distance = step.flatMap { step in
            (step.turnAngle.map { abs($0) >= 35 } == true || step.roundaboutExit > 0 || !step.exitNumber.isEmpty)
                ? update?.distanceToManeuver : nil
        }
        return PhoneCameraPolicy.framing(mode: perspective, speed: store.currentSpeed, fastRoad: fast, maneuverDistance: distance)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

enum PhoneMapArtwork {
    static func vehicle(scale: Double) -> UIImage {
        let size = 44 * CGFloat(min(max(scale, 0.65), 1.55))
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            let cg = context.cgContext
            cg.scaleBy(x: size / 44, y: size / 44)
            UIColor.black.withAlphaComponent(0.22).setFill()
            UIBezierPath(ovalIn: CGRect(x: 11, y: 7, width: 22, height: 32)).fill()
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 13, y: 5, width: 18, height: 32), cornerRadius: 6).fill()
            UIColor(red: 0.04, green: 0.40, blue: 0.84, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 15, y: 7, width: 14, height: 28), cornerRadius: 5).fill()
            UIColor(red: 0.05, green: 0.15, blue: 0.27, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 17, y: 14, width: 10, height: 15), cornerRadius: 3).fill()
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 16, y: 9, width: 3, height: 2), cornerRadius: 1).fill()
            UIBezierPath(roundedRect: CGRect(x: 25, y: 9, width: 3, height: 2), cornerRadius: 1).fill()
            UIColor.systemRed.setFill()
            UIBezierPath(roundedRect: CGRect(x: 16, y: 31, width: 3, height: 2), cornerRadius: 1).fill()
            UIBezierPath(roundedRect: CGRect(x: 25, y: 31, width: 3, height: 2), cornerRadius: 1).fill()
        }
    }

    static func event(_ kind: RoadEvent.Kind) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28)).image { _ in
            UIColor(red: 0.10, green: 0.17, blue: 0.25, alpha: 1).setFill()
            let outline = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 26, height: 26))
            outline.fill()
            UIColor.white.setStroke()
            outline.lineWidth = 1.5
            outline.stroke()
            let icon = UIImage(systemName: kind.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))?
                .withTintColor(kind == .stop ? .systemRed : .white, renderingMode: .alwaysOriginal)
            if let icon { icon.draw(at: CGPoint(x: (28 - icon.size.width) / 2, y: (28 - icon.size.height) / 2)) }
        }
    }
}

extension RoadEvent {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon) }
}
