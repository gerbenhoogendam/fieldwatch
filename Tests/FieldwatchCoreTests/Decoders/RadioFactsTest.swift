import Foundation
import Testing
@testable import FieldwatchCore

struct RadioFactsTest {
    @Test func connectableYesSurvivesScanResponse() {
        let adv = RadioFacts(connectable: true)
        let scanRsp = RadioFacts(connectable: false)
        #expect(adv.merge(newer: scanRsp).connectable == true)
        #expect(scanRsp.merge(newer: adv).connectable == true)
    }

    @Test func connectableStaysNoUntilAConnectableAd() {
        let first = RadioFacts(connectable: false)
        let again = RadioFacts(connectable: false)
        #expect(first.merge(newer: again).connectable == false)
    }

    @Test func connectableNullDoesNotClear() {
        let known = RadioFacts(connectable: false)
        #expect(known.merge(newer: RadioFacts()).connectable == false)
        #expect(RadioFacts().merge(newer: RadioFacts()).connectable == nil)
    }

    @Test func eddystoneFramesAccumulateInsteadOfReplacing() {
        let uid = RadioFacts(serviceData: [ServiceDataRecord(uuid: "FEAA", dataHex: "00AABBCCDDEEFF00112233445566778899")])
        let url = RadioFacts(serviceData: [ServiceDataRecord(uuid: "FEAA", dataHex: "1001676F6F676C6507")])
        let tlm = RadioFacts(serviceData: [ServiceDataRecord(uuid: "0000FEAA-0000-1000-8000-00805F9B34FB", dataHex: "2000ABCD")])
        let merged = uid.merge(newer: url).merge(newer: tlm)
        #expect(merged.serviceData.count == 3)
        #expect(Set(merged.serviceData.map { $0.dataHex.take(2) }) == ["00", "10", "20"])
    }

    @Test func otherServiceDataStillReplacesByUuid() {
        let first = RadioFacts(serviceData: [ServiceDataRecord(uuid: "FE2C", dataHex: "AA")])
        let second = RadioFacts(serviceData: [ServiceDataRecord(uuid: "FE2C", dataHex: "BBCC")])
        let merged = first.merge(newer: second)
        #expect(merged.serviceData.count == 1)
        #expect(merged.serviceData.first?.dataHex == "BBCC")
    }
}
