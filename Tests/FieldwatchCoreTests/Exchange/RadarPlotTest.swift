import Foundation
import Testing
@testable import FieldwatchCore

// Port of RadarPlotTest.kt.

@Suite struct RadarPlotTest {
    private let maxR = 1000.0

    @Test func loudSitsNearCenter() {
        let r30 = RadarPlot.radius(rssi: -30, maxR: maxR)
        let r100 = RadarPlot.radius(rssi: -100, maxR: maxR)
        #expect(abs(r30 - 120.0) <= 0.5)
        #expect(abs(r100 - 1000.0) <= 0.5)
        #expect(r30 < RadarPlot.radius(rssi: -40, maxR: maxR))
        #expect(RadarPlot.radius(rssi: -60, maxR: maxR) < r100)
    }

    @Test func zoomSpreadsInnerRadiosAndPushesWeakOffDisc() {
        let inner = RadarPlot.radius(rssi: -40, maxR: maxR, zoom: 1.0)
        let innerZ = RadarPlot.radius(rssi: -40, maxR: maxR, zoom: 2.0)
        #expect(abs(inner * 2.0 - innerZ) <= 0.5)
        #expect(RadarPlot.onDisc(rssi: -100, maxR: maxR, zoom: 1.0))
        #expect(!RadarPlot.onDisc(rssi: -100, maxR: maxR, zoom: 2.0))
        #expect(RadarPlot.onDisc(rssi: -40, maxR: maxR, zoom: 2.0))
    }

    @Test func zoomIsClamped() {
        #expect(abs(RadarPlot.radius(rssi: -50, maxR: maxR, zoom: 1.0) - RadarPlot.radius(rssi: -50, maxR: maxR, zoom: 0.2)) <= 0.01)
        #expect(abs(RadarPlot.radius(rssi: -50, maxR: maxR, zoom: 4.0) - RadarPlot.radius(rssi: -50, maxR: maxR, zoom: 9.0)) <= 0.01)
    }
}
