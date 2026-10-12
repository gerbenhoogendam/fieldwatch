import Foundation
import Testing
@testable import FieldwatchCore

struct HuntTest {
    private let now = 100_000

    @Test func veryCloseBeatsCloserWhenScreamingLoud() {
        let samples = [
            RssiSample(at: now - 6_000, rssi: -70),
            RssiSample(at: now - 5_000, rssi: -68),
            RssiSample(at: now - 1_200, rssi: -38),
            RssiSample(at: now - 400, rssi: -36),
        ]
        #expect(Hunt.cue(samples: samples, now: now, lastSeen: now - 400, missing: false) == .veryClose)
    }

    @Test func belowVeryCloseStillUsesRelativeCue() {
        let samples = [
            RssiSample(at: now - 6_000, rssi: -72),
            RssiSample(at: now - 5_000, rssi: -70),
            RssiSample(at: now - 1_200, rssi: -60),
            RssiSample(at: now - 400, rssi: -58),
        ]
        #expect(Hunt.cue(samples: samples, now: now, lastSeen: now - 400, missing: false) == .closer)
    }

    @Test func quietWinsOverALoudLastPacket() {
        let samples = [RssiSample(at: now - 9_000, rssi: -30)]
        #expect(Hunt.cue(samples: samples, now: now, lastSeen: now - 9_000, missing: false) == .quiet)
    }

    @Test func goneWins() {
        #expect(Hunt.cue(samples: [], now: now, lastSeen: now, missing: true) == .gone)
    }

    @Test func tickSilentWhenQuietGoneOrNoRssi() {
        #expect(Hunt.tickIntervalMs(rssi: -40, cue: .quiet) == nil)
        #expect(Hunt.tickIntervalMs(rssi: -40, cue: .gone) == nil)
        #expect(Hunt.tickIntervalMs(rssi: nil, cue: .closer) == nil)
    }

    @Test func tickFasterWhenLouder() throws {
        let slow = try #require(Hunt.tickIntervalMs(rssi: -90, cue: .same))
        let mid = try #require(Hunt.tickIntervalMs(rssi: -65, cue: .closer))
        let fast = try #require(Hunt.tickIntervalMs(rssi: -40, cue: .veryClose))
        #expect(slow == Hunt.TICK_SLOW_MS)
        #expect(fast == Hunt.TICK_FAST_MS)
        #expect(((fast + 1)..<slow).contains(mid))
        let veryClose = try #require(Hunt.tickIntervalMs(rssi: -45, cue: .veryClose))
        #expect(veryClose < mid)
        #expect(veryClose > fast)
    }
}
