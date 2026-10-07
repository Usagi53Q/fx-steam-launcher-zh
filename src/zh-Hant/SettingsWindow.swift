import AppKit
import Combine
import CoreAudio
import GameController
import SwiftUI

/// What the Settings window needs from the running VM process (all optional: --selftest-settings
/// and the first-run sheet have no VM).
final class SettingsContext: ObservableObject {
    let settings: LauncherSettings
    /// Live audio controls; nil without a VM.
    let sound: SoundControl?
    /// Graceful guest power-off + relaunch with the new settings; nil without a VM.
    var restart: (() -> Void)?
    /// Whether the running VM has the virtual gamepad / a sound device (next-start state).
    var vmHasPad: Bool
    var vmHasSound: Bool
    /// The running VM's main disk (nil without a VM).
    let diskPath: String?
    /// Opens Report a Problem over the Settings window (nil without a VM; set after the window exists).
    @Published var reportProblem: (() -> Void)?
    @Published var restartRequested = false

    init(settings: LauncherSettings, sound: SoundControl?, restart: (() -> Void)?, vmHasPad: Bool, vmHasSound: Bool,
         diskPath: String? = nil) {
        self.settings = settings
        self.sound = sound
        self.restart = restart
        self.vmHasPad = vmHasPad
        self.vmHasSound = vmHasSound
        self.diskPath = diskPath
    }
}

/// App menu "FX Steam Launcher → Settings…" (Cmd+,): toolbar-style tabs, one SwiftUI form each.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    enum Tab: Int, CaseIterable {
        case general, display, mouse, controller, sound, advanced

        var title: String {
            switch self {
            case .general: return "一般"
            case .display: return "顯示"
            case .mouse: return "滑鼠"
            case .controller: return "控制器"
            case .sound: return "音訊"
            case .advanced: return "進階"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .display: return "display"
            case .mouse: return "computermouse"
            case .controller: return "gamecontroller"
            case .sound: return "speaker.wave.2"
            case .advanced: return "slider.horizontal.3"
            }
        }

        /// Fixed content height per tab (grouped forms scroll beyond it).
        var height: CGFloat {
            switch self {
            case .general: return 830
            case .display: return 600
            case .mouse: return 470
            case .controller: return 620
            case .sound: return 440
            case .advanced: return 720
            }
        }
    }

    static let width: CGFloat = 600
    let window: NSWindow
    private let tabs: SettingsTabController
    let context: SettingsContext

    init(context: SettingsContext) {
        self.context = context
        tabs = SettingsTabController()
        tabs.tabStyle = .toolbar
        for tab in Tab.allCases {
            let root = SettingsTabRoot(tab: tab).environmentObject(context).environmentObject(context.settings)
            let host = NSHostingController(rootView: AnyView(root))
            host.sizingOptions = []
            host.view.frame = NSRect(x: 0, y: 0, width: SettingsWindowController.width, height: tab.height)
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("FXSettings")
        super.init()
        window.delegate = self
        tabs.didSelect = { [weak self] tab in self?.fit(tab) }
        fit(.general)
    }

    private func fit(_ tab: Tab) {
        let size = NSSize(width: SettingsWindowController.width, height: tab.height)
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var f = window.frame
        f.origin.y += f.height - frame.height
        f.size = frame.size
        window.setFrame(f, display: true, animate: window.isVisible)
        window.title = tab.title
    }

    func show(tab: Tab? = nil) {
        if let tab { select(tab) }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func select(_ tab: Tab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
        fit(tab)
    }

    /// The window as drawn (title bar + toolbar + content) at the screen's backing scale, for
    /// --selftest-settings and the control FIFO.
    func snapshot() -> NSBitmapImageRep? { SettingsWindowController.snapshot(window) }

    static func snapshot(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let frameView = window.contentView?.superview else { return nil }
        frameView.layoutSubtreeIfNeeded()
        let scale = window.backingScaleFactor
        let size = frameView.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return rep
    }
}

private final class SettingsTabController: NSTabViewController {
    var didSelect: ((SettingsWindowController.Tab) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        if let item, let tab = SettingsWindowController.Tab(rawValue: tabView.indexOfTabViewItem(item)) { didSelect?(tab) }
    }
}

// MARK: - shared bits

private struct SettingsTabRoot: View {
    let tab: SettingsWindowController.Tab
    @EnvironmentObject var settings: LauncherSettings

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .general: GeneralTab()
                case .display: DisplayTab()
                case .mouse: MouseTab()
                case .controller: ControllerTab()
                case .sound: SoundTab()
                case .advanced: AdvancedTab()
                }
            }
            .formStyle(.grouped)
            RestartBar()
        }
        .frame(width: SettingsWindowController.width, height: tab.height)
    }
}

/// "applies now" / "applies on next start" + the command-line override note.
private struct Applies: View {
    let now: Bool
    var key: LauncherSettings.Key? = nil
    @EnvironmentObject var settings: LauncherSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(now ? "立即生效" : "下次啓動生效")
                .font(.caption)
                .foregroundStyle(now ? Color.secondary : Color.orange.opacity(0.9))
            if let key, let flag = settings.overrides[key] {
                Text("已被命令行覆蓋 (\(flag))")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// A labelled row: title, optional explanation, the "applies" tag.
private struct Label2: View {
    let title: String
    var detail: String? = nil
    let now: Bool
    var key: LauncherSettings.Key? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Applies(now: now, key: key)
        }
    }
}

private struct RestartBar: View {
    @EnvironmentObject var settings: LauncherSettings
    @EnvironmentObject var context: SettingsContext

    var body: some View {
        if settings.restartPending || context.restartRequested {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange).font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.restartRequested ? "正在重啓虛擬機…" : "部分設定將在下次啓動時生效。")
                        .font(.callout.weight(.medium))
                    Text(context.restart == nil ? "當前視窗未運行虛擬機。"
                         : "SteamOS 將正常關機並以新設定重新啓動。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重啓虛擬機以應用") {
                    context.restartRequested = true
                    context.restart?()
                }
                .disabled(context.restart == nil || context.restartRequested)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

private func intBinding(_ b: Binding<Int>, _ range: ClosedRange<Int>) -> Binding<Int> {
    Binding(get: { b.wrappedValue }, set: { b.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) })
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var settings: LauncherSettings
    @EnvironmentObject var context: SettingsContext

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.showOverlay) {
                    Label2(title: "顯示開機與關機進度遮罩",
                           detail: "在 SteamOS 啓動、重啓和關機時顯示全視窗進度遮罩。關閉或點擊後顯示爲精簡進度膠囊。", now: true)
                }
                Toggle(isOn: $settings.showStallIndicator) {
                    Label2(title: "GPU 空閒時顯示加載提示",
                           detail: "當 SteamOS 超過 2 秒無 GPU 渲染任務時（如加載資源、編譯着色器），在畫面上顯示“仍在運行”提示卡片。",
                           now: true)
                }
                Toggle(isOn: $settings.openFullscreen) {
                    Label2(title: "啓動時以全螢幕模式打開", now: false, key: .openFullscreen)
                }
            }
            Section {
                Picker(selection: $settings.closeAction) {
                    Text("關閉 SteamOS").tag(LauncherSettings.CloseAction.shutDown)
                    Text("掛起休眠（在後臺保持運行）").tag(LauncherSettings.CloseAction.suspend)
                } label: {
                    Label2(title: "關閉視窗時",
                           detail: "掛起會將 SteamOS 及當前運行的遊戲立即凍結並保留在記憶體中；點擊 Dock 圖標或菜單欄中的“恢復”即可從離開處繼續。掛起狀態在啓動器運行期間保持：結束啓動器或重啓 Mac 將直接關閉 SteamOS。",
                           now: true)
                }
            }
            Section {
                Toggle(isOn: $settings.followMacTime) {
                    Label2(title: "同步 Mac 的時區與時間格式",
                           detail: "每次開機自動將 Mac 的時區與 12/24 小時制同步給 SteamOS，除非在 SteamOS 或 Steam 內部主動更改。",
                           now: false, key: .followMacTime)
                }
            }
            Section {
                Toggle(isOn: $settings.shareClipboard) {
                    Label2(title: "與 SteamOS 共享剪貼板",
                           detail: "在 Mac 上覆制的文本和圖片可直接粘貼至 SteamOS（Ctrl+V），反之亦然；最高支持 1 MB 文本與 16 MB 圖片。支持桌面模式。",
                           now: true)
                }
                Toggle(isOn: $settings.shareConcealedClipboard) {
                    Label2(title: "包含密碼管理器隱藏內容",
                           detail: "除非開啟此項，否則類似 1Password、Bitwarden 或 KeePassXC 標記爲隱藏或臨時密碼的內容將保留在 Mac 上而不被同步。",
                           now: true)
                }
                .disabled(!settings.shareClipboard)
            }
            Section {
                Toggle(isOn: $settings.muteInBackground) {
                    Label2(title: "靜音", detail: "淡出靜音；切換回前臺時恢復原音量。", now: true)
                }
                Toggle(isOn: $settings.pauseInBackground) {
                    Label2(title: "暫停遊戲",
                           detail: "凍結當前焦點的遊戲進程（Steam 本身、後臺下載和更新仍會繼續運行）。聯機網遊在暫停時可能會斷開連接。",
                           now: true)
                }
            } header: {
                Text("當啓動器處於後臺時")
            }
            Section {
                CrashReportsToggle(settings: settings, showsApplies: true)
                Toggle(isOn: $settings.checkForUpdates) {
                    Label2(title: "啓動時檢查更新",
                           detail: "至多每 6 小時向 GitHub (api.github.com) 查詢最新版本；僅發送應用程序版本號。"
                               + (CrashReporting.buildKind == .development
                                   ? "開發版本在啓動時不自動檢查；可通過 菜單欄 FX Steam Launcher > 檢查更新… 手動查詢。"
                                   : "可通過 菜單欄 FX Steam Launcher > 檢查更新… 隨時手動查詢。"),
                           now: true)
                }
                Toggle(isOn: $settings.perfStats) {
                    Label2(title: "記錄幀率與節奏統計日誌",
                           detail: "每 5 秒記錄一次：客機畫面刷新與渲染間隔、延遲、掉幀數。",
                           now: true, key: .perfStats)
                }
            } footer: {
                if AppBundle.resources != nil {
                    Text("日誌：\((AppBundle.logPath as NSString).abbreviatingWithTildeInPath)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("反饋問題")
                        Text("描述遇到的問題並將選定的診斷日誌發送給開發者（關閉當機報告時亦可使用）。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("反饋問題…") { context.reportProblem?() }
                        .disabled(context.reportProblem == nil)
                }
            }
        }
    }
}

// MARK: - Display

private struct DisplayTab: View {
    @EnvironmentObject var settings: LauncherSettings
    static let refreshRates = [30, 48, 50, 60, 72, 75, 90, 100, 120, 144]
    /// Largest window that fits the screen the VM window opens on (when the tab appears).
    @State private var fit = LauncherSettings.fitToScreenSize()

    /// Choosing a preset writes its W/H; "Fit to screen" writes the current fit (re-evaluated at
    /// each start); "Custom…" keeps W/H and shows the fields.
    private var preset: Binding<String> {
        Binding(get: { settings.windowSizePreset }, set: { id in
            if id == LauncherSettings.fitPreset {
                (settings.windowWidth, settings.windowHeight) = fit
            } else if let p = LauncherSettings.sizePresets.first(where: { $0.id == id }) {
                (settings.windowWidth, settings.windowHeight) = (p.width, p.height)
            }
            settings.windowSizePreset = id
        })
    }

    private func presetTitle(_ p: LauncherSettings.SizePreset) -> String {
        "\(p.width) × \(p.height) (\(p.label))" + (p.width > fit.0 || p.height > fit.1 ? " — 超出當前屏幕" : "")
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.dpiSource) {
                    Text("自動（根據屏幕）").tag(LauncherSettings.DPISource.auto)
                    Text("固定 DPI").tag(LauncherSettings.DPISource.dpi)
                    Text("固定尺寸 (mm)").tag(LauncherSettings.DPISource.mm)
                } label: {
                    Label2(title: "物理尺寸參考源",
                           detail: "設定客機界面 UI 縮放比例。自動 = 根據此 Mac 屏幕上的實際視窗物理大小決定。",
                           now: false, key: .dpiSource)
                }
                if settings.dpiSource == .dpi {
                    Stepper(value: intBinding($settings.fixedDPI, 50...600), in: 50...600, step: 5) {
                        Text("DPI: \(settings.fixedDPI)")
                    }
                }
                if settings.dpiSource == .mm {
                    HStack {
                        Text("預設視窗對應的物理尺寸")
                        Spacer()
                        TextField("W", value: intBinding($settings.fixedWidthMM, 10...5000), format: .number.grouping(.never))
                            .frame(width: 60).multilineTextAlignment(.trailing)
                        Text("×")
                        TextField("H", value: intBinding($settings.fixedHeightMM, 10...5000), format: .number.grouping(.never))
                            .frame(width: 60).multilineTextAlignment(.trailing)
                        Text("mm")
                    }
                }
                Picker(selection: $settings.refreshRate) {
                    ForEach(DisplayTab.refreshRates, id: \.self) { Text("\($0) Hz").tag($0) }
                    if !DisplayTab.refreshRates.contains(settings.refreshRate) {
                        Text("\(settings.refreshRate) Hz").tag(settings.refreshRate)
                    }
                } label: {
                    Label2(title: "刷新率", now: false, key: .refreshRate)
                }
            }
            Section {
                Toggle(isOn: $settings.followWindowSize) {
                    Label2(title: "客機解析度跟隨視窗大小自動調整",
                           detail: "關閉時：客機保持固定解析度，畫面等比縮放至當前視窗。",
                           now: true)
                }
                Picker(selection: preset) {
                    ForEach(LauncherSettings.sizePresets) { Text(presetTitle($0)).tag($0.id) }
                    Divider()
                    Text(verbatim: "適應屏幕 (\(fit.0) × \(fit.1))").tag(LauncherSettings.fitPreset)
                    Text(verbatim: "自定義…").tag(LauncherSettings.customPreset)
                } label: {
                    Label2(title: "預設視窗大小",
                           detail: "客機像素 = 視窗點數（Retina Retina解析度下每邊翻倍）；最小 800 × 500。",
                           now: false, key: .windowSizePreset)
                }
                if settings.windowSizePreset == LauncherSettings.customPreset {
                    HStack {
                        Text("自定義大小")
                        Spacer()
                        TextField("W", value: intBinding($settings.windowWidth, 800...4094), format: .number.grouping(.never))
                            .frame(width: 64).multilineTextAlignment(.trailing)
                        Text("×")
                        TextField("H", value: intBinding($settings.windowHeight, 500...4094), format: .number.grouping(.never))
                            .frame(width: 64).multilineTextAlignment(.trailing)
                        Text("pt")
                    }
                }
                Toggle(isOn: $settings.retinaResolution) {
                    Label2(title: "Retina Retina超清解析度",
                           detail: settings.retinaResolution
                               ? "客機將獲得屏幕全像素渲染密度（Retina 屏幕下每點對應 2×2 真實像素），UI 縮放比例保持一致：文字極爲銳利，但遊戲需渲染 4 倍像素。推薦做法：保持此項關閉並開啟下方的 MetalFX 超級解析度，以極低的效能開銷將畫面 2 倍超分至 Retina 屏幕。"
                               : "關閉時：每點對應 1 個客機像素，等比放大至 Retina 屏幕（可由 MetalFX 超級解析度銳化）。開啟時：客機以屏幕全物理像素密度原生渲染。",
                           now: false, key: .retinaResolution)
                }
            }
            Section {
                Toggle(isOn: $settings.metalHUD) {
                    Label2(title: "Metal 效能監控 HUD",
                           detail: "在視窗右上角顯示 Apple 原生幀率效能面板：FPS、幀間隔、GPU 耗時、顯存佔用（快速鍵 Ctrl+Cmd+P，或在“視圖”菜單中切換）。",
                           now: true)
                }
                Toggle(isOn: $settings.superResolution) {
                    Label2(title: "MetalFX 超級解析度 (超分)",
                           detail: !Renderer.superResolutionSupported ? "此 Mac 的 GPU 不支持此功能。"
                               : "當視窗像素多於客機原生解析度時（如 Retina 屏幕、拉大視窗或全螢幕模式），使用 Apple MetalFX 硬體級升頻算法銳化畫面，代替普通的雙線性縮放。"
                                   + (settings.retinaResolution ? "（開啟 Retina 解析度時此選項作用有限）。" : ""), 
                           now: true)
                }
                .disabled(!Renderer.superResolutionSupported && !settings.superResolution)
            }
        }
    }
}

// MARK: - Mouse

private struct MouseTab: View {
    @EnvironmentObject var settings: LauncherSettings

    private func choice(_ g: LauncherSettings.Game) -> Binding<Int> {
        Binding(get: { g.autoCapture.map { $0 ? 1 : 2 } ?? 0 },
                set: { settings.setAutoCapture($0 == 0 ? nil : $0 == 1, for: g.appid) })
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.autoCaptureGames) {
                    Label2(title: "進入遊戲時自動捕獲滑鼠",
                           detail: "當遊戲處於焦點時，點擊視窗即可捕獲指針（提供第一人稱視角相對位移）。",
                           now: true, key: .autoCaptureGames)
                }
                LabeledContent("釋放滑鼠捕獲") { Text("快速鍵 Ctrl+Option（Ctrl+Cmd+G 可直接切換）").foregroundStyle(.secondary) }
                LabeledContent("Steam 界面與桌面") {
                    Text("滑鼠指針 1:1 跟隨 Mac 原生光標（絕對座標）").foregroundStyle(.secondary)
                }
            }
            Section {
                if settings.games.isEmpty {
                    Text("在 SteamOS 中運行過的遊戲將顯示在此處。")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.games) { g in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.name ?? "未知遊戲")
                            Text("App ID \(String(g.appid))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: choice(g)) {
                            Text(settings.globalAutoCapture ? "預設 (自動捕獲)" : "預設 (關閉)").tag(0)
                            Text("自動捕獲").tag(1)
                            Text("關閉").tag(2)
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            settings.removeGame(g.appid)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("清除此遊戲設定")
                    }
                }
            } header: {
                HStack {
                    Text("獨立遊戲配置")
                    Spacer()
                    Applies(now: true)
                }
            }
        }
    }
}

// MARK: - Controller

/// Connected GameController gamepads, updated on connect/disconnect.
final class ControllerMonitor: ObservableObject {
    @Published private(set) var controllers: [GCController] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reload() })
        }
        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        reload()
    }

    private func reload() { controllers = GamepadBridge.connected }
}

private struct ControllerTab: View {
    @EnvironmentObject var settings: LauncherSettings
    @EnvironmentObject var context: SettingsContext
    @StateObject private var monitor = ControllerMonitor()

    private var feeding: GCController? {
        monitor.controllers.first { GamepadBridge.identifier(of: $0) == settings.controllerID } ?? monitor.controllers.first
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.virtualPad) {
                    Label2(title: "虛擬控制器",
                           detail: "當 Mac 連接控制器時，自動爲 SteamOS 映射一個虛擬遊戲控制器。",
                           now: true, key: .virtualPad)
                }
                Picker(selection: $settings.padType) {
                    Text("自動識別").tag(LauncherSettings.PadType.auto)
                    Text("Xbox 360 控制器").tag(LauncherSettings.PadType.xbox360)
                    Text("DualSense (PS5 控制器)").tag(LauncherSettings.PadType.dualSense)
                    Text("DualShock 4 (PS4 控制器)").tag(LauncherSettings.PadType.dualShock4)
                } label: {
                    Label2(title: "在 SteamOS 中模擬爲",
                           detail: "決定 Steam 中的按鍵圖標與佈局。自動：根據物理控制器類型自動選擇（DualSense、DualShock 4 或 Xbox 360）。支持按鍵、搖桿、扳機和震動（觸摸板、陀螺儀和燈條僅在 DualSense 直通模式下支持）。",
                           now: true, key: .padType)
                }
                .disabled(!settings.virtualPad)
                Toggle(isOn: $settings.dualSensePassthrough) {
                    Label2(title: "開啟 DualSense 原生直通",
                           detail: "當 DualSense 識別爲 DualSense 時，SteamOS 將直接獲取完整控制器功能：觸摸板、體感傳感器、指示燈條、靜音按鍵及燈光、觸覺反饋及自適應扳機（體驗如同 Steam Deck 原生控制器）。下方的按鍵互換和死區設定在直通模式下不生效。",
                           now: true)
                }
                .disabled(!settings.virtualPad)
                Picker(selection: $settings.controllerID) {
                    Text("首個連接的控制器").tag("")
                    ForEach(monitor.controllers, id: \.self) { c in
                        Text(GamepadBridge.displayName(of: c)).tag(GamepadBridge.identifier(of: c))
                    }
                    if !settings.controllerID.isEmpty,
                       !monitor.controllers.contains(where: { GamepadBridge.identifier(of: $0) == settings.controllerID }) {
                        Text("\(settings.controllerID.replacingOccurrences(of: "|", with: " · ")) (未連接)")
                            .tag(settings.controllerID)
                    }
                } label: {
                    Label2(title: "指定映射物理控制器", now: true)
                }
                Toggle(isOn: $settings.swapABXY) {
                    Label2(title: "交換 A/B 與 X/Y 按鍵", detail: "適用於任天堂風格的按鍵鍵位佈局。", now: true)
                }
                VStack(alignment: .leading) {
                    HStack {
                        Label2(title: "搖桿死區", now: true)
                        Spacer()
                        Text("\(settings.stickDeadzone) %").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { Double(settings.stickDeadzone) },
                                          set: { settings.stickDeadzone = Int($0.rounded()) }), in: 0...30, step: 1)
                }
            }
            Section {
                if monitor.controllers.isEmpty {
                    Text("未檢測到已連接的控制器。請在“系統設定 › 藍牙”中配對或通過 USB 線纜插入連接。")
                        .foregroundStyle(.secondary)
                }
                ForEach(monitor.controllers, id: \.self) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(GamepadBridge.displayName(of: c)).font(.headline)
                            if c === feeding && context.vmHasPad {
                                Text("正在驅動程式虛擬控制器").font(.caption)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            }
                            Spacer()
                            if let b = c.battery {
                                Text("\(Int(b.batteryLevel * 100)) %").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let pad = c.extendedGamepad { PadTestView(pad: pad) }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text("已連接控制器 — 實時輸入測試")
                    Spacer()
                    Applies(now: true)
                }
            }
        }
    }
}

/// Live sticks / triggers / buttons of one controller (polled at display rate; does not take
/// the controller's value handler, which feeds the guest).
private struct PadTestView: View {
    let pad: GCExtendedGamepad

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            HStack(alignment: .center, spacing: 18) {
                StickView(x: pad.leftThumbstick.xAxis.value, y: pad.leftThumbstick.yAxis.value,
                          pressed: pad.leftThumbstickButton?.isPressed ?? false, label: "L")
                VStack(spacing: 4) {
                    TriggerView(label: "LT", value: pad.leftTrigger.value)
                    TriggerView(label: "RT", value: pad.rightTrigger.value)
                }
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Dot("LB", pad.leftShoulder.isPressed); Dot("RB", pad.rightShoulder.isPressed)
                    }
                    HStack(spacing: 4) {
                        Dot("◀︎", pad.dpad.left.isPressed); Dot("▲", pad.dpad.up.isPressed)
                        Dot("▼", pad.dpad.down.isPressed); Dot("▶︎", pad.dpad.right.isPressed)
                    }
                    HStack(spacing: 4) {
                        Dot("View", pad.buttonOptions?.isPressed ?? false); Dot("Home", pad.buttonHome?.isPressed ?? false)
                        Dot("Menu", pad.buttonMenu.isPressed)
                    }
                }
                VStack(spacing: 2) {
                    Dot("Y", pad.buttonY.isPressed)
                    HStack(spacing: 2) { Dot("X", pad.buttonX.isPressed); Dot("B", pad.buttonB.isPressed) }
                    Dot("A", pad.buttonA.isPressed)
                }
                StickView(x: pad.rightThumbstick.xAxis.value, y: pad.rightThumbstick.yAxis.value,
                          pressed: pad.rightThumbstickButton?.isPressed ?? false, label: "R")
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct StickView: View {
    let x: Float, y: Float, pressed: Bool, label: String
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 1)
            Circle().fill(pressed ? Color.accentColor : Color.primary.opacity(0.75))
                .frame(width: 12, height: 12)
                .offset(x: CGFloat(x) * 20, y: CGFloat(-y) * 20)
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary).offset(y: 22)
        }
        .frame(width: 52, height: 52)
    }
}

private struct TriggerView: View {
    let label: String, value: Float
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).frame(width: 18)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(Color.accentColor).frame(width: 46 * CGFloat(max(0, min(1, value))))
            }
            .frame(width: 46, height: 6)
        }
    }
}

private struct Dot: View {
    let label: String, on: Bool
    init(_ label: String, _ on: Bool) { self.label = label; self.on = on }
    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .frame(minWidth: 18, minHeight: 16)
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(on ? Color.accentColor : Color.secondary.opacity(0.18)))
            .foregroundStyle(on ? Color.white : Color.primary)
    }
}

// MARK: - Sound

/// CoreAudio output devices, refreshed when devices or the default output change.
final class AudioDeviceMonitor: ObservableObject {
    @Published private(set) var devices: [AudioDevices.Device] = []
    @Published private(set) var defaultName: String?
    private var listener: AudioObjectPropertyListenerBlock?

    init() {
        reload()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.reload() }
        listener = block
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        }
    }

    deinit {
        guard let listener else { return }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
        }
    }

    private func reload() {
        devices = AudioDevices.outputs()
        defaultName = AudioDevices.defaultOutputName()
    }
}

private struct SoundTab: View {
    @EnvironmentObject var settings: LauncherSettings
    @EnvironmentObject var context: SettingsContext
    @StateObject private var monitor = AudioDeviceMonitor()

    private var probe: SoundControl { context.sound ?? SoundControl() }

    /// Why the live controls cannot act on this VM (nil = they do).
    private var liveProblem: String? {
        if let r = probe.missingAPIReason { return r }
        if context.sound == nil { return "當前視窗未運行虛擬機。" }
        if !context.vmHasSound { return context.sound?.noDeviceReason ?? "本次啓動未啟用音訊設備。" }
        return nil
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.soundEnabled) {
                    Label2(title: "音訊輸出", detail: "客機虛擬音訊設備 (virtio-snd → CoreAudio)。",
                           now: false, key: .soundEnabled)
                }
            }
            Section {
                Picker(selection: $settings.soundOutputUID) {
                    Text("系統預設" + (monitor.defaultName.map { " (\($0))" } ?? "")).tag("")
                    ForEach(monitor.devices) { Text($0.name).tag($0.uid) }
                    if !settings.soundOutputUID.isEmpty, !monitor.devices.contains(where: { $0.uid == settings.soundOutputUID }) {
                        Text("\(settings.soundOutputUID) (未連接)").tag(settings.soundOutputUID)
                    }
                } label: {
                    Label2(title: "音訊輸出設備", detail: "系統預設設備將自動跟隨 macOS 系統設定的變更。", now: true)
                }
                .disabled(!probe.canSelectDevice)
                VStack(alignment: .leading) {
                    HStack {
                        Label2(title: "音量", detail: "在 SteamOS 系統音量基礎上進行二次調節。", now: true)
                        Spacer()
                        Text(settings.soundMute ? "已靜音" : "\(Int((settings.soundVolume * 100).rounded())) %")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $settings.soundVolume, in: 0...1)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }
                .disabled(!probe.canSetVolume)
                Toggle(isOn: $settings.soundMute) { Label2(title: "靜音", now: true) }
                    .disabled(!probe.canSetVolume)
                Picker(selection: $settings.soundLatency) {
                    Text("低延遲 (10 ms)").tag(LauncherSettings.Latency.low)
                    Text("正常 (20 ms)").tag(LauncherSettings.Latency.normal)
                    Text("安全緩衝 (60 ms)").tag(LauncherSettings.Latency.safe)
                } label: {
                    Label2(title: "緩衝區大小", detail: "數值越低延遲越小；“安全緩衝”可避免高負載下的爆音。", now: true)
                }
                .disabled(!probe.canSetBuffer)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let p = liveProblem {
                        Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    Text("麥克風：客機將錄製 macOS 系統預設輸入音訊；首次使用時 macOS 會提示授予麥克風權限。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Advanced

private struct AdvancedTab: View {
    @EnvironmentObject var settings: LauncherSettings
    @EnvironmentObject var context: SettingsContext
    @State private var confirmReset = false
    @StateObject private var password = GuestPasswordModel()
    static let maxCPUs = ProcessInfo.processInfo.activeProcessorCount
    static let maxGiB = max(4, Int(ProcessInfo.processInfo.physicalMemory >> 30) - 4)
    static let host = VMSizing.Host.current
    static let autoCPUs = VMSizing.autoCPUs(host)
    static let autoGiB = VMSizing.autoMemMiB(host) / 1024

    /// The disk the next start boots (its generated SSH password is shown): Settings value, else
    /// the running VM's disk, else the default location.
    private var nextDisk: String? {
        settings.diskImage.isEmpty ? (context.diskPath ?? AppBundle.defaultDisk()) : settings.diskImage
    }

    private var diskStatus: (String, Bool) {
        if !settings.diskImage.isEmpty {
            let ok = FileManager.default.isReadableFile(atPath: settings.diskImage)
            return ((settings.diskImage as NSString).abbreviatingWithTildeInPath + (ok ? "" : " (not found)"), ok)
        }
        if let d = AppBundle.defaultDisk() { return ("預設: " + (d as NSString).abbreviatingWithTildeInPath, true) }
        return ("預設: 未找到", false)
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(get: { settings.cpus == 0 },
                                          set: { settings.cpus = $0 ? 0 : min(AdvancedTab.maxCPUs, AdvancedTab.autoCPUs) })) {
                    Text("自動（此 Mac 推薦 \(AdvancedTab.autoCPUs) 核心）").tag(true)
                    Text("自定義").tag(false)
                } label: {
                    Label2(title: "虛擬 CPU (vCPU)", detail: "自動：按此 Mac 效能核心數一對一分配（2 到 8 核）。",
                           now: false, key: .cpus)
                }
                if settings.cpus > 0 {
                    Stepper(value: intBinding($settings.cpus, 1...AdvancedTab.maxCPUs), in: 1...AdvancedTab.maxCPUs) {
                        HStack {
                            Text("自定義 vCPU 核心數")
                            Spacer()
                            Text("\(settings.cpus)").monospacedDigit()
                        }
                    }
                    if let warning = VMSizing.cpuWarning(cpus: settings.cpus, host: AdvancedTab.host) {
                        SizeWarning(text: warning)
                    }
                }
                Picker(selection: Binding(get: { settings.memMiB == 0 },
                                          set: { settings.memMiB = $0 ? 0 : min(AdvancedTab.maxGiB, AdvancedTab.autoGiB) * 1024 })) {
                    Text("自動（此 Mac 推薦 \(AdvancedTab.autoGiB) GB）").tag(true)
                    Text("Custom").tag(false)
                } label: {
                    Label2(title: "虛擬機記憶體 (RAM)", detail: "自動：分配此 Mac 物理記憶體的一半（4 到 16 GB）。因 Apple 芯片採用統一記憶體架構，GPU 共享相同記憶體，剩餘記憶體將保留給 macOS 系統及遊戲圖形顯存。",
                           now: false, key: .memMiB)
                }
                Text("GPU 顯存預算：\(VMSizing.gpuBudgetMiB(memMiB: settings.memMiB > 0 ? settings.memMiB : AdvancedTab.autoGiB * 1024, host: AdvancedTab.host)) MiB。macOS 系統及驅動程式保留：\(VMSizing.hostReserveMiB(AdvancedTab.host)) MiB。")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.memMiB > 0 {
                    Stepper(value: Binding(get: { settings.memMiB / 1024 },
                                           set: { settings.memMiB = min(AdvancedTab.maxGiB, max(2, $0)) * 1024 }),
                            in: 2...AdvancedTab.maxGiB) {
                        HStack {
                            Text("自定義記憶體大小")
                            Spacer()
                            Text("\(settings.memMiB / 1024) GB").monospacedDigit()
                        }
                    }
                    if let warning = VMSizing.memWarning(memMiB: settings.memMiB, host: AdvancedTab.host) {
                        SizeWarning(text: warning)
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { settings.sshEnabled }, set: { on in
                    settings.sshEnabled = on
                    if on { password.ensure() }
                })) {
                    Label2(title: "開啟 SSH 服務", detail: "關閉時：Mac 上不監聽端口且 SteamOS 中停用 sshd 服務。開啟時：自動爲 steamos 用戶生成訪問密碼（關閉 SSH 時仍保留該密碼）。",
                           now: false, key: .sshEnabled)
                }
                HStack {
                    Label2(title: "SSH 端口", now: false, key: .sshPort)
                    Spacer()
                    TextField("", value: Binding(get: { settings.sshPort },
                                                 set: { if (1024...65535).contains($0) { settings.sshPort = $0 } }),
                              format: .number.grouping(.never))
                        .frame(width: 70).multilineTextAlignment(.trailing)
                }
                .disabled(!settings.sshEnabled)
                if password.disk == nil {
                    LabeledContent("登錄信息") { Text("未選擇磁碟鏡像").foregroundStyle(.secondary) }
                } else if let state = password.state {
                    LabeledContent("用戶名") { Text(GuestPassword.user).textSelection(.enabled) }
                    LabeledContent("密碼") {
                        HStack {
                            Text(password.shown ?? "••••••••••••••••••••").font(.body.monospaced()).textSelection(.enabled)
                            Button(password.shown == nil ? "顯示" : "隱藏") { password.toggleShown() }
                            Button("複製") { password.copy(password: true, port: settings.sshPort) }
                        }
                    }
                    LabeledContent("連接命令") {
                        HStack {
                            Text("ssh -p \(settings.sshPort) \(GuestPassword.user)@127.0.0.1").font(.callout.monospaced())
                                .textSelection(.enabled)
                            Button("複製") { password.copy(password: false, port: settings.sshPort) }
                        }
                    }
                    HStack {
                        Text(state == .applied ? "密碼已在 SteamOS 中應用" : "密碼將在下次啓動時應用")
                            .font(.caption).foregroundStyle(state == .applied ? Color.secondary : Color.orange)
                        Spacer()
                        Button("重新生成密碼") { password.regenerate() }
                    }
                } else {
                    HStack {
                        Text("此磁碟未生成專用密碼（使用 Docker 構建的磁碟預設密碼爲 steamos）。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("生成新密碼") { password.ensure() }
                    }
                }
                if let error = password.error { Text(error).font(.caption).foregroundStyle(.red) }
                Toggle(isOn: $settings.network) {
                    Label2(title: "虛擬網絡連接", detail: "關閉時：不啟用 virtio-net / gvproxy（客機完全離線，SSH 亦不可用）。",
                           now: false, key: .network)
                }
                Toggle(isOn: $settings.lanRemotePlay) {
                    Label2(title: "局域網遠程暢玩 (Remote Play)",
                           detail: "允許同局域網內的 Steam Link 發現此虛擬機。將在 Mac 打開 UDP 27031–27036 與 TCP 27036–27037 端口。請允許“本地網絡”權限；若 Mac 原生 Steam 佔用上述端口請先結束。",
                           now: false, key: .lanRemotePlay)
                }
                .disabled(!settings.network)
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label2(title: "虛擬磁碟鏡像", detail: "SteamOS 原始 GPT 磁碟鏡像，原地直接讀寫（不復制）。若 Steam 提示空間不足，“擴充容量磁碟…”可爲遊戲擴充分區容量而無需重建磁碟。Mac 上的可用空間不會自動擴大 SteamOS 內部容量。",
                           now: false, key: .diskImage)
                    HStack {
                        Text(diskStatus.0)
                            .font(.callout).foregroundStyle(diskStatus.1 ? Color.secondary : Color.red)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        Button("新增磁碟…") { CreateDiskWindowController.show(settings: settings) }
                        Button("擴充容量磁碟…") { growDisk() }.disabled(nextDisk == nil)
                        Button("選擇已有磁碟…") { chooseDisk() }
                        Button("使用預設磁碟") { settings.diskImage = "" }.disabled(settings.diskImage.isEmpty)
                    }
                }
                Picker(selection: $settings.steamClient) {
                    ForEach(LauncherSettings.SteamClient.allCases) { Text(SteamClientPicker.itemTitle($0)).tag($0) }
                } label: {
                    Label2(title: "Steam 客戶端通道",
                           detail: settings.steamClient.detail + " " + LauncherSettings.SteamClient.switchNote,
                           now: false, key: .steamClient)
                }
                Picker(selection: $settings.vulkanDriver) {
                    ForEach(LauncherSettings.VulkanDriver.allCases) { d in
                        Text(d.title).tag(d)
                            .disabled(d.unavailableReason != nil && d != settings.vulkanDriver)
                    }
                } label: {
                    Label2(title: "Vulkan 圖形驅動程式",
                           detail: settings.vulkanDriver.detail + " " + LauncherSettings.VulkanDriver.switchNote
                               + (settings.vulkanDriver.unavailableReason.map {
                                   " 當前不可用: \($0)；將使用 MoltenVK。" } ?? ""),
                           now: false, key: .vulkanDriver)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("重設所有設定…", role: .destructive) { confirmReset = true }
                }
            }
        }
        .onAppear { password.load(disk: nextDisk) }
        .onChange(of: settings.diskImage) { password.load(disk: nextDisk) }
        .confirmationDialog("確定要將 FX Steam Launcher 的所有設定重設爲預設值嗎？", isPresented: $confirmReset) {
            Button("重設", role: .destructive) { settings.resetAll() }
        } message: {
            Text("針對單個遊戲的滑鼠設定和已選定的磁碟鏡像路徑也將被清除。")
        }
    }

    private func growDisk() {
        guard let path = nextDisk else { return }
        do {
            let table = try GPT.read(path: path)
            guard let home = table.entries.last, home.name == "home" else { throw OptionError("不是有效的 SteamOS 磁碟") }
            let current = Double(home.sectors * 512) / Double(1 << 30)
            let alert = NSAlert()
            alert.messageText = "擴充容量 SteamOS 磁碟"
            let running = context.diskPath == path && context.restart != nil
            alert.informativeText = String(format: "遊戲分區當前容量爲 %.1f GiB。請輸入更大的 home 分區容量（單位 GiB，最大支持 4096）。此操作絕不會縮小或刪除現有數據。APFS / Mac OS 擴展格式僅在寫入時佔用 Mac 空間；exFAT 則會立即預分配全部新增空間並需要足夠的剩餘空間。" + (running ? "SteamOS 將正常關機，在停機狀態下自動完成磁碟擴充容量，隨後重新啓動。" : "SteamOS 必須處於停止狀態。分區與文件系統將在下次開機時完成擴充容量。"), current)
            let field = NSTextField(string: String(min(4096, Int(ceil(current)) + 64)))
            field.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: running ? "擴充容量並重啓" : "開始擴充容量")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard let size = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw OptionError("請輸入整數的 GiB 容量")
            }
            let request = try DiskGrower.request(path: path, homeGiB: size)
            if running, let runDir = Supervisor.runDir {
                try DiskGrower.queue(request, runDir: runDir)
                context.restart?()
            } else {
                try DiskGrower.grow(request)
                let done = NSAlert()
                done.messageText = "SteamOS 磁碟已擴充容量"
                done.informativeText = "請啓動 SteamOS，系統將在開機階段自動擴展 home 分區與文件系統。"
                done.runModal()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "SteamOS 磁碟擴充容量失敗"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    private func chooseDisk() {
        let panel = NSOpenPanel()
        panel.title = "選擇 SteamOS 磁碟鏡像文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if !settings.diskImage.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (settings.diskImage as NSString).deletingLastPathComponent)
        }
        if panel.runModal() == .OK, let url = panel.url { settings.diskImage = url.path }
    }
}

/// Advanced tab: an inline warning under a custom VM size.
private struct SizeWarning: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings > Advanced view of the next-start disk's generated SSH password (GuestPassword).
/// The plaintext is read from the Keychain only for Show/Copy.
private final class GuestPasswordModel: ObservableObject {
    @Published private(set) var disk: String?
    @Published private(set) var state: GuestPassword.State?
    @Published private(set) var shown: String?
    @Published private(set) var error: String?

    func load(disk path: String?) {
        disk = path.flatMap { GuestPassword.identity(ofDisk: $0) }
        shown = nil
        error = nil
        refresh()
    }

    private func refresh() { state = disk.flatMap { GuestPassword.state(disk: $0) } }

    /// SSH switched on: a disk without a generated password gets one.
    func ensure() {
        guard let disk, GuestPassword.state(disk: disk) == nil else { return }
        regenerate()
    }

    func regenerate() {
        guard let disk else { return }
        do {
            let pw = try GuestPassword.generate(disk: disk)
            if shown != nil { shown = pw }
            error = nil
        } catch {
            self.error = "\(error)"
        }
        refresh()
    }

    func toggleShown() {
        if shown != nil { shown = nil; return }
        guard let disk else { return }
        shown = GuestPassword.password(disk: disk)
        if shown == nil { error = "無法從鑰匙串 (Keychain) 讀取密碼。" }
    }

    func copy(password: Bool, port: Int) {
        let text: String?
        if password { text = disk.flatMap { GuestPassword.password(disk: $0) } }
        else { text = "ssh -p \(port) \(GuestPassword.user)@127.0.0.1" }
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
