import Foundation

// Port of domain/RadarPlot.kt. Kotlin Float values are Double here.

/// Polar radius on Classic radar. Stronger RSSI sits closer to YOU.
/// `zoom` > 1 stretches the plot so loud radios spread out and weak ones
/// leave the disc. Angle is not part of this mapping.
public enum RadarPlot {
    public static let MIN_ZOOM = 1.0
    public static let MAX_ZOOM = 4.0

    public static func clampZoom(zoom: Double) -> Double { zoom.coerceIn(MIN_ZOOM, MAX_ZOOM) }

    public static func radius(rssi: Int, maxR: Double, zoom: Double = 1.0) -> Double {
        let t = (Double(-30 - rssi) / 70.0).coerceIn(0.0, 1.0)
        return maxR * (0.12 + t * 0.88) * clampZoom(zoom: zoom)
    }

    public static func onDisc(rssi: Int, maxR: Double, zoom: Double) -> Bool {
        radius(rssi: rssi, maxR: maxR, zoom: zoom) <= maxR + 0.5
    }
}
