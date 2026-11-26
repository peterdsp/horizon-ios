import CoreLocation
import Foundation

/// Where the car is drawn on the Mapbox map: the route position while the fix agrees with the route, with a steadied heading.
struct VehiclePose {
    let coordinate: CLLocationCoordinate2D
    let bearing: Double
    let location: CLLocation
}
