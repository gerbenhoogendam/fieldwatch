import Foundation
import Testing
@testable import FieldwatchCore

// Port of LogReplayTest.kt.

struct LogReplayTest {
    private let csvHeader =
        "timestamp,iso,kind,mac,name,rssi,channel,freq,oui,vendor,fleets,mfg,uuids,flags,raw,lat,lon,vendor_ie\n"

    @Test func csvRowsMergeToOneRadio() {
        let log = csvHeader +
            "1000,iso,BLE,aa:bb:cc:dd:ee:01,Tag,-60,0,0,,Acme,,4C,,,AB12,,,\n" +
            "2000,iso,BLE,AA:BB:CC:DD:EE:01,Tag,-55,0,0,,Acme,,4C,,,AB12,,,\n"
        let radios = LogReplay.parse(text: log)
        #expect(radios.count == 1)
        let r = radios[0]
        #expect(r.mac == "AA:BB:CC:DD:EE:01")
        #expect(r.name == "Tag")
        #expect(r.rssi == -55) // last row wins
        #expect(r.firstSeen == 1000)
        #expect(r.lastSeen == 2000)
        #expect(r.hits == 2)
        #expect(r.manufacturerId == 0x4C)
        #expect(r.manufacturerDataHex == "AB12")
    }

    @Test func csvKeepsLastGpsFixAndChannel() {
        func row(_ rssi: String, _ ch: String, _ freq: String, _ lat: String, _ lon: String) -> String {
            [
                "2000", "iso", "WIFI", "00:11:22:33:44:55", "Cafe", rssi, ch, freq,
                "", "Acme", "", "", "", "", "", lat, lon, "",
            ].joined(separator: ",")
        }
        let log = csvHeader +
            row("-80", "1", "2412", "", "") + "\n" +
            row("-70", "6", "2437", "37.5", "-122.1") + "\n"
        let r = LogReplay.parse(text: log).single { _ in true }
        #expect(r.channel == 6)
        #expect(r.frequencyMhz == 2437)
        #expect(abs(r.latitude! - 37.5) <= 0.0001)
        #expect(abs(r.longitude! - -122.1) <= 0.0001)
        #expect(r.hasPosition)
    }

    @Test func lineKindReadsCsvAndJson() {
        let csv = [
            "2000", "iso", "BLE", "AA:BB:CC:DD:EE:01", "Tag", "-50", "0", "0",
            "", "", "", "", "", "", "", "", "", "",
        ].joined(separator: ",")
        #expect(LogReplay.lineKind(line: csv, json: false) == .ble)
        #expect(LogReplay.lineKind(line: #"{"kind":"WIFI","mac":"00:11:22:33:44:55"}"#, json: true) == .wifi)
        #expect(LogExportRadios.wifi.matches(kind: .wifi))
        #expect(!LogExportRadios.wifi.matches(kind: .ble))
        #expect(LogExportRadios.both.matches(kind: .ble))
    }

    @Test func csvRoundTripToJsonlKeepsKindMacAndGps() {
        let csv = [
            "2000", "iso", "WIFI", "00:11:22:33:44:55", "Cafe", "-70", "6", "2437",
            "", "Acme", "", "4C", "", "RAND", "AB", "37.5", "-122.1", "",
        ].joined(separator: ",")
        let json = LogReplay.csvRowToJson(line: csv)!
        #expect(json.contains("\"kind\":\"WIFI\""))
        #expect(json.contains("\"mac\":\"00:11:22:33:44:55\""))
        #expect(json.contains("\"rand\":true"))
        let back = LogReplay.jsonRowToCsv(line: json)!
        let cols = back.split(",")
        #expect(cols[2] == "WIFI")
        #expect(cols[3] == "00:11:22:33:44:55")
        #expect(cols[15] == "37.500000")
        #expect(cols[16] == "-122.100000")
        let hostile = LogReplay.jsonRowToCsv(
            line: #"{"kind":"WIFI","mac":"00:11:22:33:44:55","name":"=cmd","vendor":"@sum","fleets":"ok","lat":37.5,"lon":-122.1}"#
        )!
        let hostileCols = hostile.split(",")
        #expect(hostileCols[4] == "'=cmd")
        #expect(hostileCols[9] == "'@sum")
        #expect(hostileCols[16] == "-122.100000")
        #expect(cols[13].contains("RAND"))
    }

    @Test func csvWithoutHeaderUsesDefaultLayout() {
        // A rotated part or a hand-cut excerpt has no header line.
        let log = "3000,iso,WIFI,00:11:22:33:44:55,CafeWiFi,-70,6,2437,,Cisco,,,,,,,\n"
        let radios = LogReplay.parse(text: log)
        #expect(radios.count == 1)
        #expect(radios[0].kind == .wifi)
        #expect(radios[0].name == "CafeWiFi")
        #expect(radios[0].firstSeen == 3000)
    }

    @Test func jsonLinesParseAndMerge() {
        let log = """
            {"ts":500,"kind":"BLE","mac":"aa:bb:cc:dd:ee:02","name":"Buds","rssi":-48,"mfg":76,"rand":true}
            {"ts":900,"kind":"BLE","mac":"AA:BB:CC:DD:EE:02","rssi":-40,"uuids":"FE2C"}
            """
        let radios = LogReplay.parse(text: log)
        #expect(radios.count == 1)
        let r = radios[0]
        #expect(r.name == "Buds")
        #expect(r.rssi == -40)
        #expect(r.serviceUuids == ["FE2C"])
        #expect(r.randomized)
        #expect(r.hits == 2)
    }

    @Test func junkLinesAreSkipped() {
        let log = csvHeader +
            "\n" +
            "garbage line with no commas that parses to nothing\n" +
            "1500,iso,NOPE,AA:BB:CC:DD:EE:03,X,-1,0,0,,,,,,,,,\n" +
            "1600,iso,BLE,AA:BB:CC:DD:EE:03,Real,-70,0,0,,,,,,,,,\n"
        let radios = LogReplay.parse(text: log)
        #expect(radios.count == 1)
        #expect(radios[0].name == "Real")
    }

    @Test func flagsAndHiddenSurviveReplay() {
        let log = csvHeader +
            "1000,iso,WIFI,02:11:22:33:44:55,,-80,0,0,,,,,,RAND HIDDEN,,,,\n"
        let r = LogReplay.parse(text: log).single { _ in true }
        #expect(r.randomized)
        #expect(r.hiddenSsid)
    }

    @Test func emptyInputGivesEmptyList() {
        #expect(LogReplay.parse(text: "").isEmpty)
        #expect(LogReplay.parse(text: "\n\n").isEmpty)
    }

    @Test func mfgFieldParsesHexFirst() {
        // "mfg" is written hex by the logger ("4C"); a bare digit string is still hex-parsed.
        let log = csvHeader +
            "1000,iso,BLE,AA:BB:CC:DD:EE:04,X,-50,0,0,,,,76,,,,,\n" +
            "2000,iso,BLE,AA:BB:CC:DD:EE:05,Y,-50,0,0,,,,4C,,,,,\n"
        let radios = LogReplay.parse(text: log).associateBy { $0.mac }
        #expect(radios["AA:BB:CC:DD:EE:04"]!.manufacturerId == 0x76)
        #expect(radios["AA:BB:CC:DD:EE:05"]!.manufacturerId == 0x4C)
    }

    @Test func nullJsonMfgStaysNull() {
        let log = #"{"ts":1,"kind":"BLE","mac":"AA:BB:CC:DD:EE:06","mfg":null}"#
        #expect(LogReplay.parse(text: log).single { _ in true }.manufacturerId == nil)
    }
}
