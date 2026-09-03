import Foundation

/// Which units the UI renders distances, speeds, altitudes and accuracies in.
///
/// Display only: samples are always stored, exported and filtered in meters
/// and m/s. Persisted inside ``TrackingSettings``.
public enum UnitSystem: String, Codable, Sendable, Hashable, CaseIterable {
    case metric
    case imperial

    /// The system implied by the device's region, used the first time the app
    /// runs and by ``TrackingSettings`` as the default of its field.
    ///
    /// `Locale.MeasurementSystem` has three values. `.uk` is mapped to
    /// ``imperial`` on purpose: the United Kingdom is "mixed" — metric for
    /// most measurements but *miles and miles per hour on the road*, which is
    /// exactly what this app displays. A British user who wants meters can
    /// still pick ``metric`` in Settings.
    public static var deviceDefault: UnitSystem {
        switch Locale.current.measurementSystem {
        case .us, .uk: return .imperial
        default: return .metric
        }
    }
}
