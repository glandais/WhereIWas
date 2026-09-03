import CoreLocation
import Foundation
import UIKit

// Pure bridging between the framework-free Domain types and CoreLocation /
// UIKit. Nothing here has state; every function is a one-liner mapping so
// the engine stays readable and the Domain never imports CoreLocation.

extension AccuracyLevel {
    /// The `kCLLocationAccuracy…` constant for this level.
    var clAccuracy: CLLocationAccuracy {
        switch self {
        case .bestForNavigation: return kCLLocationAccuracyBestForNavigation
        case .best: return kCLLocationAccuracyBest
        case .tenMeters: return kCLLocationAccuracyNearestTenMeters
        case .hundredMeters: return kCLLocationAccuracyHundredMeters
        case .kilometer: return kCLLocationAccuracyKilometer
        case .threeKilometers: return kCLLocationAccuracyThreeKilometers
        }
    }
}

extension ActivityTypeHint {
    var clActivityType: CLActivityType {
        switch self {
        case .other: return .other
        case .fitness: return .fitness
        case .automotiveNavigation: return .automotiveNavigation
        case .otherNavigation: return .otherNavigation
        }
    }
}

extension LocationAuthorization {
    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .authorizedWhenInUse: self = .whenInUse
        case .authorizedAlways: self = .always
        @unknown default: self = .notDetermined
        }
    }
}

extension BatteryState {
    init(_ state: UIDevice.BatteryState) {
        switch state {
        case .unknown: self = .unknown
        case .unplugged: self = .unplugged
        case .charging: self = .charging
        case .full: self = .full
        @unknown default: self = .unknown
        }
    }
}

extension LocationFix {
    /// Mirror a `CLLocation` field by field. Invalid CoreLocation values
    /// (negative accuracies/speed/course) are kept as-is; ``LocationFilter``
    /// and the store know the conventions.
    init(_ location: CLLocation) {
        self.init(latitude: location.coordinate.latitude,
                  longitude: location.coordinate.longitude,
                  altitude: location.altitude,
                  horizontalAccuracy: location.horizontalAccuracy,
                  verticalAccuracy: location.verticalAccuracy,
                  speed: location.speed,
                  speedAccuracy: location.speedAccuracy,
                  course: location.course,
                  timestamp: location.timestamp)
    }

    /// Build a fix from a `CLVisit`. A visit has no altitude/speed/course;
    /// the timestamp is the departure date for a departure event and the
    /// arrival date for an arrival (see ``CLVisit/eventDate``).
    init(_ visit: CLVisit) {
        self.init(latitude: visit.coordinate.latitude,
                  longitude: visit.coordinate.longitude,
                  altitude: 0,
                  horizontalAccuracy: visit.horizontalAccuracy,
                  verticalAccuracy: -1,
                  speed: -1,
                  speedAccuracy: -1,
                  course: -1,
                  timestamp: visit.eventDate)
    }
}

extension CLVisit {
    /// `true` when the visit describes an arrival that has not ended yet.
    var isArrivalEvent: Bool { departureDate == .distantFuture }

    /// Best timestamp for the event: departure when known, else arrival, else now.
    var eventDate: Date {
        if departureDate != .distantFuture { return departureDate }
        if arrivalDate != .distantPast { return arrivalDate }
        return Date()
    }
}
