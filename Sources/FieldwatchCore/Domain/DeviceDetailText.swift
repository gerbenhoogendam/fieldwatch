import Foundation

/// Plain-text dump of the device-detail screen. Same fields, no sparkline/presence art.
/// Not a legal identity.
public enum DeviceDetailText {
    public static func build(
        device: Sighting,
        signatureNames: [String],
        now: Int = nowMs(),
        attentionNotes: [(String, String)] = [],
        signatureNotes: [(String, String)] = [],
        fleets: [Fleet] = [],
        mine: Bool = false
    ) -> String {
        let timeFmt = "HH:mm:ss"
        let facts = device.facts
        let title = device.listTitle(signatureNames: signatureNames)
        let guess = DeviceExplain.guess(device: device, signatureNames: signatureNames)
        var out = ""

        func line(_ label: String, _ value: String) {
            out += label + ": " + value.trim() + "\n"
        }
        func section(_ title: String) {
            out += "\n## " + title + "\n"
        }

        out += "Fieldwatch device detail\n"
        out += formatMs(now, "yyyy-MM-dd HH:mm:ss Z") + "\n"
        out += "Experimental. Not a legal identity. Stock macOS radios — this is what the OS " +
            "exposed, not a guarantee a tracker or camera is present.\n"
        out += "\n"
        out += title + "\n"
        line(MacUtil.isOpaqueId(device.mac) ? "ID" : "MAC", device.mac)
        if device.name.isNotBlank { line("Advertised name", device.name) }
        if mine { line("Marked mine", "No beep while this is on. Still listed.") }

        out += "\n"
        out += "What this looks like: " + guess.headline + "\n"
        out += guess.because + "\n"
        if attentionNotes.isNotEmpty {
            section("Extra attention")
            for (name, note) in attentionNotes {
                out += "EXTRA ATTENTION (\(name)): " + note.trim() + "\n"
            }
            out += "Pattern match, not identity. Not a safety finding.\n"
        }
        if signatureNotes.isNotEmpty {
            section("Notes")
            for (name, note) in signatureNotes {
                out += name + ": " + note.trim() + "\n"
            }
        }

        section("Identity")
        line("Radio", device.kind == .wifi ? "Wi-Fi access point (beaconing a network)" : "Bluetooth Low Energy advertiser")
        line("Address", DeviceExplain.addressExplain(device: device))
        if let v = vendorLine(device) {
            line("Who made it", v.replace("\n", " "))
        } else if MacUtil.isOpaqueId(device.mac) {
            // macOS hides BLE addresses, so there is no OUI to look up.
            line("OUI (vendor prefix)", "None — macOS hides the Bluetooth address, so there is no vendor prefix")
        } else {
            line("OUI (vendor prefix)", "\(device.oui) — no IEEE match; randomized addresses usually have none")
        }
        if device.hiddenSsid {
            line("Network name (SSID)", "Hidden — the AP is beaconing but not publishing a name")
        }

        section("Signal")
        if device.gone {
            line("How loud here (RSSI)", "Not available")
            let last = Rssi.lastMeasured(rssi: device.rssi, history: device.rssiHistory)
            line("Last heard", last.map { "\($0) dBm" } ?? "Not available")
        } else {
            line("How loud here (RSSI)", DeviceExplain.rssiExplain(rssi: device.rssi))
            out += "Closer to 0 dBm is louder here, not a distance.\n"
        }
        line("Heard range this session", Rssi.sessionRange(min: device.rssiMin, max: device.rssiMax, history: device.rssiHistory))
        if let tx = facts.txPowerDbm {
            line("Claimed transmit power", "\(tx) dBm — how loud it says it transmits, not a distance")
        }
        if device.channel != 0 || device.frequencyMhz != 0 {
            var s = ""
            if device.channel != 0 { s += "channel \(device.channel)" }
            if device.frequencyMhz != 0 {
                if s.isNotEmpty { s += "  ·  " }
                s += "\(device.frequencyMhz) MHz"
            }
            if let w = facts.channelWidth { s += "  ·  \(w) wide" }
            line("Channel / frequency", s)
        }
        if let std = facts.wifiStandard { line("Wi-Fi generation", std) }
        if facts.centerFreq0 != nil || facts.centerFreq1 != nil {
            line("Center frequencies", [facts.centerFreq0, facts.centerFreq1].compactMap { $0.map { "\($0) MHz" } }.joined(separator: "  ·  "))
        }
        let rssiTail = device.rssiHistory.filter { Rssi.measured(rssi: $0.rssi) }.takeLast(24)
        if rssiTail.isNotEmpty {
            line("Recent RSSI (oldest → newest)", rssiTail.map { String($0.rssi) }.joined(separator: ", "))
        }

        if device.kind == .ble {
            section("Bluetooth advertisement")
            if let p = facts.primaryPhy {
                let phys = [p, facts.secondaryPhy].compactMap { $0 }.distinct()
                line("Radio PHY", phys.map { DeviceExplain.phyExplain(label: $0) }.joined(separator: " / "))
            }
            if let c = facts.connectable {
                line("Connectable", c ? "Yes — a phone could open a BLE connection"
                    : "No — broadcast-only (you can hear it, not join it from this scan)")
            }
            if let iv = facts.advertisingIntervalMs {
                line("How often it advertises", "\(fmt(iv, 0)) ms between bursts (smaller = chattier on the air)")
            }
            if let p = facts.periodicIntervalMs { line("Periodic advertising", "\(fmt(p, 0)) ms") }
            if let flags = facts.advFlags {
                line("Discoverability", DeviceExplain.flagsExplain(flags: flags))
                line("Flags (raw)", "0x\(hex2(flags))")
            }
            if let value = facts.appearance {
                let name = RadioDb.appearance(value: value)
                line("What it says it is (Appearance)", name ?? "Unlisted Appearance 0x\(hexN(value, 4))")
                line("Appearance code", "0x\(hexN(value, 4))")
            }
            if let cod = CodDecoder.decodeOrNull(cod: facts.deviceClass) {
                var s = cod.major
                if cod.minor.isNotBlank { s += " / " + cod.minor }
                if cod.services.isNotEmpty {
                    s += ". Also offers: "
                    s += cod.services.joined(separator: ", ")
                }
                line("Classic Bluetooth class", s)
            }
        }

        if device.kind == .wifi {
            section("Wi-Fi access point")
            if let sec = facts.security {
                line("Encryption / login", DeviceExplain.wifiSecurityExplain(raw: sec))
                if sec.isNotBlank { line("Security string", sec) }
            }
            if let r = facts.supportedRates { line("Supported rates", "\(r) Mbps  (* = required basic rate)") }
            if let caps = facts.capabilities, caps.isNotBlank, caps != facts.security {
                line("Capability string", caps)
            }
        }

        if let a = device.payloadAircraft?.trim(), a.isNotEmpty { line("Aircraft", a) }

        if fleets.isNotEmpty && (device.kind == .ble || device.kind == .wifi) {
            let decoded = SignatureFieldDecoder.decodeSighting(device: device, fleets: fleets)
            if decoded.isNotEmpty {
                section("Decoded fields")
                for row in decoded {
                    line(row.label, row.display)
                    if row.note.isNotBlank { line("Note", row.note) }
                }
            }
        }

        if device.serviceUuids.isNotEmpty {
            section("Services it offers")
            line("Service IDs", device.serviceUuids.map { uuid in
                DeviceExplain.uuidGloss(uuid: uuid).map { "\(uuid)  ·  \($0)" } ?? uuid
            }.joined(separator: "; "))
        }
        if facts.serviceData.isNotEmpty {
            for sd in facts.serviceData {
                let named = RadioDb.serviceUuid(uuid: sd.uuid).map { " (\($0))" } ?? ""
                for field in AdvPayloadDecoder.decodeService(record: sd) { line(field.label, field.value) }
                line("Service data \(uuidShort(sd.uuid))\(named)", sd.dataHex.hexSpaced().ifBlank("(empty)"))
            }
        }

        let mfg = facts.mfgRecords.ifEmpty(
            device.manufacturerId.map { [MfgRecord(companyId: $0, dataHex: device.manufacturerDataHex)] } ?? []
        )
        if mfg.isNotEmpty {
            section("Maker data inside the ad")
            for rec in mfg {
                let company = RadioDb.company(id: rec.companyId) ?? "Not in the Bluetooth company list"
                line("Bluetooth company 0x\(hexN(rec.companyId, 4))", company)
                for (k, v) in BleAdParser.mfgDecodedFields(record: rec) { line(k, v) }
                if rec.dataHex.isNotBlank {
                    line("Raw payload (\(rec.dataHex.count / 2) bytes)", rec.dataHex.hexSpaced())
                }
            }
        }

        if facts.vendorIes.isNotEmpty || device.vendorIeOuis.isNotEmpty {
            section("Wi-Fi vendor tags")
            let rows = facts.vendorIes.ifEmpty(device.vendorIeOuis.map { VendorIeRecord(oui: $0, type: -1, dataHex: "") })
            for ie in rows {
                let org = RadioDb.vendorForOui24(oui: ie.oui)
                let type = ie.type >= 0 ? " type \(ie.type)" : ""
                var s = org ?? "Unknown IEEE OUI"
                s += " — extra AP information element, not the SSID."
                if ie.dataHex.isNotBlank {
                    s += " "
                    s += ie.dataHex.hexSpaced()
                }
                line("Vendor OUI \(ie.oui)\(type)", s)
            }
        }

        section("Session")
        line("First seen", formatMs(device.firstSeen, timeFmt))
        line("Last seen", formatMs(device.lastSeen, timeFmt))
        line("Hits", String(device.hitCount))
        if let c = Geo.screenCoord(lat: device.latitude, lon: device.longitude, demo: false) {
            line("Last fix", c)
            out += "Last fix is the Mac’s location at hear-time, not a fix on this radio.\n"
        }
        if device.fleetIds.isNotEmpty {
            line("Matched signatures", signatureNames.joined(separator: "; ").ifBlank(device.fleetIds.joined(separator: "; ")))
        }
        if device.rawHex.isNotBlank && device.kind == .ble {
            // macOS has no raw advertisement; the scanner rebuilds AD structures from CoreBluetooth fields.
            line(MacUtil.isOpaqueId(device.mac) ? "Raw advertisement (rebuilt from CoreBluetooth)" : "Raw advertisement",
                 device.rawHex.hexSpaced())
        }
        if let p = presenceLine(device, now, timeFmt) { line("Presence (15 min)", p) }
        return out.trimEnd() + "\n"
    }

    private static func vendorLine(_ device: Sighting) -> String? {
        var parts: [String] = []
        if let v = device.vendor {
            parts.append("IEEE board/chip vendor: \(v) (\(device.oui)). This is who owns the MAC prefix, not always the product brand.")
        }
        if let mfgId = device.facts.mfgRecords.first?.companyId ?? device.manufacturerId {
            let company = RadioDb.company(id: mfgId)
            parts.append("Bluetooth company in the ad: \(company ?? "unlisted") (0x\(hexN(mfgId, 4))).")
        }
        return parts.joined(separator: " ").nonBlank
    }

    private static func uuidShort(_ uuid: String) -> String {
        let hex = uuid.filterAlnum().uppercased()
        return (hex.count >= 8 && hex.hasPrefix("0000")) ? hex.substring(4, 8) : uuid.take(8)
    }

    private static func presenceLine(_ device: Sighting, _ now: Int, _ timeFmt: String) -> String? {
        if device.presence.isEmpty { return nil }
        let from = now - 15 * 60 * 1000
        let spans = device.presence.filter { ($0.end ?? now) >= from }
        if spans.isEmpty { return nil }
        return spans.map { span in
            let start = formatMs(span.start.coerceAtLeast(from), timeFmt)
            let end = span.end.map { formatMs($0, timeFmt) } ?? "now"
            return "\(start)–\(end)"
        }.joined(separator: "; ")
    }
}
