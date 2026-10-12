import Foundation
import Testing
@testable import FieldwatchCore

struct Cta2063Test {
    @Test func longestPrefixNamesTheDeclaredModel() {
        let cases: [(String, String?)] = [
            ("18179132000209", "Freefly Alta X Gen2"),
            ("18179131000018", "Freefly Astro"),
            ("18179130000000", "Freefly Astro"),
            ("18179133000001", "Freefly Astro"),
            ("18179200000001", "Freefly Alta X"),
            ("18179300000001", "Freefly Alta X broadcast kit"),
            ("18179400000001", "Freefly"),
            ("1914CL2D230001", "BRINC Lemur 2"),
            ("1914CR1D230001", "BRINC Responder"),
            ("1914ZZ0001", "BRINC"),
            ("1839FTD5020001", "Teal 2"),
            ("1839ABC0001", "Teal"),
            ("1596F33ABCDEF", nil),
            ("1581F3YTDJ1D0031Z530", nil),
            ("1748CHL7822390001", "Autel"),
            ("1748chl7822390001", "Autel"),
            ("1668BE10JA000000", "Skydio"),
            ("1668be10ja000000", "Skydio"),
            ("1748", nil),
            ("1668", nil),
            ("1748AHL7822390001", nil),
            ("1668AE10JA000000", nil),
            ("  18179132000209  ", "Freefly Alta X Gen2"),
            ("18179132000209".lowercased(), "Freefly Alta X Gen2"),
            ("1914cl2d230001", "BRINC Lemur 2"),
            ("XX18179132000209", nil),
            ("", nil),
            ("   ", nil),
        ]
        for (serial, want) in cases {
            #expect(Cta2063.label(serial: serial) == want, "\(serial)")
        }
    }
}
