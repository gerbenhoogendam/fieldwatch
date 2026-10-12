import Foundation
import Testing
@testable import FieldwatchCore

struct CodDecoderTest {
    @Test func smartphoneIsPhoneSlashSmartphone() {
        // major 0x02 Phone, minor 0x03 Smartphone, format 0.
        let d = CodDecoder.decode(cod: 0x020C)
        #expect(d.major == "Phone")
        #expect(d.minor == "Smartphone")
        #expect(d.summary() == "Phone / Smartphone")
    }

    @Test func serviceBitsAppendToSummary() {
        // Networking (bit 4) + Audio (bit 8) of the service field; A/V headphones.
        let cod = (1 << 17) | (1 << 21) | (0x04 << 8) | (0x06 << 2)
        let d = CodDecoder.decode(cod: cod)
        #expect(d.major == "Audio / Video")
        #expect(d.minor == "Headphones")
        #expect(d.summary() == "Audio / Video / Headphones · Networking, Audio")
    }

    @Test func peripheralKeyboard() {
        // major 0x05 Peripheral, minor 0x10 = keyboard HID bit alone.
        let d = CodDecoder.decode(cod: (0x05 << 8) | (0x10 << 2))
        #expect(d.major == "Peripheral")
        #expect(d.minor == "Keyboard")
    }

    @Test func nonZeroFormatSuppressesMinorName() {
        let d = CodDecoder.decode(cod: (0x02 << 8) | (0x03 << 2) | 0x01)
        #expect(d.minor == "format 1")
    }

    @Test func zeroAndNullDecodeToNull() {
        #expect(CodDecoder.decodeOrNull(cod: nil) == nil)
        #expect(CodDecoder.decodeOrNull(cod: 0) == nil)
    }
}
