import Foundation
import FieldwatchCore

// macOS addition: data for the Map view (estimated radio positions). Not in the Android app.

extension FieldwatchViewModel {
    /// Estimates for the radios Live would show (Filters apply), plus advertised positions.
    func positionEstimates() -> [PositionEstimate] {
        let field = app.positions
        return ui.filtered.compactMap { device in
            PositionEstimator.estimate(device: device, samples: field.samples(key: device.key))
        }
    }

    /// Where this Mac has been this session (the Moving-with-you path).
    func operatorPath() -> [GpsSample] { app.operatorPathCopy() }

    /// This Mac's latest position, if Location has one.
    func macFix() -> (lat: Double, lon: Double)? { app.lastFix.map { ($0.0, $0.1) } }

    /// Number of radios with a loudness map.
    func positionFieldCount() -> Int { app.positions.radioCount }

    /// Map → Start over: forget every loudness map. Logs and sits are unchanged.
    func clearPositionField() { app.positions.clear() }

    /// Device for a key among the radios on screen.
    func device(key: String) -> Sighting? {
        ui.filtered.first { $0.key == key } ?? ui.devices.first { $0.key == key }
    }
}
