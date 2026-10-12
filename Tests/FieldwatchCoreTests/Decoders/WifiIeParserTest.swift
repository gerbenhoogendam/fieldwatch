import Foundation
import Testing
@testable import FieldwatchCore

struct WifiIeParserTest {
    private func ie(_ id: Int, _ data: Int...) -> WifiIeParser.Ie {
        WifiIeParser.Ie(id: id, bytes: data.map { UInt8(truncatingIfNeeded: $0) })
    }

    /// Raw CoreWLAN-style blob: [id, len, data...] per element.
    private func blob(_ ies: WifiIeParser.Ie...) -> [UInt8] {
        ies.flatMap { [UInt8($0.id), UInt8($0.bytes.count)] + $0.bytes }
    }

    private var wpa2CcmpPsk: WifiIeParser.Ie {
        ie(
            48,
            0x01, 0x00, // version 1
            0x00, 0x0F, 0xAC, 0x04, // group CCMP
            0x01, 0x00, // 1 pairwise
            0x00, 0x0F, 0xAC, 0x04, // CCMP
            0x01, 0x00, // 1 AKM
            0x00, 0x0F, 0xAC, 0x02 // PSK
        )
    }

    @Test func rsnWpa2PskCcmp() {
        let p = WifiIeParser.parseIes(ies: [wpa2CcmpPsk], capabilities: "[WPA2-PSK-CCMP][ESS]")
        #expect(p.security == "RSN PSK CCMP (group CCMP)")
    }

    @Test func rsnWpa3Sae() {
        let e = ie(48, 0x01, 0x00, 0x00, 0x0F, 0xAC, 0x04, 0x01, 0x00, 0x00, 0x0F, 0xAC, 0x04, 0x01, 0x00, 0x00, 0x0F, 0xAC, 0x08)
        #expect(WifiIeParser.parseIes(ies: [e], capabilities: "").security == "RSN SAE CCMP (group CCMP)")
    }

    @Test func rsnTransitionModeListsBothAkms() {
        let e = ie(
            48,
            0x01, 0x00,
            0x00, 0x0F, 0xAC, 0x04,
            0x01, 0x00,
            0x00, 0x0F, 0xAC, 0x04,
            0x02, 0x00,
            0x00, 0x0F, 0xAC, 0x02, // PSK
            0x00, 0x0F, 0xAC, 0x08 // SAE
        )
        #expect(WifiIeParser.parseIes(ies: [e], capabilities: "").security == "RSN PSK/SAE CCMP (group CCMP)")
    }

    private var wpa1: WifiIeParser.Ie {
        ie(
            221,
            0x00, 0x50, 0xF2, 0x01, // Microsoft OUI, WPA type
            0x01, 0x00,
            0x00, 0x50, 0xF2, 0x02, // group TKIP
            0x01, 0x00,
            0x00, 0x50, 0xF2, 0x02, // pairwise TKIP
            0x01, 0x00,
            0x00, 0x50, 0xF2, 0x02 // akm
        )
    }

    @Test func wpa1VendorIeSummaryAndOui() {
        let p = WifiIeParser.parseIes(ies: [wpa1], capabilities: "")
        #expect(p.security == "WPA TKIP")
        #expect(p.vendorIes.contains { $0.oui == "00:50:F2" && $0.type == 1 })
    }

    @Test func vendorIeExtractsOuiTypeAndPayload() {
        let p = WifiIeParser.parseIes(ies: [ie(221, 0x00, 0x17, 0xF2, 0x0A, 0x01, 0x02)], capabilities: "")
        #expect(p.vendorIes.count == 1)
        #expect(p.vendorIes.first?.oui == "00:17:F2")
        #expect(p.vendorIes.first?.type == 0x0A)
        #expect(p.vendorIes.first?.dataHex == "0102")
    }

    @Test func ratesDecodeBasicFlagAndHalfMbps() {
        let p = WifiIeParser.parseIes(ies: [ie(1, 0x82, 0x84, 0x8B, 0x96, 0x0C, 0x12, 0x18, 0x24)], capabilities: "")
        #expect(p.rates == "1* 2* 5.5* 11* 6 9 12 18")
    }

    @Test func dsParameterSetsChannel() {
        #expect(WifiIeParser.parseIes(ies: [ie(3, 0x06)], capabilities: "").channelFromDs == 6)
    }

    @Test func capabilitiesFallbackWhenNoSecurityIe() {
        #expect(WifiIeParser.parseIes(ies: [], capabilities: "[WPA2-PSK-CCMP][ESS]").security == "[WPA2-PSK-CCMP][ESS]")
        // A truncated RSN body must not shadow the capability string.
        let short = ie(48, 0x01, 0x00, 0x00, 0x0F)
        #expect(WifiIeParser.parseIes(ies: [short], capabilities: "[WPA2-PSK-CCMP][ESS]").security == "[WPA2-PSK-CCMP][ESS]")
    }

    @Test func vendorIeKeepsOpenDroneIdSizedPayload() {
        let body = (0..<30).map { UInt8($0) }
        let e = WifiIeParser.Ie(id: 221, bytes: [0xFA, 0x0B, 0xBC, 0x0D] + body)
        let p = WifiIeParser.parseIes(ies: [e], capabilities: "")
        #expect(p.vendorIes.count == 1)
        #expect(p.vendorIes.first?.oui == "FA:0B:BC")
        #expect(p.vendorIes.first?.type == 0x0D)
        #expect(p.vendorIes.first?.dataHex.count == 60)
    }

    @Test func noIesNoCapabilitiesGivesNullSecurity() {
        #expect(WifiIeParser.parseIes(ies: [], capabilities: nil).security == nil)
        #expect(WifiIeParser.parseIes(ies: [], capabilities: "").security == nil)
    }

    // MARK: - macOS: byte-based input (CoreWLAN informationElementData)

    @Test func rawBlobParsesLikeIeList() {
        let raw = blob(ie(0, 0x41, 0x50), ie(1, 0x82, 0x84), ie(3, 0x0B), wpa2CcmpPsk, ie(221, 0x00, 0x17, 0xF2, 0x0A, 0x01))
        let p = WifiIeParser.parse(ies: raw)
        #expect(p.rates == "1* 2*")
        #expect(p.channelFromDs == 11)
        #expect(p.security == "RSN PSK CCMP (group CCMP)")
        #expect(p.vendorIes.map { $0.oui } == ["00:17:F2"])
        #expect(p.elements.count == 5)
    }

    @Test func truncatedBlobKeepsCompleteElements() {
        let raw = blob(ie(3, 0x06)) + [221, 40, 0x00, 0x17]
        let p = WifiIeParser.parse(ies: raw)
        #expect(p.channelFromDs == 6)
        #expect(p.vendorIes.isEmpty)
        #expect(WifiIeParser.parse(ies: []) == WifiIeParser.Parsed())
    }

    @Test func openNetworkSecurityFallsBackToEss() {
        let p = WifiIeParser.parse(ies: blob(ie(0, 0x41), ie(3, 0x01)))
        #expect(p.security == "[ESS]")
        #expect(DeviceExplain.wifiSecurityExplain(raw: p.security!).contains("Open"))
    }

    @Test func capabilitiesStringFromRsnWpaAndWps() {
        let wps = ie(221, 0x00, 0x50, 0xF2, 0x04, 0x10, 0x4A)
        let p = WifiIeParser.parse(ies: blob(wpa2CcmpPsk, wps))
        #expect(WifiIeParser.capabilitiesString(parsed: p) == "[WPA2-PSK-CCMP][RSN-PSK-CCMP][ESS][WPS]")
        let mixed = WifiIeParser.parse(ies: blob(wpa1, wpa2CcmpPsk))
        #expect(WifiIeParser.capabilitiesString(parsed: mixed) == "[WPA-PSK-TKIP][WPA2-PSK-CCMP][RSN-PSK-CCMP][ESS]")
        let sae = WifiIeParser.parse(ies: blob(ie(48, 0x01, 0x00, 0x00, 0x0F, 0xAC, 0x04, 0x01, 0x00, 0x00, 0x0F, 0xAC, 0x04,
                                                   0x02, 0x00, 0x00, 0x0F, 0xAC, 0x02, 0x00, 0x0F, 0xAC, 0x08)))
        let caps = WifiIeParser.capabilitiesString(parsed: sae)
        #expect(caps == "[WPA2-PSK+SAE-CCMP][RSN-PSK+SAE-CCMP][ESS]")
        #expect(DeviceExplain.wifiSecurityExplain(raw: caps).contains("WPA3"))
        let open = WifiIeParser.parse(ies: blob(ie(0, 0x41), ie(114, 0x6D)))
        #expect(WifiIeParser.capabilitiesString(parsed: open, ibss: true, privacy: true) == "[WEP][MESH][IBSS]")
    }

    @Test func vendorIeOuisInOrderDistinct() {
        let raw = blob(ie(221, 0x00, 0x17, 0xF2, 0x0A), ie(48, 0x01, 0x00), ie(221, 0x00, 0x50, 0xF2, 0x04), ie(221, 0x00, 0x17, 0xF2, 0x06), ie(221, 0x01))
        #expect(WifiIeParser.vendorIeOuis(ies: raw) == ["00:17:F2", "00:50:F2"])
    }

    @Test func wifiStandardFromCapabilityElements() {
        let ht = ie(45, 0x00, 0x00)
        let vht = ie(191, 0x00, 0x00, 0x00, 0x00)
        let he = ie(255, 35, 0x00)
        let eht = ie(255, 108, 0x00)
        #expect(WifiIeParser.wifiStandardLabel(ies: []) == nil)
        #expect(WifiIeParser.wifiStandardLabel(ies: blob(ie(1, 0x82))) == "802.11a/b/g")
        #expect(WifiIeParser.wifiStandardLabel(ies: blob(ht), band: 2) == "802.11n")
        #expect(WifiIeParser.wifiStandardLabel(ies: blob(ht, vht), band: 5) == "802.11ac")
        #expect(WifiIeParser.wifiStandardLabel(ies: blob(ht, vht), band: 2) == "802.11n")
        #expect(WifiIeParser.wifiStandardLabel(ies: blob(ht, vht, he), band: 5) == "802.11ax")
        #expect(WifiIeParser.wifiStandardLabel(ies: blob(ht, vht, he, eht), band: 6) == "802.11be")
    }

    @Test func channelWidthFromOperationElements() {
        let ht20 = ie(61, 36, 0x00, 0, 0, 0)
        let ht40 = ie(61, 36, 0x05, 0, 0, 0) // secondary above, any width
        let vht80 = ie(192, 1, 42, 0, 0, 0)
        let vht160 = ie(192, 1, 42, 50, 0, 0)
        let vht8080 = ie(192, 1, 42, 106, 0, 0)
        #expect(WifiIeParser.channelWidthLabel(ies: []) == nil)
        #expect(WifiIeParser.channelWidthLabel(ies: blob(ie(1, 0x82))) == "20 MHz")
        #expect(WifiIeParser.channelWidthLabel(ies: blob(ht20), band: 2) == "20 MHz")
        #expect(WifiIeParser.channelWidthLabel(ies: blob(ht40), band: 5) == "40 MHz")
        #expect(WifiIeParser.channelWidthLabel(ies: blob(ht40, vht80), channel: 36, band: 5) == "80 MHz")
        #expect(WifiIeParser.channelWidthLabel(ies: blob(ht40, vht160), band: 5) == "160 MHz")
        #expect(WifiIeParser.channelWidthLabel(ies: blob(ht40, vht8080), band: 5) == "80+80 MHz")
        // 6 GHz HE Operation: params with bit 17 set, then 6 GHz info [primary, control=2 (80), ccfs0, ccfs1, minRate].
        let he6 = ie(255, 36, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 37, 0x02, 39, 0, 0)
        #expect(WifiIeParser.channelWidthLabel(ies: blob(he6), band: 6) == "80 MHz")
        // EHT Operation info present (bit 0) with control 4 = 320 MHz.
        let eht = ie(255, 106, 0x01, 0, 0, 0, 0, 0x04, 31, 63)
        #expect(WifiIeParser.channelWidthLabel(ies: blob(he6, eht), band: 6) == "320 MHz")
    }

    // MARK: - channel / frequency helpers

    @Test func channelOfKnownFrequencies() {
        #expect(WifiIeParser.channelOf(freq: 2412) == 1)
        #expect(WifiIeParser.channelOf(freq: 2437) == 6)
        #expect(WifiIeParser.channelOf(freq: 2484) == 14)
        #expect(WifiIeParser.channelOf(freq: 5180) == 36)
        #expect(WifiIeParser.channelOf(freq: 5825) == 165)
        #expect(WifiIeParser.channelOf(freq: 5955) == 1)
        #expect(WifiIeParser.channelOf(freq: 6115) == 33)
        #expect(WifiIeParser.channelOf(freq: 900) == 0)
    }

    @Test func frequencyChannelRoundTrip() {
        for ch in 1...14 {
            let f = WifiIeParser.frequencyOf(channel: ch, band: 2)
            #expect(WifiIeParser.channelOf(freq: f) == ch, "2.4 GHz ch \(ch) -> \(f)")
        }
        for ch in [36, 40, 44, 48, 52, 64, 100, 120, 144, 149, 153, 161, 165, 169, 177] {
            let f = WifiIeParser.frequencyOf(channel: ch, band: 5)
            #expect(WifiIeParser.channelOf(freq: f) == ch, "5 GHz ch \(ch) -> \(f)")
        }
        for ch in stride(from: 1, through: 233, by: 4) {
            let f = WifiIeParser.frequencyOf(channel: ch, band: 6)
            #expect(WifiIeParser.channelOf(freq: f) == ch, "6 GHz ch \(ch) -> \(f)")
        }
        #expect(WifiIeParser.frequencyOf(channel: 14, band: 2) == 2484)
        #expect(WifiIeParser.frequencyOf(channel: 2, band: 6) == 5935)
        #expect(WifiIeParser.frequencyOf(channel: 0, band: 5) == 0)
        #expect(WifiIeParser.frequencyOf(channel: 36, band: 7) == 0)
        for f in [2412, 2462, 5180, 5745, 5955, 7115] {
            let ch = WifiIeParser.channelOf(freq: f)
            let band = f < 3000 ? 2 : (f < 5950 ? 5 : 6)
            #expect(WifiIeParser.frequencyOf(channel: ch, band: band) == f, "\(f)")
        }
    }
}
