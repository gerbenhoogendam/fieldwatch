import SwiftUI
import AppKit
import Darwin
import FieldwatchCore

// Port of ui/screen/ScanStatusScreen.kt (Settings → Diagnostics).
// Mac and scan facts only: no network names, MACs, or coordinates. The report logic and wording are Core
// `ScanStatus`; this screen fills `ScanPhoneFacts` from the Mac and adds the two privacy permissions.

struct ScanStatusScreen: View {
    @Environment(\.fw) var fw
    var state: FieldwatchUi
    var onBack: () -> Void
    @State var copied = false

    var body: some View {
        VStack(spacing: 0) {
            NestedTopBar(title: "Diagnostics", onBack: onBack)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let now = Int(ctx.date.timeIntervalSince1970 * 1000)
                let report = ScanStatus.report(
                    radio: state.scanRadio,
                    phone: scanPhoneFacts(state: state, now: now),
                    now: now,
                    radiosOnAir: state.wifiNow + state.bleNow,
                    // No GNSS receiver on a Mac: no GNSS or calibration rows.
                    gnssRows: []
                )
                let bluetooth = PrivacyPermission.bluetooth()
                let location = PrivacyPermission.location()
                ScrollView {
                    content(report: report, bluetooth: bluetooth, location: location)
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(fw.background)
    }

    @ViewBuilder
    private func content(report: ScanStatusReport, bluetooth: PrivacyPermission, location: PrivacyPermission) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(report.verdict)
                .font(.system(size: 15))
                .foregroundStyle(report.blocked ? fw.error : fw.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            Text("What to check")
                .font(.system(size: 13, weight: .semibold))
            ForEach(Array(report.checks.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("If that does not explain it, click Copy and send the paste.")
                .font(.system(size: 12))
                .foregroundStyle(fw.onSurfaceVariant)

            SectionCard(title: "Permissions") {
                permissionRow("Bluetooth", bluetooth, off: "BLE advertisers will not appear.") {
                    RadioPermissions.openBluetoothSettings()
                }
                permissionRow("Location", location, off: "Wi-Fi network names and addresses are hidden by macOS.") {
                    RadioPermissions.openLocationSettings()
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Array(report.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0)
                            .font(.system(size: 13))
                            .gridColumnAlignment(.leading)
                        Text(row.1)
                            .font(FW.mono(12))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 4)

            HStack(spacing: 10) {
                FieldwatchActionButton("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText(report, bluetooth: bluetooth), forType: .string)
                    copied = true
                }
                if copied {
                    Text("Copied.")
                        .font(.system(size: 12))
                        .foregroundStyle(fw.onSurfaceVariant)
                }
            }
            Text("Paste this into an issue. It has no network names, no addresses, and no coordinates.")
                .font(.system(size: 12))
                .foregroundStyle(fw.onSurfaceVariant)
        }
    }

    @ViewBuilder
    private func permissionRow(_ title: String, _ status: PrivacyPermission, off: String, openSettings: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 13)).frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.label)
                    .font(FW.mono(12))
                    .foregroundStyle(status == .granted ? fw.tint(FW.phosphor) : (status == .notDetermined ? fw.onSurfaceVariant : fw.error))
                if status != .granted {
                    Text(off).font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
                }
            }
            Spacer()
            switch status {
            case .notDetermined:
                FieldwatchActionButton("Grant", prominent: true) { PrivacyPermission.request() }
            case .denied, .servicesOff:
                FieldwatchActionButton("Open System Settings") { _ = openSettings() }
            case .granted:
                EmptyView()
            }
        }
    }

    /// Core report text plus the Bluetooth permission, which the Android report did not need.
    private func copyText(_ report: ScanStatusReport, bluetooth: PrivacyPermission) -> String {
        "Bluetooth permission: \(bluetooth.label)\n" + report.text
    }
}

/// Kotlin `scanPhoneFacts(context, state, now)`. Field names stay Android's; Core `ScanPhoneFacts` documents the
/// Mac meaning of each.
func scanPhoneFacts(state: FieldwatchUi, now: Int) -> ScanPhoneFacts {
    let app = FieldwatchApp.shared
    let filter = state.filter
    let info = Bundle.main.infoDictionary ?? [:]
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let release = os.patchVersion > 0
        ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        : "\(os.majorVersion).\(os.minorVersion)"
    let darwin = Int(sysctlString("kern.osrelease").substringBefore(".")) ?? 0
    return ScanPhoneFacts(
        versionName: (info["CFBundleShortVersionString"] as? String) ?? "dev",
        versionCode: Int((info["CFBundleVersion"] as? String) ?? "") ?? 0,
        catalogVersion: state.catalogVersion,
        manufacturer: "Apple",
        model: sysctlString("hw.model"),
        androidRelease: release,
        sdkInt: darwin,
        fingerprint: sysctlString("kern.osversion"),
        locationOn: app.systemLocationOn(),
        locationPermission: app.hasFineLocation(),
        gpsFixAgeMs: app.gpsFixAgeMs(now: now),
        arrivalsOnly: filter.arrivalsOnly,
        watchedOnly: filter.watchedOnly,
        customNamesOnly: filter.customNamesOnly,
        showOnly: filter.namedOnly || filter.namedOnlyImplied(),
        movingWithYou: filter.movingWithYou,
        showWifi: filter.showWifi,
        showBle: filter.showBle,
        nameFilter: filter.nameQuery.isNotBlank,
        ouiFilter: filter.ouiQuery.isNotBlank,
        wifiFastScan: state.settings.wifiFastScan,
        // macOS refusing or pacing an on-demand CoreWLAN scan shows up as "waiting on OS".
        wifiOsThrottled: state.scanRadio.wifiWaitingOnOs,
        // The scan runs in the app process, so it keeps going while the window is in the background.
        backgroundUsage: state.scanning,
        // The runtime holds an App Nap-proof activity while it scans.
        unrestrictedBattery: state.scanning
    )
}

private func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
    return String(cString: buf)
}
