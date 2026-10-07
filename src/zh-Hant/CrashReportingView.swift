import AppKit
import SwiftUI

/// "Send crash reports and diagnostics" (CrashReporting): Settings > General, the first-run
/// alert (SteamClientPicker.alertAccessoryView) and the Create SteamOS Disk sheet. Bound to
/// `sendCrashReports`; the VM process applies a change right away, the supervisor before the
/// next boot or report.
struct CrashReportsToggle: View {
    @ObservedObject var settings: LauncherSettings
    /// Settings window: the "applies now" / command-line override captions.
    var showsApplies = false
    /// First-run alert and Create SteamOS Disk sheet: a checkbox (Settings uses switches).
    var checkbox = false
    @State private var showDetails = false

    var body: some View {
        let toggle = Toggle(isOn: $settings.sendCrashReports) {
            VStack(alignment: .leading, spacing: 2) {
                Text("發送當機報告與診斷數據")
                Text(CrashReporting.summary)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("查看發送內容") { showDetails.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .popover(isPresented: $showDetails, arrowEdge: .bottom) { WhatIsSentView() }
                if showsApplies {
                    Text("立即生效").font(.caption).foregroundStyle(.secondary)
                    if let flag = settings.overrides[.sendCrashReports] {
                        Text("已被命令行覆蓋 (\(flag))").font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        if checkbox { toggle.toggleStyle(.checkbox) } else { toggle }
    }
}

/// The "What is sent" popover (also captured by --selftest-settings).
struct WhatIsSentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("發送內容說明").font(.headline)
            ForEach(CrashReporting.whatIsSent, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                    Text(item).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
            Text("報告將發送至開發者的專用服務器。可隨時在 一般設定 中關閉，或使用 --no-crash-reports 臨時停用。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
    }
}
