import Foundation

/// Plain-language decode of advertised identity. Guesses are what the radio
/// is broadcasting, not a visual identification.
public enum DeviceExplain {
    public struct Guess: Hashable, Sendable {
        public var headline: String
        public var because: String
        public var confidence: Confidence
        public init(headline: String, because: String, confidence: Confidence) {
            self.headline = headline; self.because = because; self.confidence = confidence
        }
    }

    public enum Confidence: String, CaseIterable, Sendable { case high = "HIGH", medium = "MEDIUM", low = "LOW" }

    public static func guess(device: Sighting, signatureNames: [String]) -> Guess {
        var hints: [Hint] = []
        let appearance = device.facts.appearance.flatMap { RadioDb.appearance(value: $0) }
        if let h = appearanceHint(appearance) { hints.append(h) }
        if let cod = CodDecoder.decodeOrNull(cod: device.facts.deviceClass), let h = codHint(cod) { hints.append(h) }
        hints += uuidHints(device.serviceUuids + device.facts.serviceData.map { $0.uuid })
        hints += AdvPayloadDecoder.roleHints(device: device).map {
            Hint(bucket: $0.bucket, label: $0.label, reason: $0.reason, weight: $0.weight)
        }
        hints += signatureHints(signatureNames)
        if device.kind == .wifi { hints += wifiHints(device, signatureNames) }

        if hints.isEmpty {
            return Guess(
                headline: device.kind == .wifi ? "Wi-Fi access point" : "Bluetooth LE advertiser",
                because: "It is on the air, but it did not advertise a product class " +
                    "(no Appearance, Class of Device, or well-known service that names a type).",
                confidence: .low
            )
        }
        // LinkedHashMap: keep first-insert order of buckets.
        var order: [String] = []
        var grouped: [String: Hint] = [:]
        for hint in hints.sortedByDescending({ $0.weight }) {
            let key = hint.bucket
            if let prev = grouped[key] {
                if hint.weight > prev.weight { grouped[key] = hint }
            } else {
                order.append(key)
                grouped[key] = hint
            }
        }
        let values = order.map { grouped[$0]! }
        // Kotlin maxBy keeps the first maximum.
        var best = values[0]
        for v in values.dropFirst() where v.weight > best.weight { best = v }
        let support = values
            .filter { $0.bucket == best.bucket || $0.weight >= 3 }
            .map { $0.reason }
            .distinct()
        let confidence: Confidence = best.weight >= 6 ? .high : (best.weight >= 3 ? .medium : .low)
        let hedge: String
        switch confidence {
        case .high: hedge = "Most likely"
        case .medium: hedge = "Probably"
        case .low: hedge = "Could be"
        }
        return Guess(
            headline: "\(hedge) \(best.label)",
            because: support.joined(separator: " ") + " This is what the device is advertising, not a visual ID.",
            confidence: confidence
        )
    }

    /// Compact Live-row title from the same guess as detail. Nil if we only
    /// know it is an unnamed advertiser — caller may fall back to vendor.
    public static func listLabel(device: Sighting, signatureNames: [String] = []) -> String? {
        let guess = guess(device: device, signatureNames: signatureNames)
        let generic = guess.headline.contains("Bluetooth LE advertiser", ignoreCase: true) ||
            guess.headline.contains("Wi-Fi access point", ignoreCase: true)
        let core = generic ? nil : tidyHeadline(guess.headline)
        let vendor = device.vendor?.trim().nonBlank.flatMap { $0.utf16.count <= 24 ? $0 : nil }
        if let core {
            if let vendor, !core.contains(vendor, ignoreCase: true) { return "\(vendor) · \(core)" }
            return core
        }
        if let vendor { return "\(vendor) device" }
        return nil
    }

    private static func removePrefix(_ s: String, _ p: String) -> String { s.hasPrefix(p) ? String(s.dropFirst(p.count)) : s }

    private static func tidyHeadline(_ headline: String) -> String {
        var s = removePrefix(removePrefix(removePrefix(headline, "Most likely "), "Probably "), "Could be ").trim()
        s = KRegex("\\s*\\([^)]*\\)").replace(s, "").trim()
        s = removePrefix(removePrefix(s, "an "), "a ").trim()
        if s.isEmpty { return headline }
        guard let f = s.first, f.isLowercase else { return s }
        return String(f).uppercased() + s.dropFirst()
    }

    public static func flagsExplain(flags: Int) -> String {
        var out: [String] = []
        if flags & 0x01 != 0 { out.append("Limited-discoverable: briefly looking for a nearby connection.") }
        if flags & 0x02 != 0 { out.append("Discoverable: other BLE devices can find it.") }
        if flags & 0x04 != 0 {
            out.append("BLE-only: no classic Bluetooth (headsets/file-send radio).")
        } else {
            out.append("May also do classic Bluetooth (BR/EDR) as well as BLE.")
        }
        if flags & 0x08 != 0 || flags & 0x10 != 0 { out.append("Dual-mode chip: BLE and classic can run together.") }
        return out.joined(separator: " ")
    }

    public static func phyExplain(label: String) -> String {
        if label.contains("Coded") { return "\(label) — long-range BLE (slower, farther)" }
        if label.contains("2M") { return "\(label) — faster BLE (Bluetooth 5)" }
        if label.contains("1M") { return "\(label) — standard BLE radio" }
        return label
    }

    public static func addressExplain(device: Sighting) -> String {
        let type = device.facts.addressType
        func typeIs(_ s: String) -> Bool { type?.equals(s, ignoreCase: true) == true }
        if device.kind == .wifi && device.randomized {
            return "Locally administered BSSID. Vehicle, mesh, and guest APs often keep this address. Not a rotating phone MAC."
        }
        // macOS: CoreBluetooth never hands over the BLE address.
        if MacUtil.isOpaqueId(device.mac) {
            return "macOS does not expose Bluetooth addresses. This ID is a per-Mac identifier, not the radio's MAC. It is not a lasting identity."
        }
        if MacUtil.isLocallyAdministered(mac: device.mac) && !device.randomized {
            return "Locally administered address. The local bit is set, so this is not an IEEE factory assignment."
        }
        if typeIs("Public") && !device.randomized { return "Public factory address (stable, IEEE-assigned)." }
        if typeIs("Random") || device.randomized {
            return "Random / privacy address. The MAC can change, so this is not a lasting identity."
        }
        if typeIs("Anonymous") { return "Anonymous: the stack hid the address." }
        return [type, "Universal IEEE address (stable OUI)."].compactMap { $0 }.joined(separator: " · ")
    }

    public static func rssiBand(rssi: Int) -> String {
        if !Rssi.measured(rssi: rssi) { return "not available" }
        if rssi >= -45 { return "very strong" }
        if rssi >= -60 { return "strong" }
        if rssi >= -75 { return "medium" }
        if rssi >= -88 { return "weak" }
        return "very weak"
    }

    public static func rssiExplain(rssi: Int) -> String {
        Rssi.measured(rssi: rssi) ? "\(rssi) dBm · \(rssiBand(rssi: rssi))" : "Not available"
    }

    public static func wifiSecurityExplain(raw: String) -> String {
        var bits: [String] = []
        let u = raw.uppercased()
        if u.contains("SAE") || u.contains("WPA3") { bits.append("WPA3 password (SAE handshake)") }
        else if u.contains("OWE") { bits.append("Enhanced Open (encrypted, no password)") }
        else if u.contains("PSK") && u.contains("WPA2") { bits.append("WPA2 password (PSK)") }
        else if u.contains("PSK") || u.contains("WPA") { bits.append("Wi-Fi password (WPA/PSK)") }
        else if u.contains("802.1X") || u.contains("EAP") { bits.append("Enterprise login (802.1X)") }
        else if u.contains("WEP") { bits.append("WEP (old, weak)") }
        else if u.contains("ESS") && bits.isEmpty { bits.append("Open or encryption not parsed") }
        if u.contains("CCMP") || u.contains("GCMP") { bits.append("AES encryption") }
        else if u.contains("TKIP") { bits.append("TKIP (older, weaker cipher)") }
        if u.contains("WPS") { bits.append("WPS setup is enabled") }
        if u.contains("MESH") { bits.append("mesh node") }
        if u.contains("IBSS") { bits.append("ad-hoc network") }
        if u.contains("ESS") { bits.append("infrastructure access point") }
        return bits.isEmpty ? raw : bits.distinct().joined(separator: ". ") + "."
    }

    public static func uuidGloss(uuid: String) -> String? {
        let name = RadioDb.serviceUuid(uuid: uuid)
        guard let short = uuid16(uuid) else { return name }
        let extra: String?
        switch short {
        case 0x1800: extra = "connection basics"
        case 0x1801: extra = "attribute protocol"
        case 0x180A: extra = "model / serial / firmware"
        case 0x180F: extra = "battery level"
        case 0x1812: extra = "keyboard, mouse, or gamepad"
        case 0x180D: extra = "heart-rate sensor"
        case 0x1810: extra = "blood-pressure sensor"
        case 0x181A: extra = "temperature / humidity style sensor"
        case 0x1844, 0x1845, 0x1846: extra = "LE cycling power/speed"
        case 0x1850, 0x184E, 0x184F: extra = "LE Audio"
        case 0xFE2C: extra = "Google Fast Pair (often buds/speakers)"
        case 0xFD5A: extra = "Samsung SmartTag"
        case 0xFD44: extra = "Apple Find My related"
        case 0xFEED, 0xFEDD, 0xFEEC: extra = "Tile tracker"
        case 0xFEEE: extra = "Polar heart-rate strap or watch"
        case 0xFD50: extra = "Tuya IoT"
        case 0xFEBE, 0xFE21: extra = "Bose"
        case 0xFE78: extra = "HP printer"
        case 0xFE07: extra = "Sonos speaker"
        case 0xFEAF, 0xFEB0: extra = "Nest Weave"
        case 0xFCBF: extra = "ASSA ABLOY Opening Solutions"
        case 0xFE24: extra = "August Home lock"
        case 0xFCF4: extra = "Allegion / Schlage"
        case 0xFCB2: extra = "Apple (not ASSA ABLOY)"
        default: extra = nil
        }
        if let name, let extra { return "\(name) — \(extra)" }
        return name ?? extra
    }

    private struct Hint {
        let bucket: String
        let label: String
        let reason: String
        let weight: Int
        init(bucket: String, label: String, reason: String, weight: Int) {
            self.bucket = bucket; self.label = label; self.reason = reason; self.weight = weight
        }
        init(_ bucket: String, _ label: String, _ reason: String, _ weight: Int) {
            self.init(bucket: bucket, label: label, reason: reason, weight: weight)
        }
    }

    private static func appearanceHint(_ name: String?) -> Hint? {
        guard let name, !name.isBlank, !name.equals("Unknown", ignoreCase: true) else { return nil }
        let n = name.lowercased()
        func has(_ s: String) -> Bool { n.contains(s) }
        let t: (String, String, Int)
        if has("ear") || has("headphone") || has("headset") || has("hearable") || has("hearing") {
            t = ("audio-personal", "earbuds or headphones", 7)
        } else if has("speaker") || has("loudspeaker") || has("hifi") {
            t = ("audio-speaker", "a speaker", 7)
        } else if has("mouse") { t = ("mouse", "a mouse", 8) }
        else if has("keyboard") { t = ("keyboard", "a keyboard", 8) }
        else if has("gamepad") || has("joystick") { t = ("gamepad", "a game controller", 7) }
        else if has("watch") { t = ("watch", "a watch or wrist wearable", 7) }
        else if has("phone") { t = ("phone", "a phone", 6) }
        else if has("laptop") || has("computer") || has("desktop") || has("tablet") {
            t = ("computer", "a computer or tablet", 6)
        } else if has("tag") || has("keyring") { t = ("tag", "a finder tag / tracker", 6) }
        else if has("remote") { t = ("remote", "a remote control", 6) }
        else if has("hid") { t = ("hid", "an input device (keyboard, mouse, or similar)", 4) }
        else if has("heart") { t = ("health", "a heart-rate monitor", 7) }
        else if has("glucose") || has("oximeter") || has("blood pressure") || has("thermometer") {
            t = ("health", "a health sensor", 6)
        } else if has("display") || has("monitor") { t = ("display", "a display or TV stick", 4) }
        else if has("clock") { t = ("clock", "a clock", 5) }
        else if has("glasses") { t = ("glasses", "smart glasses", 6) }
        else { t = ("other", name, 3) }
        return Hint(t.0, t.1, "It advertises Appearance as \(name).", t.2)
    }

    private static func codHint(_ cod: CodDecoder.Decoded) -> Hint? {
        let minor = cod.minor.lowercased()
        let major = cod.major.lowercased()
        let t: (String, String, Int)
        if minor.contains("headphone") || minor.contains("headset") || minor.contains("hands-free") {
            t = ("audio-personal", "earbuds or a headset", 6)
        } else if minor.contains("loudspeaker") || minor.contains("portable audio") || minor.contains("hifi") || minor.contains("car audio") {
            t = ("audio-speaker", "a speaker", 6)
        } else if minor.contains("pointing") || minor == "mouse" { t = ("mouse", "a mouse", 7) }
        else if minor.contains("keyboard") { t = ("keyboard", "a keyboard", 7) }
        else if minor.contains("gamepad") || minor.contains("joystick") { t = ("gamepad", "a game controller", 6) }
        else if minor.contains("smartphone") || (major == "phone" && !minor.contains("uncategorized")) {
            t = ("phone", "a phone", 5)
        } else if minor.contains("laptop") || minor.contains("tablet") || minor.contains("desktop") {
            t = ("computer", "a computer", 5)
        } else if minor.contains("wristwatch") { t = ("watch", "a watch", 6) }
        else if minor.contains("heart") || minor.contains("pulse") || minor.contains("glucose") || minor.contains("oximeter") {
            t = ("health", "a health sensor", 6)
        } else if major.contains("audio") { t = ("audio-personal", "an audio device", 3) }
        else if major.contains("peripheral") { t = ("hid", "an input accessory", 3) }
        else { return nil }
        let shown = (cod.minor.isNotBlank && cod.minor != "Uncategorized") ? "\(cod.major) / \(cod.minor)" : cod.major
        return Hint(t.0, t.1, "Class of Device says \(shown).", t.2)
    }

    private static func uuidHints(_ uuids: [String]) -> [Hint] {
        var out: [Hint] = []
        for uuid in uuids {
            guard let id = uuid16(uuid) else { continue }
            switch id {
            case 0x1812: out.append(Hint("hid", "a keyboard, mouse, or gamepad", "It offers the HID (human-interface) service.", 5))
            case 0x1108, 0x1112, 0x111E, 0x110B, 0x110A, 0x1131, 0x1203:
                out.append(Hint("audio-personal", "headphones, a headset, or a speaker", "It offers a classic audio / headset service.", 5))
            case 0x184E, 0x184F, 0x1850, 0x1851:
                out.append(Hint("audio-personal", "LE Audio earbuds or a speaker", "It offers Bluetooth LE Audio services.", 6))
            case 0x180D: out.append(Hint("health", "a heart-rate monitor", "It offers the Heart Rate service.", 6))
            case 0x1810: out.append(Hint("health", "a blood-pressure monitor", "It offers the Blood Pressure service.", 6))
            case 0x181A: out.append(Hint("sensor", "an environmental sensor", "It offers Environmental Sensing.", 4))
            case 0xFE2C: out.append(Hint("audio-personal", "earbuds or a speaker", "Google Fast Pair is present (common on buds and speakers).", 4))
            case 0xFD5A: out.append(Hint("tag", "a Samsung SmartTag", "SmartTag service UUID.", 7))
            case 0xFD44: out.append(Hint("tag", "an Apple Find My accessory", "Find My related UUID.", 6))
            case 0xFEED, 0xFEDD, 0xFEEC: out.append(Hint("tag", "a Tile tracker", "Tile service UUID.", 7))
            case 0xFEEE: out.append(Hint("wearable", "a Polar heart-rate strap or watch", "Polar service UUID.", 7))
            default: break
            }
        }
        return out
    }

    private static func signatureHints(_ names: [String]) -> [Hint] {
        names.compactMap { signatureHint($0) }
    }

    private static func signatureHint(_ raw: String) -> Hint? {
        if isGenericSignatureName(raw) { return nil }
        let n = raw.lowercased()
        if n.contains("airtag") || n == "find my" || n.contains("find hub") || n.contains("dult") {
            let label: String
            if n.contains("dult") { label = "a DULT finder tag" }
            else if n.contains("find hub") { label = "a Google Find Hub tag" }
            else { label = "an Apple AirTag / Find My tag" }
            return Hint("tag", label, "Matched signature \(raw).", 8)
        }
        if n.contains("apple device") { return Hint("phone", "an iPhone, iPad, or Mac", "Matched signature \(raw).", 7) }
        if n.contains("apple audio") { return Hint("audio-personal", "AirPods, Beats, or AirPlay", "Matched signature \(raw).", 7) }
        if n.contains("microsoft") { return Hint("computer", "a Windows / Surface / Xbox radio", "Matched signature \(raw).", 6) }
        if n == "tesla tstpms" { return Hint("vehicle", "a Tesla BLE tire sensor", "Matched signature \(raw).", 7) }
        if n.contains("tpms") || n == "tirecheck" || n == "sytpms" { return Hint("vehicle", "a BLE tire-pressure sensor", "Matched signature \(raw).", 7) }
        if n == "vuzix" { return Hint("glasses", "Vuzix smart glasses", "Matched signature \(raw).", 7) }
        if n == "tesla" { return Hint("vehicle", "a Tesla vehicle (including Cybertruck) or phone-as-key", "Matched signature \(raw).", 7) }
        if n == "google" { return Hint("phone", "a Pixel or other Google radio", "Matched signature \(raw).", 6) }
        if n == "sony" { return Hint("audio-personal", "Sony headphones, a TV, or a camera", "Matched signature \(raw).", 6) }
        if n == "bose" { return Hint("audio-personal", "Bose headphones or a speaker", "Matched signature \(raw).", 7) }
        if n == "garmin" { return Hint("watch", "a Garmin watch or inReach", "Matched signature \(raw).", 7) }
        if n == "amazon" { return Hint("speaker", "an Echo, Fire, or other Amazon radio", "Matched signature \(raw).", 6) }
        if n == "fitbit" { return Hint("watch", "a Fitbit", "Matched signature \(raw).", 7) }
        if n == "oura" { return Hint("wearable", "an Oura ring", "Matched signature \(raw).", 7) }
        if n == "logitech" { return Hint("hid", "a Logitech mouse, keyboard, or webcam", "Matched signature \(raw).", 6) }
        if n.contains("jbl") || n == "harman" { return Hint("audio-personal", "JBL or Harman audio", "Matched signature \(raw).", 6) }
        if n == "sonos" { return Hint("audio-speaker", "a Sonos speaker", "Matched signature \(raw).", 7) }
        if n == "gopro" { return Hint("camera", "a GoPro", "Matched signature \(raw).", 7) }
        if n == "osmo" { return Hint("camera", "a DJI Osmo action camera", "Matched signature \(raw).", 7) }
        if n == "insta360" { return Hint("camera", "an Insta360 camera", "Matched signature \(raw).", 7) }
        if n == "dji power" { return Hint("iot", "a DJI Power station", "Matched signature \(raw).", 7) }
        if n == "dji" { return Hint("drone", "a DJI drone or controller", "Matched signature \(raw).", 7) }
        if n == "remote id" { return Hint("drone", "a drone broadcasting ASTM Remote ID", "Matched signature \(raw).", 8) }
        if n == "skydio" { return Hint("drone", "a Skydio drone", "Matched signature \(raw).", 7) }
        if n == "autel" { return Hint("drone", "an Autel drone", "Matched signature \(raw).", 7) }
        if n == "parrot" { return Hint("drone", "a Parrot ANAFI or Bebop drone", "Matched signature \(raw).", 7) }
        if n == "hoverair" { return Hint("drone", "a HOVERAir flying camera", "Matched signature \(raw).", 7) }
        if n == "netgear" || n == "orbi" { return Hint("ap", "a NETGEAR or Orbi access point", "Matched signature \(raw).", 6) }
        if n == "tp-link" { return Hint("ap", "a TP-Link access point", "Matched signature \(raw).", 6) }
        if n == "asus" { return Hint("ap", "an ASUS access point", "Matched signature \(raw).", 6) }
        if n == "linksys" { return Hint("ap", "a Linksys or Velop access point", "Matched signature \(raw).", 6) }
        if n == "eero" { return Hint("ap", "an Eero mesh node", "Matched signature \(raw).", 6) }
        if n == "google wifi" { return Hint("ap", "a Google Wifi or Nest Wifi point", "Matched signature \(raw).", 6) }
        if n == "d-link" { return Hint("ap", "a D-Link access point", "Matched signature \(raw).", 6) }
        if n == "belkin" { return Hint("ap", "a Belkin access point", "Matched signature \(raw).", 6) }
        if n == "xfinity" { return Hint("ap", "an Xfinity gateway or hotspot", "Matched signature \(raw).", 6) }
        if n == "spectrum" { return Hint("ap", "a Spectrum gateway or Spectrum Mobile hotspot", "Matched signature \(raw).", 6) }
        if n == "at&t" { return Hint("ap", "an AT&T gateway or attwifi hotspot", "Matched signature \(raw).", 6) }
        if n == "verizon" { return Hint("ap", "a Verizon or Fios gateway", "Matched signature \(raw).", 6) }
        if n == "starlink" { return Hint("ap", "a Starlink router", "Matched signature \(raw).", 7) }
        if n == "meraki" { return Hint("ap", "a Cisco Meraki access point", "Matched signature \(raw).", 7) }
        if n == "cisco" { return Hint("ap", "a Cisco Aironet, Catalyst, Business, RV, or SPVTG access point", "Matched signature \(raw).", 7) }
        if n == "mist" { return Hint("ap", "a Juniper Mist access point", "Matched signature \(raw).", 7) }
        if n == "t-mobile" { return Hint("ap", "a T-Mobile Home Internet gateway or hotspot", "Matched signature \(raw).", 6) }
        if n == "humax" { return Hint("ap", "a HUMAX gateway (often T-Mobile Home Internet)", "Matched signature \(raw).", 6) }
        if n == "sagemcom" { return Hint("ap", "a Sagemcom ISP gateway", "Matched signature \(raw).", 6) }
        if n == "arcadyan" { return Hint("ap", "an Arcadyan ISP gateway", "Matched signature \(raw).", 6) }
        if n == "askey" { return Hint("ap", "an Askey ISP / 5G gateway", "Matched signature \(raw).", 6) }
        if n == "calix" { return Hint("ap", "a Calix fiber gateway", "Matched signature \(raw).", 6) }
        if n == "nokia" { return Hint("ap", "a Nokia Solutions and Networks gateway", "Matched signature \(raw).", 6) }
        if n == "airties" { return Hint("ap", "an AirTies ISP mesh node", "Matched signature \(raw).", 6) }
        if n == "tenda" { return Hint("ap", "a Tenda access point", "Matched signature \(raw).", 6) }
        if n == "ruijie" { return Hint("ap", "a Ruijie or Reyee access point", "Matched signature \(raw).", 6) }
        if n == "dwnet" { return Hint("ap", "a DWnet access point", "Matched signature \(raw).", 6) }
        if n == "wavlink" { return Hint("ap", "a WAVLINK access point", "Matched signature \(raw).", 6) }
        if n == "sercomm" { return Hint("ap", "a Sercomm ISP gateway", "Matched signature \(raw).", 6) }
        if n == "luxul" { return Hint("ap", "a Luxul access point", "Matched signature \(raw).", 6) }
        if n == "sophos" { return Hint("ap", "a Sophos firewall or access point", "Matched signature \(raw).", 7) }
        if n == "aumovio" { return Hint("hotspot", "an AUMOVIO / Continental vehicle Wi-Fi radio", "Matched signature \(raw).", 6) }
        if n == "centurylink" { return Hint("ap", "a CenturyLink gateway", "Matched signature \(raw).", 6) }
        if n == "gm hotspot" { return Hint("hotspot", "a GM in-car hotspot (Cadillac / GMC / Buick / Chevrolet)", "Matched signature \(raw).", 6) }
        if n == "audi mmi" { return Hint("hotspot", "an Audi MMI in-car hotspot", "Matched signature \(raw).", 6) }
        if n == "extreme" { return Hint("ap", "an Extreme Networks access point", "Matched signature \(raw).", 7) }
        if n == "adtran" { return Hint("ap", "an Adtran fiber gateway (often CenturyLink / Quantum Fiber OEM)", "Matched signature \(raw).", 6) }
        if n == "cambium" { return Hint("ap", "a Cambium or IgniteNet access point", "Matched signature \(raw).", 6) }
        if n == "trendnet" { return Hint("ap", "a TRENDnet access point", "Matched signature \(raw).", 6) }
        if n == "cudy" { return Hint("ap", "a Cudy travel or home router", "Matched signature \(raw).", 6) }
        if n == "snapav" { return Hint("ap", "a SnapAV / Control4 / Wattbox access point", "Matched signature \(raw).", 6) }
        if n == "arlo" { return Hint("camera", "an Arlo camera or VMB base station", "Matched signature \(raw).", 6) }
        if n == "vantiva" { return Hint("ap", "a Vantiva or Technicolor ISP gateway", "Matched signature \(raw).", 6) }
        if n == "hitron" { return Hint("ap", "a Hitron cable gateway (often Xfinity OEM)", "Matched signature \(raw).", 6) }
        if n == "actiontec" { return Hint("ap", "an Actiontec FiOS or Frontier gateway", "Matched signature \(raw).", 6) }
        if n == "buffalo" { return Hint("ap", "a Buffalo AirStation or router", "Matched signature \(raw).", 6) }
        if n == "grandstream" { return Hint("ap", "a Grandstream GWN access point", "Matched signature \(raw).", 6) }
        if n == "edgecore" { return Hint("ap", "an Edgecore access point", "Matched signature \(raw).", 7) }
        if n == "watchguard ap" { return Hint("ap", "a WatchGuard firewall or access point", "Matched signature \(raw).", 7) }
        if n == "mojo" { return Hint("ap", "a Mojo Networks / Arista Cognitive Wi-Fi access point", "Matched signature \(raw).", 7) }
        if n == "winegard" { return Hint("hotspot", "a Winegard RV or marine Wi-Fi radio", "Matched signature \(raw).", 6) }
        if n == "inseego" { return Hint("ap", "an Inseego 5G or MiFi hotspot", "Matched signature \(raw).", 6) }
        if n == "franklin" { return Hint("ap", "a Franklin Technology 5G home-internet gateway (RG3100 class)", "Matched signature \(raw).", 6) }
        if n == "synology" { return Hint("ap", "a Synology NAS or router access point", "Matched signature \(raw).", 6) }
        if n == "aruba" { return Hint("ap", "an HPE Aruba Instant or Instant On access point", "Matched signature \(raw).", 7) }
        if n == "ruckus" { return Hint("ap", "a RUCKUS access point", "Matched signature \(raw).", 7) }
        if n == "fortinet" { return Hint("ap", "a Fortinet FortiAP or FortiWiFi", "Matched signature \(raw).", 7) }
        if n == "mikrotik" { return Hint("ap", "a MikroTik router or access point", "Matched signature \(raw).", 6) }
        if n == "engenius" { return Hint("ap", "an EnGenius access point", "Matched signature \(raw).", 6) }
        if n == "zyxel" { return Hint("ap", "a Zyxel gateway or access point", "Matched signature \(raw).", 6) }
        if n == "peplink" { return Hint("ap", "a Peplink or Pepwave router", "Matched signature \(raw).", 6) }
        if n == "openwrt" { return Hint("ap", "an OpenWrt router", "Matched signature \(raw).", 6) }
        if n == "arris" { return Hint("ap", "an Arris or SURFboard cable gateway", "Matched signature \(raw).", 6) }
        if n == "unifi ap" { return Hint("ap", "a Ubiquiti UniFi access point", "Matched signature \(raw).", 7) }
        if n == "unifi protect" { return Hint("camera", "a UniFi Protect Instant camera", "Matched signature \(raw).", 7) }
        if n == "unifi" { return Hint("ap", "a UniFi / Ubiquiti name", "Matched signature \(raw).", 5) }
        if n == "ecobee" { return Hint("thermostat", "an ecobee thermostat", "Matched signature \(raw).", 7) }
        if n == "sensi" { return Hint("thermostat", "a Sensi thermostat", "Matched signature \(raw).", 6) }
        if n == "honeywell home" { return Hint("thermostat", "a Honeywell Home or Lyric thermostat", "Matched signature \(raw).", 6) }
        if n.contains("honeywell xenon") { return Hint("health", "a Honeywell Xenon healthcare barcode scanner", "Matched signature \(raw).", 7) }
        if n == "omron" { return Hint("health", "an Omron blood-pressure cuff or scale", "Matched signature \(raw).", 7) }
        if n == "withings" { return Hint("health", "a Withings scale or blood-pressure monitor", "Matched signature \(raw).", 7) }
        if n == "dexcom" { return Hint("health", "a Dexcom glucose sensor", "Matched signature \(raw).", 7) }
        if n == "nest thermostat" { return Hint("thermostat", "a Nest thermostat or Nest Labs BLE sensor", "Matched signature \(raw).", 6) }
        if n == "nest weave" { return Hint("sensor", "a Nest Protect, camera, or other Weave BLE device", "Matched signature \(raw).", 7) }
        if n == "haiku fan" || n == "haiku" { return Hint("fan", "a Haiku or Mammoth ceiling fan", "Matched signature \(raw).", 7) }
        if n == "tuya" { return Hint("iot", "a Tuya BLE gadget (plug, light, camera, sensor)", "Matched signature \(raw).", 6) }
        if n == "seos" || n == "assa abloy" { return Hint("access", "an ASSA ABLOY lock, Yale lock, HID reader, or Seos credential", "Matched signature \(raw).", 7) }
        if n == "august" { return Hint("lock", "an August smart lock", "Matched signature \(raw).", 7) }
        if n == "schlage" { return Hint("lock", "a Schlage or Allegion lock", "Matched signature \(raw).", 7) }
        if n == "nuki" { return Hint("lock", "a Nuki lock or opener", "Matched signature \(raw).", 7) }
        if n == "salto" { return Hint("access", "a SALTO access reader or lock", "Matched signature \(raw).", 7) }
        if n == "dormakaba" { return Hint("access", "a dormakaba, Saflok, or Oracode lock", "Matched signature \(raw).", 7) }
        if n == "lockly" { return Hint("lock", "a Lockly smart lock", "Matched signature \(raw).", 6) }
        if n == "kevo" { return Hint("lock", "a Kwikset Kevo or Unikey lock", "Matched signature \(raw).", 7) }
        if n == "master lock" { return Hint("lock", "a Master Lock padlock", "Matched signature \(raw).", 7) }
        if n == "igloohome" { return Hint("lock", "an igloohome lock or keybox", "Matched signature \(raw).", 7) }
        if n == "tedee" { return Hint("lock", "a Tedee smart lock", "Matched signature \(raw).", 7) }
        if n == "paxton" { return Hint("access", "a Paxton reader or Net2 access point", "Matched signature \(raw).", 7) }
        if n == "kwikset" { return Hint("lock", "a Kwikset lock", "Matched signature \(raw).", 6) }
        if n == "myq" { return Hint("garage", "a Chamberlain myQ garage hub", "Matched signature \(raw).", 7) }
        if n == "chevrolet hotspot" { return Hint("hotspot", "a Chevrolet in-car Wi-Fi hotspot", "Matched signature \(raw).", 7) }
        if n == "rivian" { return Hint("vehicle", "a Rivian vehicle, phone key, or sensor", "Matched signature \(raw).", 7) }
        if n == "ford" { return Hint("vehicle", "a Ford or Lincoln vehicle or phone-as-key", "Matched signature \(raw).", 7) }
        if n == "honda" { return Hint("vehicle", "a Honda or Acura vehicle or phone-as-key", "Matched signature \(raw).", 7) }
        if n == "hyundai" { return Hint("vehicle", "a Hyundai or Genesis vehicle or phone-as-key", "Matched signature \(raw).", 7) }
        if n == "toyota" { return Hint("vehicle", "a Toyota or Lexus vehicle or phone-as-key", "Matched signature \(raw).", 7) }
        if n == "nissan" { return Hint("vehicle", "a Nissan or Infiniti vehicle or phone-as-key", "Matched signature \(raw).", 7) }
        if n == "subaru" { return Hint("vehicle", "a Subaru vehicle or phone-as-key", "Matched signature \(raw).", 7) }
        if n == "bmw" { return Hint("vehicle", "a BMW vehicle, phone-as-key, or factory hotspot", "Matched signature \(raw).", 7) }
        if n == "volkswagen" { return Hint("vehicle", "a Volkswagen vehicle or phone-as-key", "Matched signature \(raw).", 7) }
        if n == "porsche" { return Hint("vehicle", "a Porsche vehicle or phone-as-key", "Matched signature \(raw).", 7) }
        if n == "jaguar land rover" { return Hint("vehicle", "a Jaguar, Land Rover, or Range Rover", "Matched signature \(raw).", 7) }
        if n == "byd" { return Hint("vehicle", "a BYD vehicle or phone-as-key", "Matched signature \(raw).", 7) }
        if n == "govee" { return Hint("light", "a Govee light or sensor", "Matched signature \(raw).", 6) }
        if n == "hp" { return Hint("printer", "an HP printer", "Matched signature \(raw).", 6) }
        if n == "epson" { return Hint("printer", "an Epson EcoTank or WorkForce printer", "Matched signature \(raw).", 6) }
        if n == "lg webos tv" { return Hint("tv", "an LG webOS TV", "Matched signature \(raw).", 7) }
        if n == "roku" { return Hint("tv", "a Roku streaming stick or Roku TV (often a hidden Wi-Fi Direct remote AP)", "Matched signature \(raw).", 7) }
        if n == "samsung appliance" { return Hint("iot", "a Samsung fridge, range, oven, or cooktop (setup AP)", "Matched signature \(raw).", 6) }
        if n == "ecowater" { return Hint("iot", "an EcoWater water softener (setup AP)", "Matched signature \(raw).", 6) }
        if n == "nespresso" { return Hint("iot", "a Nespresso coffee machine", "Matched signature \(raw).", 7) }
        if n == "radiacode" { return Hint("sensor", "a RadiaCode radiation detector", "Matched signature \(raw).", 7) }
        if n == "shokz" { return Hint("audio-personal", "Shokz OpenRun or OpenFit headphones", "Matched signature \(raw).", 7) }
        if n == "mercedes mbux" { return Hint("hotspot", "a Mercedes MBUX in-car hotspot", "Matched signature \(raw).", 7) }
        if n == "motive" { return Hint("hotspot", "a Motive / KeepTruckin fleet ELD hotspot", "Matched signature \(raw).", 6) }
        if n == "peoplenet" { return Hint("hotspot", "a PeopleNet fleet ELD hotspot", "Matched signature \(raw).", 6) }
        if n == "uconnect" { return Hint("hotspot", "a Uconnect in-car hotspot", "Matched signature \(raw).", 6) }
        if n == "carplay" { return Hint("hotspot", "a CarPlay in-car hotspot", "Matched signature \(raw).", 6) }
        if n == "cradlepoint" { return Hint("hotspot", "a Cradlepoint vehicle router (often public-safety / fleet)", "Matched signature \(raw).", 7) }
        if n == "airlink" { return Hint("hotspot", "a Sierra Wireless AirLink vehicle gateway", "Matched signature \(raw).", 7) }
        if n == "compex" { return Hint("hotspot", "a Compex access point (sometimes public-safety / fleet)", "Matched signature \(raw).", 6) }
        if n == "novatel wireless" { return Hint("hotspot", "a Novatel Wireless / Inseego vehicle radio", "Matched signature \(raw).", 6) }
        if n == "utility inc" { return Hint("hotspot", "a Utility, Inc vehicle or public-safety radio", "Matched signature \(raw).", 6) }
        if n.contains("gl.inet") || n == "glinet" { return Hint("ap", "a GL.iNet travel router", "Matched signature \(raw).", 6) }
        if n.contains("smarttag") { return Hint("tag", "a Samsung SmartTag", "Matched signature \(raw).", 8) }
        if n.contains("tile") { return Hint("tag", "a Tile tracker", "Matched signature \(raw).", 8) }
        if n == "ibeacon" { return Hint("beacon", "an iBeacon", "Matched signature \(raw).", 7) }
        if n.contains("atrius") { return Hint("beacon", "an Atrius cart tag", "Matched signature \(raw).", 8) }
        if n == "minew" { return Hint("beacon", "a Minew BLE beacon or sensor", "Matched signature \(raw).", 7) }
        if n == "estimote" { return Hint("beacon", "an Estimote beacon", "Matched signature \(raw).", 7) }
        if n == "kontakt.io" || n == "kontakt" { return Hint("beacon", "a Kontakt.io beacon", "Matched signature \(raw).", 7) }
        if n.contains("bluetoad") { return Hint("roadside", "an Iteris BlueTOAD / Vantage Velocity roadside Bluetooth travel-time reader", "Matched signature \(raw).", 7) }
        if n.contains("bliptrack") { return Hint("roadside", "a BLIP Systems BlipTrack roadside travel-time sensor", "Matched signature \(raw).", 7) }
        if n.contains("raven") || n.contains("shotspotter") || n.contains("soundthinking") { return Hint("acoustic", "a Flock Raven or ShotSpotter acoustic gunshot sensor", "Matched signature \(raw).", 8) }
        if n.contains("digital ally") { return Hint("camera", "a Digital Ally body-worn or in-car camera", "Matched signature \(raw).", 8) }
        if n.contains("reveal media") || n.contains("bodyworn") { return Hint("camera", "a Reveal Media body-worn camera", "Matched signature \(raw).", 8) }
        if n == "wolfcom" { return Hint("camera", "a Wolfcom body-worn or in-car camera", "Matched signature \(raw).", 8) }
        if n.contains("i-pro") || n.contains("arbitrator") { return Hint("camera", "a Panasonic i-PRO camera or Arbitrator in-car system", "Matched signature \(raw).", 8) }
        if n.contains("limitless") { return Hint("wearable", "a Limitless Pendant conversation recorder", "Matched signature \(raw).", 8) }
        if n == "bee pendant" || n.contains("bee pioneer") { return Hint("wearable", "a Bee Pioneer wearable recorder", "Matched signature \(raw).", 8) }
        if n == "omi" || n.contains("openglass") { return Hint("wearable", "an Omi pendant or OpenGlass camera glasses", "Matched signature \(raw).", 8) }
        if n.contains("friend pendant") { return Hint("wearable", "a Friend Pendant necklace", "Matched signature \(raw).", 8) }
        if n.contains("brilliant frame") { return Hint("glasses", "Brilliant Labs Frame AR glasses", "Matched signature \(raw).", 8) }
        if n == "even g1" { return Hint("glasses", "Even Realities G1 glasses", "Matched signature \(raw).", 8) }
        if n.contains("hayden") { return Hint("camera", "a Hayden AI bus- or vehicle-mounted camera", "Matched signature \(raw).", 8) }
        if n.contains("miovision") { return Hint("camera", "a Miovision intersection traffic camera", "Matched signature \(raw).", 8) }
        if n == "tattile" { return Hint("camera", "a Tattile plate reader", "Matched signature \(raw).", 8) }
        if n.contains("lvt") || n.contains("liveview") { return Hint("camera", "an LVT / LiveView solar surveillance trailer", "Matched signature \(raw).", 8) }
        if n.contains("hanwha") || n.contains("wisenet") { return Hint("camera", "a Hanwha Vision / Wisenet camera", "Matched signature \(raw).", 7) }
        if n == "uniview" { return Hint("camera", "a Uniview / UNV camera", "Matched signature \(raw).", 7) }
        if n == "rhombus" { return Hint("camera", "a Rhombus cloud camera", "Matched signature \(raw).", 7) }
        if n == "meshcore" { return Hint("mesh", "a MeshCore LoRa companion radio", "Matched signature \(raw).", 7) }
        if n.contains("gotenna") { return Hint("mesh", "a goTenna Mesh or Pro radio", "Matched signature \(raw).", 7) }
        if n == "sensecap" { return Hint("mesh", "a SenseCAP LoRaWAN / Helium gateway", "Matched signature \(raw).", 7) }
        if n.contains("wisgate") || n == "rak wisgate" { return Hint("mesh", "a RAK WisGate LoRaWAN gateway", "Matched signature \(raw).", 7) }
        if n == "ghostesp" { return Hint("pentest", "a GhostESP ESP32 audit board", "Matched signature \(raw).", 7) }
        if n == "bruce" { return Hint("pentest", "a Bruce ESP32 pentest board", "Matched signature \(raw).", 7) }
        if n == "liteon camera radio" { return Hint("module", "a camera-module radio (LiteOn or similar)", "Matched signature \(raw).", 3) }
        if n.contains("chipolo") || n.contains("pebblebee") || n.contains("moto tag") { return Hint("tag", "a finder tag", "Matched signature \(raw).", 7) }
        if n.contains("airpods") { return Hint("audio-personal", "AirPods", "Matched signature \(raw).", 8) }
        return Hint("named", raw, "Matched signature \(raw).", 7)
    }

    private static func isGenericSignatureName(_ name: String) -> Bool {
        let n = name.trim()
        return n.equals("Unknown Signature", ignoreCase: true) || n.equals("Unknown Fleet", ignoreCase: true)
    }

    private static func wifiHints(_ device: Sighting, _ signatureNames: [String]) -> [Hint] {
        let name = device.name
        let caps = (device.facts.capabilities ?? "").uppercased()
        let specific = signatureNames.contains { !isGenericSignatureName($0) }
        var out: [Hint] = []
        if name.startsWith("DIRECT-", ignoreCase: true) {
            out.append(specific
                ? Hint("wifi-direct", "a Wi-Fi Direct access point", "SSID starts with DIRECT-.", 4)
                : Hint("wifi-direct", "a phone or TV using Wi-Fi Direct", "SSID starts with DIRECT-.", 6))
        } else if name.startsWith("ANDROID-", ignoreCase: true) || name.contains("hotspot", ignoreCase: true) {
            if !specific { out.append(Hint("hotspot", "a phone hotspot", "SSID looks like a phone hotspot.", 6)) }
        } else if caps.contains("MESH") {
            out.append(Hint("mesh", "a mesh Wi-Fi node", "Capability list includes mesh.", 5))
        } else if device.hiddenSsid {
            out.append(Hint("ap", "a hidden Wi-Fi access point", "SSID is hidden; the radio is still beaconing.", 4))
        } else if !specific {
            out.append(Hint("ap", "a Wi-Fi access point", "macOS only reports beaconing APs.", 3))
        }
        return out
    }

    private static func uuid16(_ uuid: String) -> Int? {
        let hex = uuid.filterAlnum().uppercased()
        if hex.count == 4 { return hex.toIntOrNull(16) }
        if hex.count == 32 && hex.hasPrefix("0000") && hex.hasSuffix("00001000800000805F9B34FB") {
            return hex.substring(4, 8).toIntOrNull(16)
        }
        if hex.count == 8 { return hex.takeLast(4).toIntOrNull(16) }
        return nil
    }
}
