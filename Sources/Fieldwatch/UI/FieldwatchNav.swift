import SwiftUI
import Observation

// Window navigation for the macOS shell (FieldwatchAppUi.swift): the Android NavHost routes as sidebar tabs,
// per-tab NavigationStack paths, the detail inspector, and the Hunt sheet.
//
// Kept in its own file WITHOUT `import FieldwatchCore`: Core declares `public struct Observation`, which
// shadows the Observation module inside the `@Observable` macro expansion in any file that imports Core.

/// The five bottom tabs of the Android app, now sidebar entries, plus the Mac-only Map.
enum FieldwatchTab: String, CaseIterable, Identifiable, Hashable {
    case live, map, room, connected, filters, fleets, reports, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "Live"
        case .map: return "Map"
        case .room: return "Room"
        case .connected: return "Connected"
        case .filters: return "Filters"
        case .fleets: return "Signatures"
        case .reports: return "Reports"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .live: return "dot.radiowaves.left.and.right"
        case .map: return "map"
        case .room: return "square.split.bottomrightquarter"
        case .connected: return "link"
        case .filters: return "line.3.horizontal.decrease.circle"
        case .fleets: return "point.3.filled.connected.trianglepath.dotted"
        case .reports: return "doc.text"
        case .settings: return "gearshape"
        }
    }
}

/// Kotlin NavHost sub-routes that push inside a tab's NavigationStack.
enum FieldwatchRoute: Hashable {
    case candidates
    case radioBookmarks
    case scanStatus
}

/// Window navigation state. Shared by the window content and the menu commands.
@MainActor @Observable final class FieldwatchNav {
    var tab: FieldwatchTab = .live
    var reportsPath: [FieldwatchRoute] = []
    var settingsPath: [FieldwatchRoute] = []
    /// Device-detail inspector (Kotlin route "detail").
    var detailOpen = false
    /// Hunt sheet (Kotlin route "hunt").
    var huntOpen = false

    init() {}

    func openDiagnostics() {
        tab = .settings
        settingsPath = [.scanStatus]
    }

    func openCandidates() {
        tab = .reports
        if reportsPath.last != .candidates { reportsPath = [.candidates] }
    }
}

