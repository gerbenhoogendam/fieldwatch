import SwiftUI
import FieldwatchCore

// Port of ui/screen/CandidatesScreen.kt — Reports → Signature candidates (manual §9.2.1, §11.5).

struct CandidatesScreen: View {
    var vm: FieldwatchViewModel
    var demoMode: Bool
    var onBack: () -> Void
    var onCreate: (SignatureCandidate) -> Void

    @Environment(\.fw) var fw

    var body: some View {
        let ui = vm.candidates
        VStack(spacing: 0) {
            NestedTopBar(title: "Signature candidates", onBack: onBack) {
                // Mac addition: re-mine the log without leaving the page.
                Button { vm.startSignatureCandidates() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ui.loading ? fw.onSurfaceVariant.opacity(0.5) : fw.onSurface)
                .disabled(ui.loading)
                .keyboardShortcut("r", modifiers: .command)
                .help("Read the log again (⌘R)")
                .accessibilityLabel("Read the log again")
            }
            content(ui)
        }
        .background(fw.background)
        .onAppear {
            // Kotlin's caller starts the run before navigating; also start if this page opens cold.
            if !ui.loading && ui.report == nil && ui.error == nil { vm.startSignatureCandidates() }
        }
    }

    @ViewBuilder private func content(_ ui: CandidatesUi) -> some View {
        if ui.loading {
            VStack(spacing: 16) {
                ProgressView().controlSize(.regular)
                Text("Reading the log and re-matching the catalog…")
                    .font(.system(size: 13))
                    .foregroundStyle(fw.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = ui.error {
            Text(error)
                .font(.system(size: 13))
                .foregroundStyle(fw.error)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            let report = ui.report
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text(headerLine(report))
                        .font(.system(size: 12))
                        .foregroundStyle(fw.onSurfaceVariant)
                    if let report, report.skippedRandomized > 0 || report.skippedHouseLike > 0 {
                        Text(skipLine(report))
                            .font(.system(size: 12))
                            .foregroundStyle(fw.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(fw.sectionFill))
                    }
                    if let report, report.families.isNotEmpty {
                        ForEach(report.families) { cand in
                            CandidateCard(cand: cand, demoMode: demoMode, onCreate: onCreate)
                        }
                    } else {
                        Text("No signature families in this log. Randomized addresses and house-like names are skipped. A candidate needs a unique on-air ID on two or more radios.")
                            .font(.system(size: 13))
                            .foregroundStyle(fw.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func headerLine(_ report: CandidateReport?) -> String {
        var s = (report?.sourceLabel ?? "Rotating log") + " · re-matched now"
        if let report {
            let n = report.families.count
            s += " · \(n) \(n == 1 ? "family" : "families")"
        }
        return s
    }
}

private struct CandidateCard: View {
    @Environment(\.fw) var fw
    var cand: SignatureCandidate
    var demoMode: Bool
    var onCreate: (SignatureCandidate) -> Void

    var body: some View {
        let accent = fw.tint(fleetColor(cand.colorIndex))
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                RadioClassBadge(classKind: cand.kind, accent: accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(cand.proposedName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(fw.onSurface)
                        .lineLimit(1)
                    Text(cand.kind.label())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.16)))
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(cand.distinctRadios)")
                        .font(FW.mono(16, weight: .bold))
                        .foregroundStyle(fw.onSurface)
                    RadioKindMark(kind: cand.radioKind, size: 13)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(cand.distinctRadios) \(cand.radioKind.label()) radios")
            }
            Group {
                Text(cand.ruleLabel)
                    .font(FW.mono(12, weight: .medium))
                    .foregroundStyle(fw.primary)
                    .textSelection(.enabled)
                    .padding(.top, 8)
                Text(cand.why)
                    .font(.system(size: 12))
                    .foregroundStyle(fw.onSurfaceVariant)
                    .padding(.top, 4)
                let examples = cand.examples.map { MacUtil.redactMacIn(text: $0, mac: $0, demo: demoMode && looksLikeMac($0)) }
                if examples.isNotEmpty {
                    let extra = cand.extraCount > 0 ? "\nand \(cand.extraCount) more" : ""
                    Text(examples.joined(separator: " · ") + extra)
                        .font(.system(size: 12))
                        .foregroundStyle(fw.onSurface)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 38)
            HStack {
                Spacer()
                FieldwatchActionButton(action: { onCreate(cand) }) {
                    Image(systemName: "rectangle.stack.badge.plus")
                    Text("Create signature")
                }
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(fw.sectionFill))
    }
}

private func skipLine(_ report: CandidateReport) -> String {
    var bits: [String] = []
    if report.skippedRandomized > 0 { bits.append("\(report.skippedRandomized) randomized addresses") }
    if report.skippedHouseLike > 0 { bits.append("\(report.skippedHouseLike) house-like names") }
    return "Skipped " + bits.joined(separator: " and ") + ". Those are not catalog families."
}

/// Kotlin: four or more colons. macOS: BLE examples may be Core Bluetooth peripheral UUIDs — mask those too.
private func looksLikeMac(_ text: String) -> Bool {
    text.filter { $0 == ":" }.count >= 4 || MacUtil.isOpaqueId(text)
}
