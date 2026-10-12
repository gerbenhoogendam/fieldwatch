import SwiftUI
import FieldwatchCore

// Port of ui/LiveChromeTour.kt.
//
// Android draws one full-screen overlay: a dim layer with holes cut around the Tune icon and the five bottom
// tabs, a callout bubble per target, arrows, and a single "Got it". On the Mac the targets live in the window
// toolbar (Tune, Pause/Run) and the sidebar (Filters, Signatures, Reports, Settings), which are separate AppKit
// hosts, so their geometry cannot be measured into one overlay. The tour is the same six callouts shown as a
// sequence of popovers anchored to each target (Next / Skip / Got it), over a light dim of the Live list.
// Finishing or skipping calls onDismiss (vm.dismissLiveTour). Settings → Show Live tour brings it back.

/// One callout. Kotlin `Spot` titles and bodies, with the copy adapted to the toolbar and sidebar.
enum LiveTourSpot: Int, CaseIterable, Identifiable {
    case tune, pause, filters, signatures, reports, settings

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .tune: return "Tune"
        case .pause: return "Pause"
        case .filters: return "Filters"
        case .signatures: return "Signatures"
        case .reports: return "Reports"
        case .settings: return "Settings"
        }
    }

    var body: String {
        switch self {
        case .tune: return "Display — Radar, list, timeline, hybrid, By class. Click it again to close."
        case .pause: return "Freeze the picture. Radios keep scanning and logging. Click Run or press Space to run again."
        case .filters: return "Who is shown. In the sidebar."
        case .signatures: return "Pattern catalog."
        case .reports: return "Debrief, sits, log."
        case .settings: return "Scan, location, TAK. Show Live tour brings this back."
        }
    }

    /// Toolbar targets get the arrow from below; sidebar rows from the right.
    var arrowEdge: Edge {
        switch self {
        case .tune, .pause: return .bottom
        case .filters, .signatures, .reports, .settings: return .trailing
        }
    }

    var next: LiveTourSpot? { LiveTourSpot(rawValue: rawValue + 1) }

    var isLast: Bool { next == nil }
}

/// Kotlin `LiveChromeTour` + `Callout`: the bubble for one target.
struct LiveChromeTour: View {
    @Environment(\.fw) var fw
    var spot: LiveTourSpot
    var onNext: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(spot.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(fw.primary)
            Text(spot.body)
                .font(.system(size: 12))
                .foregroundStyle(fw.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("\(spot.rawValue + 1) of \(LiveTourSpot.allCases.count)")
                    .font(FW.mono(10))
                    .foregroundStyle(fw.onSurfaceVariant)
                Spacer(minLength: 8)
                if !spot.isLast {
                    Button("Skip", action: onDismiss)
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(fw.onSurfaceVariant)
                }
                FieldwatchActionButton(spot.isLast ? "Got it" : "Next", prominent: true) {
                    if spot.isLast { onDismiss() } else { onNext() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
        .background(fw.surface)
    }
}

/// Anchors the tour popover for `spot` to the modified view. `current` is the spot on screen (nil: no tour).
struct LiveTourAnchor: ViewModifier {
    @Environment(\.fw) var fw
    var spot: LiveTourSpot
    @Binding var current: LiveTourSpot?
    var onDismiss: () -> Void

    func body(content: Content) -> some View {
        content.popover(
            isPresented: Binding(
                get: { current == spot },
                set: { shown in
                    // A click outside the popover closes it: treat that as Skip. Next clears `current`
                    // first, so a programmatic close lands here with current != spot.
                    if !shown && current == spot {
                        current = nil
                        onDismiss()
                    }
                }
            ),
            arrowEdge: spot.arrowEdge
        ) {
            LiveChromeTour(
                spot: spot,
                onNext: {
                    // Close this popover first; AppKit will not present the next one mid-dismissal.
                    let next = spot.next
                    current = nil
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        if current == nil { current = next }
                    }
                },
                onDismiss: {
                    current = nil
                    onDismiss()
                }
            )
            .environment(\.fw, fw)
            .tint(fw.primary)
        }
    }
}
