import Foundation
import Testing
@testable import FieldwatchCore

/// Smoke test: a small synthetic debrief renders to a non-empty PDF.
struct DebriefPdfTests {
    private func sampleDoc() -> DebriefDoc {
        let longBody = (1...140).map { "Line \($0): a radio was heard near the stop and logged for the debrief." }.joined(separator: " ")
        return DebriefDoc(
            generatedUtc: "2026-10-12T14:03:22Z",
            windowLine: "14:00–15:00",
            meta: [("Generated", "2026-10-12 14:03 UTC"), ("Window", "14:00–15:00"), ("Radios", "42")],
            disclaimer: "Pattern matches only.\n\nNot a safety finding.",
            trackingAlert: true,
            takeaway: "Nothing followed you.",
            sections: [
                DebriefSection(
                    number: "1",
                    title: "Summary",
                    body: "Overview:\n· First bullet\n• Second bullet\n1. Stay 12 min\nPlain prose paragraph.",
                    chart: ReportChart(rows: [
                        ReportBar(label: "Finder tags", value: 5, detail: "2 rotating"),
                        ReportBar(label: "Wearables", value: 0),
                    ]),
                    after: "After the chart."
                ),
                DebriefSection(
                    number: "2",
                    title: "By radio",
                    body: longBody,
                    alert: true,
                    chart: ReportChart(rows: [ReportBar(label: "Hour 14", value: 9, second: 4)], split: true, caption: "Wi-Fi vs BLE")
                ),
                DebriefSection(number: "3", title: "Extra attention", body: "ignored when hits exist"),
            ],
            extraAttention: [ExtraAttentionHit(signature: "Example tag", radioLabel: "AA:BB:CC:**:**:**", note: "Seen at every stop.")]
        )
    }

    @Test func rendersPdfData() throws {
        var progress: [Double] = []
        let data = DebriefPdf.render(doc: sampleDoc(), onProgress: { progress.append($0) })
        #expect(data.count > 1000)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "%PDF")
        #expect(progress.last == 1.0)
    }

    @Test func writesPdfFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("debrief-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sub/debrief.pdf")
        try DebriefPdf.write(doc: sampleDoc(), file: file)
        let data = try Data(contentsOf: file)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "%PDF")
    }
}
