import Foundation
import Testing
@testable import FieldwatchCore

// Port of test/java/app/fieldwatch/data/Catalog93MigrationTest.kt. Pure logic; no files touched.

@Suite struct Catalog93MigrationTest {
    @Test func savedBuiltInRowsDropLooseRulesAndKeepOperatorRules() throws {
        let stock = DefaultCatalog.fleets().associateBy { $0.id }
        let flock = old(
            "fleet-flock-cameras",
            MatchRule(kind: .oui, text: "B4:1E:52"),
            MatchRule(kind: .nameContains, text: "Flock"),
            MatchRule(kind: .nameContains, text: "flck"),
            MatchRule(kind: .nameContains, text: "CONDOR"),
            MatchRule(kind: .nameContains, text: "Falcon"),
            MatchRule(kind: .nameContains, text: "SPARROW"),
            MatchRule(kind: .nameGlob, text: "Flock-*"),
            MatchRule(kind: .nameGlob, text: "Flock-??????"),
            MatchRule(kind: .nameContains, text: "MyPole")
        )
        let penguin = old(
            "fleet-penguin",
            MatchRule(kind: .nameContains, text: "Penguin"),
            MatchRule(kind: .nameContains, text: "PENGUIN"),
            MatchRule(kind: .nameGlob, text: "Penguin*"),
            MatchRule(kind: .nameGlob, text: "Penguin-*"),
            MatchRule(kind: .manufacturerId, companyId: 0x09C8),
            MatchRule(kind: .nameGlob, text: "KeepMe*")
        )
        let fs = old(
            "fleet-fs-ext-battery",
            MatchRule(kind: .nameContains, text: "FS Ext Battery"),
            MatchRule(kind: .nameGlob, text: "FS_*"),
            MatchRule(kind: .nameGlob, text: "FS Ext*"),
            MatchRule(kind: .oui, text: "04:0d:84"),
            MatchRule(kind: .oui, text: "F0:82:C0"),
            MatchRule(kind: .oui, text: "AA:BB:CC")
        )
        let lite = old(
            "fleet-liteon-camera-radio",
            MatchRule(kind: .oui, text: "B8:35:32"),
            MatchRule(kind: .oui, text: "08:3A:88"),
            MatchRule(kind: .oui, text: "C0:35:32")
        )
        let custom = Fleet(id: "fleet-flock-cameras", name: "Mine", rules: [MatchRule(kind: .nameContains, text: "Flock")], builtIn: false)

        let stockFlock = try #require(stock[flock.id])
        let stockPenguin = try #require(stock[penguin.id])
        let stockFs = try #require(stock[fs.id])
        let stockLite = try #require(stock[lite.id])

        let nextFlock = catalog93Fleet(fleet: flock, stock: stockFlock)
        let nextPenguin = catalog93Fleet(fleet: penguin, stock: stockPenguin)
        let nextFs = catalog93Fleet(fleet: fs, stock: stockFs)
        let nextLite = catalog93Fleet(fleet: lite, stock: stockLite)
        let nextCustom = catalog93Fleet(fleet: custom, stock: stockFlock)

        #expect(texts(nextFlock) == ["B4:1E:52", "Flock-*", "MyPole"])
        #expect(nextFlock.notes == stockFlock.notes)
        #expect(Set(texts(nextPenguin).filter { $0.isNotBlank }) == ["Penguin-*", "KeepMe*"])
        #expect(nextPenguin.rules.contains { $0.kind == .manufacturerId && $0.companyId == 0x09C8 })
        #expect(nextPenguin.attentionNote == stockPenguin.attentionNote)
        #expect(texts(nextFs) == ["FS Ext Battery", "FS Ext*", "AA:BB:CC"])
        #expect(!texts(nextFs).contains { $0.equals("FS_*", ignoreCase: true) })
        #expect(texts(nextLite) == ["08:3A:88", "C0:35:32"])
        #expect(nextLite.notes.contains("Universal Global Scientific"))
        #expect(nextCustom.rules.map { $0.text } == ["Flock"])
    }

    private func old(_ id: String, _ rules: MatchRule...) -> Fleet {
        Fleet(id: id, name: id, rules: rules, notes: "old notes", attentionNote: "old attention", builtIn: true)
    }

    private func texts(_ fleet: Fleet) -> Set<String> { Set(fleet.rules.map { $0.text }) }
}
