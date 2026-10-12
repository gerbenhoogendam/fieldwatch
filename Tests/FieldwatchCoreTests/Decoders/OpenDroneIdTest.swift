import Foundation
import Testing
@testable import FieldwatchCore

struct OpenDroneIdTest {
    private func near(_ a: Double?, _ b: Double, _ eps: Double = 1e-6) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= eps
    }

    @Test func bleLocationHeadingSpeedAndEw() {
        let loc = OpenDroneId.fromFacts(facts: RadioFacts(serviceData: [
            ServiceDataRecord(uuid: "FFFA", dataHex: bleWrap(locationMsg(dir: 90, ew: false, speed: 40))),
        ]))
        #expect(near(loc.lat, 40.0))
        #expect(near(loc.lon, -74.0))
        #expect(near(loc.headingDeg, 90.0))
        #expect(near(loc.speedMps, 10.0))
        #expect(near(loc.vspeedMps, 2.0))
        let west = OpenDroneId.fromFacts(facts: RadioFacts(serviceData: [
            ServiceDataRecord(uuid: "FFFA", dataHex: bleWrap(locationMsg(dir: 90, ew: true, speed: 40))),
        ]))
        #expect(near(west.headingDeg, 270.0))
    }

    @Test func wifiVendorIeLocation() {
        let ie = VendorIeRecord(oui: "FA:0B:BC", type: 0x0D, dataHex: "00" + locationMsg(dir: 45, ew: false, speed: 8).toHexUpper())
        let loc = OpenDroneId.fromFacts(facts: RadioFacts(vendorIes: [ie]))
        #expect(near(loc.lat, 40.0))
        #expect(near(loc.headingDeg, 45.0))
        #expect(near(loc.speedMps, 2.0))
    }

    @Test func unknownDirectionIsNull() {
        let loc = OpenDroneId.parseMessages(msgs: [locationMsg(dir: 255, ew: false, speed: 40)])
        #expect(loc.headingDeg == nil)
    }

    @Test func wifiMessagePackDecodesIdLocationAndOperator() {
        // DJI RID-1581F3… FA:0B:BC type 13 pack from A54 28 Sep 2026.
        let hex = "D9F2190302123135383146335954444A3144303033315A353330000000" +
            "1220820A00864228110CFF80CF0000F508B2083A022E310A00" +
            "420176E42711B5FF81CF010000000000000005088B02900E00"
        let loc = OpenDroneId.fromFacts(facts: RadioFacts(vendorIes: [VendorIeRecord(oui: "FA:0B:BC", type: 0x0D, dataHex: hex)]))
        #expect(loc.uasId == "1581F3YTDJ1D0031Z530")
        #expect(near(loc.lat, 28.7851142))
        #expect(near(loc.lon, -81.3629684))
        #expect(near(loc.headingDeg, 130.0))
        #expect(near(loc.speedMps, 2.5))
        #expect(near(loc.opLat, 28.7827062))
        #expect(near(loc.opLon, -81.3563979))
    }

    private func bleWrap(_ msg: [UInt8]) -> String { "0D00" + msg.toHexUpper() }

    private func locationMsg(dir: Int, ew: Bool, speed: Int) -> [UInt8] {
        let flags = 0x20 | (ew ? 0x02 : 0)
        let lat = le32(400_000_000)
        let lon = le32(-740_000_000)
        let geo = le16(2200)
        let height = le16(2100)
        let head: [UInt8] = [0x12, UInt8(flags), UInt8(truncatingIfNeeded: dir), UInt8(truncatingIfNeeded: speed), 4]
        return head + lat + lon + le16(0) + geo + height + [UInt8](repeating: 0, count: 6)
    }

    private func le32(_ n: Int) -> [UInt8] {
        [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)]
    }

    private func le16(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF)] }
}
