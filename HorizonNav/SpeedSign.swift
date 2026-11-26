import SwiftUI
import UIKit

/// The posted limit and the car's speed, in the units of the region (Android's speed sign and speedometer).
enum SpeedDisplay {
    static var unit: UnitSpeed { AppLocale.usesImperialDistances ? .milesPerHour : .kilometersPerHour }

    static func value(_ metersPerSecond: Double) -> Int {
        Int(Measurement(value: metersPerSecond, unit: UnitSpeed.metersPerSecond).converted(to: unit).value.rounded())
    }

    static var unitLabel: String { AppLocale.usesImperialDistances ? String(localized: "mph") : String(localized: "km/h") }

    /// Over the limit by more than a whisker (1 km/h or 1 mph), when the speedometer turns red.
    static func isOver(speed: Double, limit: Double?) -> Bool {
        guard let limit else { return false }
        return value(speed) > value(limit)
    }

    /// "50 in 250 m", the lower limit ahead and how far it is.
    static func nextText(_ drop: SpeedLimitLookahead.Drop) -> String {
        let distance = Measurement(value: drop.distance, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
        return String(localized: "\(value(drop.metersPerSecond)) in \(distance)")
    }
}

/// The speed sign drawn on the car map: a red-ringed limit sign with the current speed under it.
final class SpeedSignView: UIView {
    private let ring = UIView()
    private let limitLabel = UILabel()
    private let speedLabel = UILabel()
    private let nextLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        ring.backgroundColor = .white
        ring.layer.borderColor = UIColor.systemRed.cgColor
        ring.layer.borderWidth = 5
        limitLabel.font = .systemFont(ofSize: 20, weight: .bold)
        limitLabel.textColor = .black
        limitLabel.textAlignment = .center
        limitLabel.adjustsFontSizeToFitWidth = true
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        speedLabel.textAlignment = .center
        speedLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        speedLabel.textColor = .white
        speedLabel.layer.cornerRadius = 8
        speedLabel.clipsToBounds = true
        nextLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        nextLabel.textAlignment = .center
        nextLabel.textColor = .black
        nextLabel.backgroundColor = .white
        nextLabel.layer.borderColor = UIColor.systemRed.cgColor
        nextLabel.layer.borderWidth = 2
        nextLabel.layer.cornerRadius = 8
        nextLabel.clipsToBounds = true
        nextLabel.adjustsFontSizeToFitWidth = true
        ring.addSubview(limitLabel)
        addSubview(ring)
        addSubview(speedLabel)
        addSubview(nextLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, 52)
        ring.frame = CGRect(x: (bounds.width - side) / 2, y: 0, width: side, height: side)
        ring.layer.cornerRadius = side / 2
        limitLabel.frame = ring.bounds.insetBy(dx: 8, dy: 8)
        speedLabel.frame = CGRect(x: 0, y: side + 6, width: bounds.width, height: 24)
        nextLabel.frame = CGRect(x: 0, y: side + 34, width: bounds.width, height: 20)
    }

    /// The current limit stays on the sign until the change point; the lower one ahead shows under the speed.
    func update(limit: Double?, speed: Double, next: SpeedLimitLookahead.Drop? = nil) {
        nextLabel.isHidden = next == nil
        nextLabel.text = next.map(SpeedDisplay.nextText)
        ring.isHidden = limit == nil
        limitLabel.text = limit.map { "\(SpeedDisplay.value($0))" }
        speedLabel.text = "\(SpeedDisplay.value(speed)) \(SpeedDisplay.unitLabel)"
        speedLabel.backgroundColor = SpeedDisplay.isOver(speed: speed, limit: limit) ? .systemRed : UIColor.black.withAlphaComponent(0.6)
    }
}

/// The same sign on the phone.
struct SpeedSignBadge: View {
    var limit: Double?
    var speed: Double
    var next: SpeedLimitLookahead.Drop?

    var body: some View {
        VStack(spacing: 6) {
            if let limit {
                Text("\(SpeedDisplay.value(limit))")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(.white))
                    .overlay(Circle().stroke(.red, lineWidth: 5))
                    .accessibilityLabel("Speed limit \(SpeedDisplay.value(limit)) \(SpeedDisplay.unitLabel)")
            }
            Text("\(SpeedDisplay.value(speed)) \(SpeedDisplay.unitLabel)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(SpeedDisplay.isOver(speed: speed, limit: limit) ? Color.red : Color.black.opacity(0.6)))
            if let next {
                Text(SpeedDisplay.nextText(next))
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.white))
                    .overlay(Capsule().stroke(.red, lineWidth: 2))
                    .accessibilityLabel("Speed limit \(SpeedDisplay.value(next.metersPerSecond)) \(SpeedDisplay.unitLabel) ahead")
            }
        }
    }
}
