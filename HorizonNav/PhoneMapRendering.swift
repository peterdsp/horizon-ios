import UIKit

enum PhoneMapArtwork {
    /// The flat car for the Mapbox map's heading-up and north-up views, drawn so it needs no image asset.
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
}
