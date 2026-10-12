import SwiftUI
import AppKit
import FieldwatchCore

// macOS entry point. Android: MainActivity (setContent { FieldwatchRoot(vm) }) + the Application class.
// One main window (dark, min 1000×640), one FieldwatchViewModel, and the runtime FieldwatchApp.shared.

@main
struct FieldwatchMain: App {
    @NSApplicationDelegateAdaptor(FieldwatchAppDelegate.self) var appDelegate
    @State var vm: FieldwatchViewModel
    @State var nav = FieldwatchNav()

    init() {
        // Android Application.onCreate: the runtime exists before the first screen.
        let app = FieldwatchApp.shared
        _vm = State(initialValue: FieldwatchViewModel(application: app))
    }

    var body: some Scene {
        Window("Fieldwatch", id: "main") {
            FieldwatchRoot(vm: vm, nav: nav)
                .frame(minWidth: 1000, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1320, height: 840)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            FieldwatchCommands(vm: vm, nav: nav)
        }
    }
}

final class FieldwatchAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    /// Single-window field tool: closing the window ends the session.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        FieldwatchApp.shared.stopScanning()
    }
}

// MARK: - Menu commands

struct FieldwatchCommands: Commands {
    var vm: FieldwatchViewModel
    var nav: FieldwatchNav

    var body: some Commands {
        let state = vm.ui
        let ready = state.settings.disclaimerOk()
        let exporting = vm.export.active

        CommandGroup(replacing: .appInfo) {
            Button("About Fieldwatch") { showAboutPanel() }
        }
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .printItem) {}

        // File → Export shortcuts into Reports.
        CommandGroup(after: .saveItem) {
            Button("Export…") { nav.tab = .reports }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!ready)
            Menu("Export As") {
                Button("Save Log As…") {
                    nav.tab = .reports
                    FieldwatchSavePanels.saveLog(vm: vm)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Save Sit Export As…") {
                    nav.tab = .reports
                    FieldwatchSavePanels.saveSit(vm: vm)
                }
                Divider()
                Button("Debrief") {
                    nav.tab = .reports
                    vm.startFieldDebrief()
                }
                Button("Debrief PDF") {
                    nav.tab = .reports
                    vm.startFieldDebriefPdf()
                }
                Button("AI Export") {
                    nav.tab = .reports
                    vm.startAiExport()
                }
            }
            .disabled(!ready || exporting)
        }

        // View → the five sidebar tabs.
        CommandGroup(before: .sidebar) {
            ForEach(Array(FieldwatchTab.allCases.enumerated()), id: \.element) { i, tab in
                Button(tab.title) { nav.tab = tab }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
            .disabled(!ready)
            Button(state.settings.scanControlsExpanded ? "Hide Display Options" : "Show Display Options") {
                nav.tab = .live
                vm.setScanControlsExpanded(expanded: !state.settings.scanControlsExpanded)
            }
            .disabled(!ready)
            Button(state.settings.nightMode ? "Night Mode Off" : "Night Mode On") {
                vm.updateSettings(transform: { s in
                    var s = s
                    s.nightMode.toggle()
                    return s
                })
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
        }

        CommandMenu("Scan") {
            Button(state.scanning ? "Stop Scanning" : "Start Scanning") {
                if state.scanning { vm.stopScan() } else { vm.startScan() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!ready)

            // Space does the same while Live is in front.
            Button(state.displayPaused ? "Run Live Display" : "Pause Live Display") {
                vm.toggleLiveDisplay()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!ready)

            Divider()

            if state.sit.open != nil {
                Button("End Sit") { vm.endSit() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!ready)
            } else {
                Button("Start Sit") { vm.startSit(name: vm.defaultSitName()) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!ready)
            }

            Divider()

            Button("Show Live Tour") {
                vm.showLiveTour(then: { nav.tab = .live })
            }
            .disabled(!ready)
            Button("Diagnostics") { nav.openDiagnostics() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(!ready)
        }

        CommandGroup(replacing: .help) {
            if let manual = Bundle.main.url(forResource: "Fieldwatch_User_Manual", withExtension: "pdf") {
                Button("Fieldwatch User Manual") { NSWorkspace.shared.open(manual) }
                    .keyboardShortcut("?", modifiers: .command)
            }
        }
    }

    private func showAboutPanel() {
        let credits = NSAttributedString(
            string: "Fieldwatch by Off Grid Pete LLC (MIT). macOS port.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Fieldwatch",
            .credits: credits,
        ])
    }
}
