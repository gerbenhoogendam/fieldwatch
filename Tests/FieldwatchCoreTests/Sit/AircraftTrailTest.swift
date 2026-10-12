import Foundation
import Testing
@testable import FieldwatchCore

// Port of AircraftTrailTest.kt.

private func with<T>(_ v: T, _ f: (inout T) -> Void) -> T {
    var c = v
    f(&c)
    return c
}

private func settings(tagLocation: Bool) -> AppSettings {
    var s = AppSettings()
    s.tagLocation = tagLocation
    return s
}

struct AircraftTrailTest {
    @Test func appendSkipsAShortMoveAndAGlitchAndKeepsTheEnds() {
        var trail: [PayloadFix] = []
        trail = AircraftTrail.append(trail: trail, fix: fix(0, 28.0, -81.0))
        trail = AircraftTrail.append(trail: trail, fix: fix(1_000, 28.00002, -81.0))
        #expect(trail.count == 1)
        trail = AircraftTrail.append(trail: trail, fix: fix(2_000, 28.02, -81.0))
        #expect(trail.count == 1, "a one-second jump of about 2 km is dropped")
        trail = AircraftTrail.append(trail: trail, fix: fix(30_000, 28.001, -81.0))
        #expect(trail.count == 2)
        for i in 0..<50 {
            trail = AircraftTrail.append(trail: trail, fix: fix(60_000 + i * 20_000, 28.001 + Double(i + 1) * 0.001, -81.0))
        }
        #expect(trail.count <= AircraftTrail.CAP)
        #expect(abs(trail.first!.lat - 28.0) <= 1e-6)
        #expect(abs(trail.last!.lat - (28.001 + 50 * 0.001)) <= 1e-4)
    }

    @Test func sameUasIdJoinsAndAFarTrackGetsItsOwnFigure() throws {
        let path = [
            GpsSample(at: 0, lat: 28.0, lon: -81.0, rssi: -50),
            GpsSample(at: 60_000, lat: 28.001, lon: -81.0, rssi: -50),
        ]
        let nearA = source("ABC123", "near-a", 10_000, 28.0004, -81.0, "Airborne")
        let nearB = source("ABC123", "near-b", 40_000, 28.0008, -81.0, "Airborne")
        let far = source("ZZZ999", "far", 20_000, 28.08, -81.0, "Ground")
        let anon = source("", "stray", 20_000, 40.0, -74.0, "")
        let pictures = AircraftTrail.pictures(sources: [nearA, nearB, far, anon], path: path)
        let joined = pictures.single { $0.uasId == "ABC123" }
        #expect(joined.onWalk)
        #expect(!joined.ownFigure)
        #expect(joined.fixes.count >= 2)
        let away = pictures.single { $0.uasId == "ZZZ999" }
        #expect(!away.onWalk)
        #expect(away.ownFigure)
        let stray = pictures.single { $0.uasId.isBlank }
        #expect(!stray.onWalk)
        #expect(!stray.ownFigure)
        let own = AircraftTrail.ownFigures(pictures: pictures)
        #expect(own.count == 1)
        #expect(own.single { _ in true }.kicker == "AIRCRAFT")
        #expect(own.single { _ in true }.tracks.single { _ in true }.aircraft)
        #expect(abs(own.single { _ in true }.tracks.single { _ in true }.headingDeg! - 90.0) <= 0.01)
        #expect(own.single { _ in true }.caption.contains("marker"))
        let over = AircraftTrail.overlay(
            model: SitPathPlot.Model(
                samples: path,
                dots: [],
                lengthM: 100.0,
                spanM: 100.0,
                title: "walk"
            ),
            pictures: pictures
        )
        #expect(over.samples.count == 2)
        #expect(over.craft.count == 1)
        #expect(over.craft.single { _ in true }.aircraft)
        #expect(over.craft.single { _ in true }.name == "ABC123")
        #expect(abs(over.craft.single { _ in true }.headingDeg! - 90.0) <= 0.01)
        #expect(over.craft.single { _ in true }.samples.count >= 2)
        #expect(over.aircraftCards.count == 1)
        #expect(over.aircraftCards.single { _ in true }.title == "ZZZ999")
        #expect(abs(over.aircraftCards.single { _ in true }.minHalfSpanM - 140) <= 0.01)
        #expect(over.looseAdvertised == 1)
        let walk = try #require(SitPathPlot.layout(model: over, width: 400, height: 300))
        #expect(walk.path.count == 2)
        let nearPt = walk.project(28.0008, -81.0)
        #expect(nearPt.y > walk.plotTop && nearPt.y < walk.plotBottom)
        #expect(walk.project(28.08, -81.0).y < walk.plotTop)
        let card = try #require(SitPathPlot.layout(model: over.aircraftCards.single { _ in true }, width: 400, height: 300))
        #expect(card.path.isEmpty)
        let farPt = card.project(28.08, -81.0)
        #expect(farPt.x > card.plotLeft && farPt.x < card.plotRight)
        #expect(farPt.y > card.plotTop && farPt.y < card.plotBottom)
    }

    @Test func decodedAlertStaysOnANearTrackAndAFarOneLeavesTheWalk() throws {
        let path = [
            GpsSample(at: 0, lat: 28.0, lon: -81.0, rssi: -50),
            GpsSample(at: 60_000, lat: 28.001, lon: -81.0, rssi: -50),
        ]
        let near = source("ABC123", "near", 40_000, 28.0008, -81.0, "Airborne", key: "near-key")
        let far = source("ZZZ999", "far", 20_000, 28.08, -81.0, "Ground", key: "far-key")
        let pictures = AircraftTrail.pictures(sources: [near, far], path: path)
        let nearDot = alertDot("near-key", 28.0008, -81.0, advertised: true)
        let farDot = alertDot("far-key", 28.08, -81.0, advertised: true)
        let phoneDot = alertDot("phone", 28.0, -81.0, advertised: false)
        let over = AircraftTrail.overlay(
            model: SitPathPlot.Model(
                samples: path,
                dots: [phoneDot, nearDot, farDot],
                lengthM: 100.0,
                spanM: 100.0,
                title: "walk"
            ),
            pictures: pictures
        )
        #expect(over.dots.map { $0.key } == ["phone", "near-key"])
        #expect(over.aircraftCards.single { _ in true }.dots.map { $0.key } == ["far-key"])
        #expect(SitPathPlot.sitsOnCraft(dot: nearDot, craft: over.craft))
        #expect(!SitPathPlot.sitsOnCraft(dot: phoneDot, craft: over.craft))
        #expect(SitPathPlot.sitsOnCraft(dot: farDot, craft: over.aircraftCards.single { _ in true }.craft))
        let walk = try #require(SitPathPlot.layout(model: over, width: 400, height: 300))
        #expect(walk.project(28.08, -81.0).y < walk.plotTop)
    }

    @Test func sitKeepsTheAdvertisedTrailAfterTheWindowCloses() throws {
        let session = SitSession.start(
            name: "flight",
            now: 1_000,
            heard: [drone(1_000, 28.0, -81.0)],
            fleets: [],
            watchDeviceKeys: [],
            watchedFleetIds: []
        )
        session.ingest(device: drone(20_000, 28.002, -81.0), fleets: [], watchDeviceKeys: [], watchedFleetIds: [])
        session.ingest(device: drone(40_000, 28.004, -81.0), fleets: [], watchDeviceKeys: [], watchedFleetIds: [])
        let saved = session.snapshot().radios.single { _ in true }
        #expect(saved.payloadTrail.count == 3)
        #expect(abs(saved.payloadAlt! - 130.0) <= 1e-6)
        #expect(saved.payloadUasId == "ABC123")
        let text = DebriefReport.document(
            devices: [saved.toSighting()],
            fleets: [],
            settings: settings(tagLocation: true),
            operatorPath: [
                GpsSample(at: 1_000, lat: 28.0, lon: -81.0, rssi: -50),
                GpsSample(at: 40_000, lat: 28.001, lon: -81.0, rssi: -50),
            ],
            now: 40_000,
            window: DebriefWindow(startAt: 1_000, endAt: 40_000, sitName: "flight"),
            watchedFleetIds: ["fleet-remote-id"]
        )
        let plain = text.toPlainText()
        #expect(plain.contains("AIRCRAFT"))
        #expect(plain.contains("ABC123"))
        #expect(plain.contains("Airborne"))
        #expect(plain.contains("advertised aircraft positions"))
        let figure = try #require(text.pathFigure)
        #expect(figure.tracks.contains { $0.aircraft })
        #expect(figure.dots.isEmpty)
        let row = figure.craftKeys.single { _ in true }
        #expect(row.contains("Remote ID"))
        #expect(row.contains("AA:BB:CC:DD:EE:10"))
        #expect(row.contains("Airborne"))
        #expect(row.contains("UAS ABC123"))
        #expect(!row.contains("Freefly"))
        #expect(row.contains("28.004000"))
        #expect(row.contains("130 m"))
        #expect(row.contains("course 90°"))
        #expect(text.extraFigures.isEmpty)
    }

    @Test func privacyModeMasksRemoteIdInThePathKey() throws {
        let serial = "1581F6Z9D242C0018A7B"
        let mac = "60:60:1F:3B:84:2E"
        let heard = with(drone(40_000, 28.004, -81.0)) {
            $0.key = "BLE:\(mac)"
            $0.mac = mac
            $0.name = ""
            $0.payloadUasId = serial
            $0.payloadOpLat = 28.787120
            $0.payloadOpLon = -81.360360
        }
        let open = DebriefReport.document(
            devices: [heard],
            fleets: [],
            settings: settings(tagLocation: true),
            operatorPath: [
                GpsSample(at: 1_000, lat: 28.0, lon: -81.0, rssi: -50),
                GpsSample(at: 40_000, lat: 28.001, lon: -81.0, rssi: -50),
            ],
            now: 40_000,
            window: DebriefWindow(startAt: 1_000, endAt: 40_000, sitName: "flight"),
            watchedFleetIds: ["fleet-remote-id"]
        )
        let row = try #require(open.pathFigure).craftKeys.single { _ in true }
        #expect(row.contains(mac))
        #expect(row.contains(serial))
        #expect(row.contains("28.004000, -81.000000"))
        #expect(row.contains("28.787120, -81.360360"))
        let masked = open.withDemoMacs(macs: [mac], demo: true, uasIds: [serial])
        let key = try #require(masked.pathFigure).craftKeys.single { _ in true }
        #expect(key.contains("60:60:1F:**:**:**"))
        #expect(!key.contains("3B:84:2E"))
        #expect(!key.contains(serial))
        #expect(key.contains("UAS masked"))
        #expect(!key.contains("28.004000"))
        #expect(!key.contains("-81.000000"))
        #expect(!key.contains("28.787120"))
        #expect(!key.contains("-81.360360"))
        #expect(key.contains("last masked"))
        #expect(key.contains("pilot masked"))
        #expect(key.contains("130 m"))
        #expect(key.contains("course 90"))
        let plain = masked.toPlainText()
        #expect(!plain.contains(serial))
        #expect(!plain.contains(mac))
        #expect(!plain.contains("28.004000"))
        #expect(!plain.contains("28.787120"))
        #expect(plain.contains("Advertised position: masked"))
        let dot = SitPathPlot.Dot(
            key: "BLE:\(mac)",
            lat: 28.004,
            lon: -81.0,
            label: mac,
            extraAttention: false,
            named: false,
            mac: mac,
            advertisedNote: "Airborne · UAS \(serial) · last 28.787120, -81.365491 · pilot 28.787120, -81.360360"
        )
        let figure = SitPathPlot.Figure(
            kicker: "OPERATOR PATH",
            tracks: [],
            dots: [dot],
            lengthM: 0.0,
            spanM: 0.0,
            caption: "advertised track for \(serial)",
            craftKeys: [row]
        )
        let doc = with(masked) { $0.pathFigure = figure }.withDemoMacs(macs: [mac], demo: true, uasIds: [serial])
        let kept = try #require(doc.pathFigure)
        #expect(kept.dots.single { _ in true }.mac == "60:60:1F:**:**:**")
        #expect(kept.dots.single { _ in true }.label == "60:60:1F:**:**:**")
        #expect(!kept.dots.single { _ in true }.advertisedNote.contains(serial))
        #expect(!kept.dots.single { _ in true }.advertisedNote.contains("28.787120"))
        #expect(!kept.caption.contains(serial))
        #expect(kept.dots.single { _ in true }.lat == 28.004)
    }

    @Test func advertisedNoteLeadsWithTheSerialMaker() {
        let note = AircraftTrail.advertisedNote(
            status: "Airborne",
            uasId: "18179132000209",
            label: "Remote ID",
            lat: 28.0,
            lon: -81.0,
            alt: 100.0,
            heading: 90.0,
            speed: 5.0,
            pilotLat: nil,
            pilotLon: nil,
            aircraft: "Freefly Alta X Gen2"
        )
        #expect(note.hasPrefix("Freefly Alta X Gen2 · Airborne · UAS 18179132000209"))
        let text = AircraftTrail.body(
            pictures: [
                AircraftTrail.Picture(
                    uasId: "18179200000001",
                    title: "18179200000001",
                    fixes: [PayloadFix(at: 1, lat: 28.0, lon: -81.0)],
                    status: "Airborne",
                    alt: nil,
                    heading: nil,
                    speed: nil,
                    pilotLat: nil,
                    pilotLon: nil,
                    pilotOnMap: false,
                    onWalk: true,
                    ownFigure: false,
                    aircraft: "Freefly Alta X"
                ),
            ]
        )
        #expect(text.lines()[1] == "  Freefly Alta X")
    }

    @Test func sitKeepsSerialMakerUntilTheUasIdChanges() {
        let first = with(drone(1_000, 28.0, -81.0)) { $0.payloadAircraft = "Freefly Alta X" }
        let session = SitSession.start(
            name: "flight",
            now: 1_000,
            heard: [first],
            fleets: [],
            watchDeviceKeys: [],
            watchedFleetIds: []
        )
        session.ingest(device: drone(20_000, 28.002, -81.0), fleets: [], watchDeviceKeys: [], watchedFleetIds: [])
        #expect(session.snapshot().radios.single { _ in true }.payloadAircraft == "Freefly Alta X")
        session.ingest(
            device: with(drone(40_000, 28.004, -81.0)) { $0.payloadUasId = "SESSION1"; $0.payloadAircraft = nil },
            fleets: [],
            watchDeviceKeys: [],
            watchedFleetIds: []
        )
        let saved = session.snapshot().radios.single { _ in true }
        #expect(saved.payloadUasId == "SESSION1")
        #expect(saved.payloadAircraft == nil)
    }

    private func fix(_ at: Int, _ lat: Double, _ lon: Double) -> PayloadFix { PayloadFix(at: at, lat: lat, lon: lon) }

    private func alertDot(_ key: String, _ lat: Double, _ lon: Double, advertised: Bool) -> SitPathPlot.Dot {
        SitPathPlot.Dot(
            key: key,
            lat: lat,
            lon: lon,
            label: key,
            extraAttention: false,
            named: false,
            advertised: advertised
        )
    }

    private func source(
        _ uasId: String,
        _ title: String,
        _ at: Int,
        _ lat: Double,
        _ lon: Double,
        _ status: String,
        key: String = ""
    ) -> AircraftTrail.Source {
        AircraftTrail.Source(
            uasId: uasId,
            title: title,
            lastSeen: at,
            status: status,
            fixes: [PayloadFix(at: at, lat: lat, lon: lon, alt: 100.0)],
            alt: 100.0,
            heading: 90.0,
            speed: 5.0,
            pilotLat: nil,
            pilotLon: nil,
            key: key
        )
    }

    private func drone(_ at: Int, _ lat: Double, _ lon: Double) -> Sighting {
        Sighting(
            key: "BLE:AA:BB:CC:DD:EE:10",
            kind: .ble,
            mac: "AA:BB:CC:DD:EE:10",
            name: "Remote ID",
            rssi: -60,
            rssiMin: -60,
            rssiMax: -60,
            channel: 0,
            frequencyMhz: 2402,
            vendor: nil,
            randomized: true,
            hiddenSsid: false,
            serviceUuids: ["FFFA"],
            manufacturerId: nil,
            manufacturerDataHex: "",
            rawHex: "",
            extras: "",
            firstSeen: 1_000,
            lastSeen: at,
            hitCount: 3,
            fleetIds: ["fleet-remote-id"],
            rssiHistory: [],
            presence: [],
            payloadLat: lat,
            payloadLon: lon,
            payloadAlt: 130.0,
            payloadUasId: "ABC123",
            payloadHeading: 90.0,
            payloadSpeed: 8.0,
            liveDecode: [LiveDecodeChip(text: "Airborne", emphasis: false)]
        )
    }
}
