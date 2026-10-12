import Foundation
import Testing
@testable import FieldwatchCore

// Port of test/java/app/fieldwatch/data/PathTilesTest.kt.
struct PathTilesTests {
    @Test func zoomTightensForAShortSpanAndOpensForADrive() {
        #expect(PathTiles.zoomFor(spanM: 80.0, lat: 28.5) >= 15)
        #expect((8...14).contains(PathTiles.zoomFor(spanM: 12_000.0, lat: 28.5)))
    }

    @Test func expandToPlotFillsAWidePlotForATallPath() {
        let box = PathTiles.expandToPlot(minLat: 28.780, maxLat: 28.790, minLon: -81.370, maxLon: -81.3695)
        let latSpan = box[1] - box[0]
        let lonSpan = box[3] - box[2]
        let yM = latSpan * 110_540.0
        let xM = lonSpan * 111_320.0 * cos(28.785 * .pi / 180.0)
        #expect((1.5...1.9).contains(xM / yM))
    }

    @Test func aSingleFixStillRequestsANeighborhoodOfTiles() {
        let box = PathTiles.expandToPlot(minLat: 28.780, maxLat: 28.780, minLon: -81.370, maxLon: -81.370)
        let yM = (box[1] - box[0]) * 110_540.0
        #expect(yM >= 400.0)
    }
}
