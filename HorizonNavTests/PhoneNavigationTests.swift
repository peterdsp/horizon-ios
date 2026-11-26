import Foundation
import Testing
@testable import HorizonNav

struct PhoneNavigationTests {
    @Test func mapSelectionKeepsOfflineMapAvailable() {
        #expect(PhoneMapSource.resolve(choice: "mapbox", online: true, mapboxAvailable: true) == .mapbox)
        #expect(PhoneMapSource.resolve(choice: "mapbox", online: true, mapboxAvailable: false) == .openstreetmap)
        #expect(PhoneMapSource.resolve(choice: "apple", online: false, mapboxAvailable: true) == .openstreetmap)
        #expect(PhoneMapSource.resolve(choice: "apple", online: true, mapboxAvailable: false) == .apple)
        #expect(PhoneMapSource.resolve(choice: "openstreetmap", online: true, mapboxAvailable: true) == .openstreetmap)
    }

    @Test func vehicleHeadingEasesTheShortWayRound() {
        #expect(PhoneCameraPolicy.easedBearing(from: 350, to: 10, amount: 0.5) == 0)
        #expect(PhoneCameraPolicy.easedBearing(from: 10, to: 350, amount: 0.5) == 0)
        #expect(PhoneCameraPolicy.easedBearing(from: 90, to: 90, amount: 0.55) == 90)
    }
}
