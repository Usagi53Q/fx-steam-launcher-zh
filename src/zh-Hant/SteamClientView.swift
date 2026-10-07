import AppKit
import SwiftUI

/// "Steam client" choice (LauncherSettings.SteamClient) in the Create SteamOS Disk sheet and the
/// first-run alert; Settings > Advanced has its own row with the "applies on next start" caption.
/// Bound to `steamClient`, which every boot passes as `steamac.steam_client=`.
struct SteamClientPicker: View {
    @ObservedObject var settings: LauncherSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Steam 客戶端通道", selection: $settings.steamClient) {
                ForEach(LauncherSettings.SteamClient.allCases) { Text(SteamClientPicker.itemTitle($0)).tag($0) }
            }
            Text(settings.steamClient.detail + " " + LauncherSettings.SteamClient.switchNote)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func itemTitle(_ c: LauncherSettings.SteamClient) -> String {
        c == .deck ? c.title + " (預設)" : c.title
    }

    /// First-run alert accessory: the Steam client choice above the crash reports checkbox.
    static func alertAccessoryView(settings: LauncherSettings, width: CGFloat = 320) -> NSView {
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            SteamClientPicker(settings: settings)
            CrashReportsToggle(settings: settings, checkbox: true)
        }
        .frame(width: width, alignment: .leading))
        host.frame.size = host.fittingSize
        return host
    }
}
