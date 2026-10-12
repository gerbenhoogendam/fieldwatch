import Foundation
import Testing
@testable import FieldwatchCore

// Port of SitPathPlotTest.kt. Kotlin Float plot math is Double here.

private func with<T>(_ v: T, _ f: (inout T) -> Void) -> T {
    var c = v
    f(&c)
    return c
}

private func sighting(
    key: String, kind: RadioKind, mac: String, name: String, rssi: Int, rssiMin: Int, rssiMax: Int,
    channel: Int, frequencyMhz: Int, vendor: String? = nil, firstSeen: Int, lastSeen: Int, hitCount: Int,
    fleetIds: [String], gpsTrail: [GpsSample]
) -> Sighting {
    Sighting(
        key: key, kind: kind, mac: mac, name: name, rssi: rssi, rssiMin: rssiMin, rssiMax: rssiMax,
        channel: channel, frequencyMhz: frequencyMhz, vendor: vendor, randomized: false, hiddenSsid: false,
        serviceUuids: [], manufacturerId: nil, manufacturerDataHex: "", rawHex: "", extras: "",
        firstSeen: firstSeen, lastSeen: lastSeen, hitCount: hitCount, fleetIds: fleetIds,
        rssiHistory: [], presence: [], gpsTrail: gpsTrail
    )
}

private let axon = Fleet(
    id: "fleet-axon",
    name: "Axon",
    attentionNote: "Body-worn.",
    kind: .lawEnforcement
)

struct SitPathPlotTest {
    @Test func northIsUpAndEastIsRight() throws {
        let south = GpsSample(at: 1, lat: 28.7800, lon: -81.3700)
        let north = GpsSample(at: 2, lat: 28.7810, lon: -81.3700)
        let east = GpsSample(at: 3, lat: 28.7810, lon: -81.3690)
        let model = SitPathPlot.Model(
            samples: [south, north, east],
            dots: [],
            lengthM: 200.0,
            spanM: 150.0,
            title: "test"
        )
        let layout = try #require(SitPathPlot.layout(model: model, width: 400, height: 300))
        #expect(layout.path.count == 3)
        #expect(layout.path[1].y < layout.path[0].y)
        #expect(layout.path[2].x > layout.path[1].x)
    }

    @Test func tallPathCentersHorizontally() throws {
        let south = GpsSample(at: 1, lat: 28.7800, lon: -81.3700)
        let north = GpsSample(at: 2, lat: 28.7850, lon: -81.3700)
        let model = SitPathPlot.Model(
            samples: [south, north],
            dots: [],
            lengthM: 550.0,
            spanM: 550.0,
            title: "tall"
        )
        let layout = try #require(SitPathPlot.layout(model: model, width: 400, height: 300))
        let mid = 200.0
        for pt in layout.path {
            #expect(abs(pt.x - mid) < 20)
        }
    }

    @Test func oneAdvertisedFixStillFrames() throws {
        let model = SitPathPlot.Model(
            samples: [],
            dots: [],
            lengthM: 0.0,
            spanM: 0.0,
            title: "AIRCRAFT",
            frameSamples: [GpsSample(at: 1, lat: 28.78, lon: -81.36)],
            minHalfSpanM: 140
        )
        let layout = try #require(SitPathPlot.layout(model: model, width: 400, height: 300, pad: 12, scaleBarReserve: 0))
        let pt = layout.project(28.78, -81.36)
        #expect(pt.x > layout.plotLeft && pt.x < layout.plotRight)
        #expect(pt.y > layout.plotTop && pt.y < layout.plotBottom)
        #expect(layout.path.isEmpty)
    }

    @Test func advertisedFixDoesNotExtendThePhoneLine() throws {
        let model = SitPathPlot.Model(
            samples: [
                GpsSample(at: 1, lat: 28.78, lon: -81.37),
                GpsSample(at: 2, lat: 28.781, lon: -81.37),
            ],
            dots: [],
            lengthM: 100.0,
            spanM: 100.0,
            title: "walk",
            frameSamples: [GpsSample(at: 3, lat: 28.80, lon: -81.37)]
        )
        let layout = try #require(SitPathPlot.layout(model: model, width: 400, height: 300))
        #expect(layout.path.count == 2)
        let craft = layout.project(28.80, -81.37)
        #expect(craft.y < layout.path[0].y)
        #expect(craft.y > layout.plotTop)
    }

    @Test func shortPathOpensEnoughGroundToReadTheStreets() throws {
        let model = SitPathPlot.Model(
            samples: [
                GpsSample(at: 1, lat: 28.78000, lon: -81.37000),
                GpsSample(at: 2, lat: 28.78002, lon: -81.37000),
            ],
            dots: [],
            lengthM: 2.0,
            spanM: 2.0,
            title: "still"
        )
        let layout = try #require(SitPathPlot.layout(model: model, width: 400, height: 300))
        let here = layout.project(28.78000, -81.37000)
        let north = layout.project(28.78200, -81.37000)
        let meters = 0.002 * 110_540.0
        let pxPerM = (here.y - north.y) / meters
        let viewM = (layout.plotBottom - layout.plotTop) / pxPerM
        #expect((350.0...600.0).contains(viewM))
        #expect(here.y > layout.plotTop && here.y < layout.plotBottom)
    }

    @Test func oneGpsFixStillFrames() throws {
        let model = SitPathPlot.Model(
            samples: [GpsSample(at: 1, lat: 28.78000, lon: -81.37000)],
            dots: [],
            lengthM: 0.0,
            spanM: 0.0,
            title: "one"
        )
        let layout = try #require(SitPathPlot.layout(model: model, width: 400, height: 300))
        let pt = layout.project(28.78000, -81.37000)
        #expect(pt.x > layout.plotLeft && pt.x < layout.plotRight)
        #expect(pt.y > layout.plotTop && pt.y < layout.plotBottom)
    }

    @Test func aLongWalkStillFillsThePlot() throws {
        let model = SitPathPlot.Model(
            samples: [
                GpsSample(at: 1, lat: 28.7800, lon: -81.3700),
                GpsSample(at: 2, lat: 28.8000, lon: -81.3700),
            ],
            dots: [],
            lengthM: 2200.0,
            spanM: 2200.0,
            title: "drive"
        )
        let layout = try #require(SitPathPlot.layout(model: model, width: 400, height: 300))
        let south = layout.project(28.7800, -81.3700)
        let north = layout.project(28.8000, -81.3700)
        let used = (south.y - north.y) / (layout.plotBottom - layout.plotTop)
        #expect(used > 0.7)
    }

    @Test func scaleBarIsANiceMeterValue() {
        #expect(abs(SitPathPlot.niceMeters(raw: 47.0) - 50.0) <= 0.01)
        #expect(abs(SitPathPlot.niceMeters(raw: 80.0) - 100.0) <= 0.01)
        #expect(abs(SitPathPlot.niceMeters(raw: 18.0) - 20.0) <= 0.01)
    }

    @Test func nearbyDotsBecomeOneStackedCluster() {
        let a = SitPathPlot.Dot(key: "a", lat: 0.0, lon: 0.0, label: "A", extraAttention: true, named: false)
        let b = SitPathPlot.Dot(key: "b", lat: 0.0, lon: 0.0, label: "B", extraAttention: true, named: false)
        let c = SitPathPlot.Dot(key: "c", lat: 0.0, lon: 0.0, label: "C", extraAttention: false, named: true)
        let stacked = SitPathPlot.clusters(
            dots: [
                (a, SitPathPlot.Pt(x: 10, y: 10)),
                (b, SitPathPlot.Pt(x: 18, y: 12)),
                (c, SitPathPlot.Pt(x: 200, y: 180)),
            ],
            threshPx: 28
        )
        #expect(stacked.count == 2)
        let pile = stacked.first { $0.stacked }!
        #expect(pile.members.count == 2)
        #expect(stacked.contains { !$0.stacked && $0.members.single { _ in true }.dot.key == "c" })
    }

    @Test func startLabelOpensTheDetectionItCovers() {
        let dot = SitPathPlot.Dot(key: "a", lat: 0.0, lon: 0.0, label: "A", extraAttention: false, named: true)
        let cluster = SitPathPlot.clusters(dots: [(dot, SitPathPlot.Pt(x: 100, y: 100))]).single { _ in true }
        let start = SitPathPlot.HitMarker(
            x: 100,
            y: 100,
            radius: 12,
            labelLeft: 108,
            labelTop: 94,
            labelRight: 180,
            labelBottom: 112
        )
        let onTheWord = SitPathPlot.clusterAt(clusters: [cluster], x: 160, y: 100, markers: [start])
        #expect(onTheWord?.id == cluster.id)
        let onTheDot = SitPathPlot.clusterAt(clusters: [cluster], x: 100, y: 100, markers: [start])
        #expect(onTheDot?.id == cluster.id)
        let elsewhere = SitPathPlot.clusterAt(clusters: [cluster], x: 160, y: 40, markers: [start])
        #expect(elsewhere == nil)
    }

    @Test func extraAttentionDotsComeFirstAndNeedAFix() {
        let tagged = sighting(
            key: "WIFI:AA:AA:AA:AA:AA:01",
            kind: .wifi,
            mac: "AA:AA:AA:AA:AA:01",
            name: "cam",
            rssi: -50,
            rssiMin: -50,
            rssiMax: -50,
            channel: 6,
            frequencyMhz: 2437,
            firstSeen: 1,
            lastSeen: 1,
            hitCount: 1,
            fleetIds: ["fleet-axon"],
            gpsTrail: [GpsSample(at: 1, lat: 28.78, lon: -81.37)]
        )
        let dots = SitPathPlot.dotsFrom(devices: [tagged], fleets: [axon], namedKeys: [])
        #expect(dots.points.count == 1)
        #expect(dots.points[0].extraAttention)
        #expect(SitPathPlot.layout(
            model: SitPathPlot.Model(
                samples: [
                    GpsSample(at: 1, lat: 28.780, lon: -81.370),
                    GpsSample(at: 2, lat: 28.781, lon: -81.371),
                ],
                dots: dots.points,
                lengthM: 120.0,
                spanM: 100.0,
                title: "plaza"
            ),
            width: 300, height: 200
        ) != nil)
    }

    @Test func sameRadioPlotsOnceAtLoudestHear() {
        let tagged = sighting(
            key: "WIFI:AA:AA:AA:AA:AA:01",
            kind: .wifi,
            mac: "AA:AA:AA:AA:AA:01",
            name: "cam",
            rssi: -40,
            rssiMin: -80,
            rssiMax: -40,
            channel: 6,
            frequencyMhz: 2437,
            firstSeen: 1,
            lastSeen: 3,
            hitCount: 3,
            fleetIds: ["fleet-axon"],
            gpsTrail: [
                GpsSample(at: 1, lat: 28.7800, lon: -81.3700, rssi: -80),
                GpsSample(at: 2, lat: 28.7810, lon: -81.3710, rssi: -42),
                GpsSample(at: 3, lat: 28.7820, lon: -81.3720, rssi: -70),
            ]
        )
        let dots = SitPathPlot.dotsFrom(devices: [tagged, tagged], fleets: [axon], namedKeys: [])
        #expect(dots.points.count == 1)
        #expect(abs(dots.points[0].lat - 28.7810) <= 0.00001)
        #expect(abs(dots.points[0].lon - -81.3710) <= 0.00001)
    }

    @Test func extraAttentionAlongTheWalkIsStillANumberedStop() {
        let tagged = sighting(
            key: "WIFI:AA:AA:AA:AA:AA:01",
            kind: .wifi,
            mac: "AA:AA:AA:AA:AA:01",
            name: "van",
            rssi: -50,
            rssiMin: -60,
            rssiMax: -40,
            channel: 6,
            frequencyMhz: 2437,
            firstSeen: 0,
            lastSeen: 60_000,
            hitCount: 8,
            fleetIds: ["fleet-axon"],
            gpsTrail: [
                GpsSample(at: 0, lat: 28.7800, lon: -81.3700, rssi: -55),
                GpsSample(at: 15_000, lat: 28.7812, lon: -81.3700, rssi: -48),
                GpsSample(at: 30_000, lat: 28.7825, lon: -81.3700, rssi: -40),
                GpsSample(at: 45_000, lat: 28.7837, lon: -81.3700, rssi: -46),
                GpsSample(at: 60_000, lat: 28.7850, lon: -81.3700, rssi: -52),
            ]
        )
        let dots = SitPathPlot.dotsFrom(devices: [tagged], fleets: [axon], namedKeys: [])
        #expect(dots.points.count == 1)
        #expect(dots.points[0].label == "van")
        #expect(dots.points[0].extraAttention)
    }

    @Test func pathPlotsMacAlertsAndSignatureAlerts() {
        let axon7 = with(axon) { $0.colorIndex = 7 }
        let tagged = sighting(
            key: "WIFI:AA:AA:AA:AA:AA:01",
            kind: .wifi,
            mac: "AA:AA:AA:AA:AA:01",
            name: "cam",
            rssi: -50,
            rssiMin: -50,
            rssiMax: -50,
            channel: 6,
            frequencyMhz: 2437,
            firstSeen: 1,
            lastSeen: 1,
            hitCount: 1,
            fleetIds: ["fleet-axon"],
            gpsTrail: [GpsSample(at: 1, lat: 28.78, lon: -81.37)]
        )
        let report = SitPathPlot.dotsFrom(devices: [tagged], fleets: [axon7], namedKeys: [])
        #expect(report.points.count == 1)
        let bare = SitPathPlot.dotsFrom(devices: [tagged], fleets: [axon7], namedKeys: [], alertsOnly: true)
        #expect(bare.points.isEmpty)
        let signature = SitPathPlot.dotsFrom(
            devices: [tagged],
            fleets: [axon7],
            namedKeys: [],
            watchedFleetIds: [axon7.id],
            alertsOnly: true
        )
        #expect(signature.points.count == 1)
        #expect(signature.points[0].classKind == .lawEnforcement)
        #expect(signature.points[0].accentArgb == Palette.color(index: 7))
        let mac = SitPathPlot.dotsFrom(
            devices: [tagged],
            fleets: [axon7],
            namedKeys: [],
            bookmarkedKeys: [tagged.key],
            alertsOnly: true
        )
        #expect(mac.points.count == 1)
        #expect(mac.points[0].named)
        let decoded = with(tagged) {
            $0.payloadLat = 29.5
            $0.payloadLon = -81.37
            $0.payloadTrail = [
                PayloadFix(at: 1, lat: 29.1, lon: -81.37),
                PayloadFix(at: 2, lat: 29.4, lon: -81.37),
            ]
        }
        let pinned = SitPathPlot.dotsFrom(
            devices: [decoded],
            fleets: [axon7],
            namedKeys: [],
            watchedFleetIds: [axon7.id],
            alertsOnly: true
        )
        #expect(abs(pinned.points.single { _ in true }.lat - 29.4) <= 1e-6)
        #expect(pinned.points.single { _ in true }.advertised)
        let letter = SitPathPlot.dotsFrom(devices: [decoded], fleets: [axon7], namedKeys: [])
        #expect(abs(letter.points.single { _ in true }.lat - 28.78) <= 1e-6)
        #expect(!letter.points.single { _ in true }.advertised)
    }

    @Test func bookmarkedRadioIsANumberedStop() {
        let tagged = sighting(
            key: "BLE:AA:AA:AA:AA:AA:02",
            kind: .ble,
            mac: "AA:AA:AA:AA:AA:02",
            name: "Cybertruck",
            rssi: -55,
            rssiMin: -70,
            rssiMax: -40,
            channel: 0,
            frequencyMhz: 2402,
            vendor: "Tesla, Inc.",
            firstSeen: 0,
            lastSeen: 20 * 60_000,
            hitCount: 80,
            fleetIds: [],
            gpsTrail: [0, 5, 10, 15, 20].map { i in
                GpsSample(at: i * 60_000, lat: 28.7800 + Double(i) * 0.01, lon: -81.3700, rssi: -50)
            }
        )
        let dots = SitPathPlot.dotsFrom(
            devices: [tagged], fleets: [axon], namedKeys: [tagged.key],
            bookmarkedKeys: [tagged.key]
        )
        #expect(dots.points.count == 1)
        #expect(dots.points[0].label == "Cybertruck")
        #expect(dots.points[0].named)
    }

    @Test func extraAttentionLeaveAndReturnIsAStop() {
        let tagged = sighting(
            key: "WIFI:AA:AA:AA:AA:AA:03",
            kind: .wifi,
            mac: "AA:AA:AA:AA:AA:03",
            name: "home AP",
            rssi: -40,
            rssiMin: -50,
            rssiMax: -35,
            channel: 6,
            frequencyMhz: 2437,
            firstSeen: 0,
            lastSeen: 20 * 60_000,
            hitCount: 12,
            fleetIds: ["fleet-axon"],
            gpsTrail: [
                GpsSample(at: 0, lat: 28.7800, lon: -81.3700, rssi: -40),
                GpsSample(at: 20 * 60_000, lat: 28.7800, lon: -81.3700, rssi: -42),
            ]
        )
        let dots = SitPathPlot.dotsFrom(devices: [tagged], fleets: [axon], namedKeys: [])
        #expect(dots.points.count == 1)
        #expect(dots.points[0].label == "home AP")
        #expect(dots.points[0].extraAttention)
    }

    @Test func namedWithoutBookmarkIsNotPlotted() {
        let tagged = sighting(
            key: "BLE:AA:AA:AA:AA:AA:05",
            kind: .ble,
            mac: "AA:AA:AA:AA:AA:05",
            name: "tsTPMS",
            rssi: -55,
            rssiMin: -60,
            rssiMax: -50,
            channel: 0,
            frequencyMhz: 2402,
            firstSeen: 0,
            lastSeen: 60_000,
            hitCount: 8,
            fleetIds: [],
            gpsTrail: [GpsSample(at: 0, lat: 28.7800, lon: -81.3700, rssi: -55)]
        )
        let dots = SitPathPlot.dotsFrom(
            devices: [tagged],
            fleets: [],
            namedKeys: [tagged.key],
            observerNotes: [tagged.key: "Saw this at the gate."]
        )
        #expect(dots.points.isEmpty)
    }

    @Test func observerNotesPlotAsNumberedBlueStop() {
        let tagged = sighting(
            key: "BLE:AA:AA:AA:AA:AA:04",
            kind: .ble,
            mac: "AA:AA:AA:AA:AA:04",
            name: "iBeacon",
            rssi: -55,
            rssiMin: -60,
            rssiMax: -50,
            channel: 0,
            frequencyMhz: 2402,
            firstSeen: 0,
            lastSeen: 60_000,
            hitCount: 8,
            fleetIds: [],
            gpsTrail: [
                GpsSample(at: 0, lat: 28.7800, lon: -81.3700, rssi: -55),
                GpsSample(at: 30_000, lat: 28.7825, lon: -81.3700, rssi: -50),
                GpsSample(at: 60_000, lat: 28.7850, lon: -81.3700, rssi: -58),
            ]
        )
        let dots = SitPathPlot.dotsFrom(
            devices: [tagged],
            fleets: [],
            namedKeys: [],
            observerNotes: [tagged.key: "Mall door, same as last week."],
            bookmarkedKeys: [tagged.key]
        )
        #expect(dots.points.count == 1)
        #expect(dots.points[0].named)
        #expect(!dots.points[0].extraAttention)
        #expect(dots.points[0].observerNotes == "Mall door, same as last week.")
    }

    @Test func despikeDropsOutAndBackJump() {
        let a = GpsSample(at: 0, lat: 28.7800, lon: -81.3700)
        let spike = GpsSample(at: 2_000, lat: 28.7950, lon: -81.3700)
        let c = GpsSample(at: 4_000, lat: 28.7802, lon: -81.3700)
        let cleaned = Geo.despikePath(samples: [a, spike, c])
        #expect(cleaned.count == 2)
        #expect(cleaned[0].at == a.at)
        #expect(cleaned[1].at == c.at)
    }

    @Test func despikeKeepsHighwayHop() {
        let a = GpsSample(at: 0, lat: 28.7800, lon: -81.3700)
        let b = GpsSample(at: 10_000, lat: 28.7827, lon: -81.3700)
        let cleaned = Geo.despikePath(samples: [a, b])
        #expect(cleaned.count == 2)
    }

    @Test func capSpreadKeepsFirstAndLast() {
        let samples = (0..<100).map { i in
            GpsSample(at: i * 1_000, lat: 28.78 + Double(i) * 0.001, lon: -81.37)
        }
        let kept = Geo.capSpread(samples: samples, cap: 40)
        #expect(kept.count == 40)
        #expect(kept.first!.at == samples.first!.at)
        #expect(kept.last!.at == samples.last!.at)
        #expect(kept.contains { (20_000...30_000).contains($0.at) })
    }

    @Test func gnssPinSitsOnTheSampleNearestInTime() {
        let path = [
            GpsSample(at: 1_000, lat: 28.7800, lon: -81.3700),
            GpsSample(at: 10_000, lat: 28.7810, lon: -81.3700),
            GpsSample(at: 20_000, lat: 28.7820, lon: -81.3700),
        ]
        let mark = GnssMark(
            at: 11_000,
            endedAt: 16_000,
            kind: "interference",
            confidence: "Medium",
            detail: "GPS L1: AGC -9.0 dB, signal -7.0 dB, 8 satellites (baseline 12)"
        )
        let pin = SitPathPlot.gnssPins(marks: [mark], path: path).single { _ in true }
        #expect(abs(pin.lat - 28.7810) <= 0.00001)
        #expect(abs(pin.lon - -81.3700) <= 0.00001)
        let line = pin.keyLine()
        #expect(line.contains("Possible GNSS interference"))
        #expect(line.contains("Medium"))
        #expect(line.contains("AGC -9.0 dB"))
        #expect(!line.contains("28.781"))
        #expect(!line.contains("latitude", ignoreCase: true))
        #expect(!line.contains("jammer", ignoreCase: true))
        #expect(!line.contains("spoofer", ignoreCase: true))
    }

    @Test func gnssPinNeedsAPathAndNamesSpoofingWithoutAPlace() {
        let mark = GnssMark(at: 5_000, kind: "spoofing", confidence: "High", detail: "  ")
        #expect(SitPathPlot.gnssPins(marks: [mark], path: []).isEmpty)
        let pin = SitPathPlot.gnssPins(
            marks: [mark],
            path: [GpsSample(at: 1_000, lat: 28.7800, lon: -81.3700)]
        ).single { _ in true }
        #expect(pin.title() == "Possible GNSS spoofing")
        #expect(pin.keyLine().contains("Signal changed."))
        #expect(!pin.keyLine().contains("28.7800"))
    }
}
