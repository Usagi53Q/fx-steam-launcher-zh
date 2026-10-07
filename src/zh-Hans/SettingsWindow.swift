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
            case .general: return "通用"
            case .display: return "显示"
            case .mouse: return "鼠标"
            case .controller: return "手柄"
            case .sound: return "音频"
            case .advanced: return "高级"
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
            Text(now ? "立即生效" : "下次启动生效")
                .font(.caption)
                .foregroundStyle(now ? Color.secondary : Color.orange.opacity(0.9))
            if let key, let flag = settings.overrides[key] {
                Text("已被命令行覆盖 (\(flag))")
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
                    Text(context.restartRequested ? "正在重启虚拟机…" : "部分设置将在下次启动时生效。")
                        .font(.callout.weight(.medium))
                    Text(context.restart == nil ? "当前窗口未运行虚拟机。"
                         : "SteamOS 将正常关机并以新设置重新启动。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重启虚拟机以应用") {
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
                    Label2(title: "显示开机与关机进度遮罩",
                           detail: "在 SteamOS 启动、重启和关机时显示全窗口进度遮罩。关闭或点击后显示为精简进度胶囊。", now: true)
                }
                Toggle(isOn: $settings.showStallIndicator) {
                    Label2(title: "GPU 空闲时显示加载提示",
                           detail: "当 SteamOS 超过 2 秒无 GPU 渲染任务时（如加载资源、编译着色器），在画面上显示“仍在运行”提示卡片。",
                           now: true)
                }
                Toggle(isOn: $settings.openFullscreen) {
                    Label2(title: "启动时以全屏模式打开", now: false, key: .openFullscreen)
                }
            }
            Section {
                Picker(selection: $settings.closeAction) {
                    Text("关闭 SteamOS").tag(LauncherSettings.CloseAction.shutDown)
                    Text("挂起休眠（在后台保持运行）").tag(LauncherSettings.CloseAction.suspend)
                } label: {
                    Label2(title: "关闭窗口时",
                           detail: "挂起会将 SteamOS 及当前运行的游戏立即冻结并保留在内存中；点击 Dock 图标或菜单栏中的“恢复”即可从离开处继续。挂起状态在启动器运行期间保持：退出启动器或重启 Mac 将直接关闭 SteamOS。",
                           now: true)
                }
            }
            Section {
                Toggle(isOn: $settings.followMacTime) {
                    Label2(title: "同步 Mac 的时区与时间格式",
                           detail: "每次开机自动将 Mac 的时区与 12/24 小时制同步给 SteamOS，除非在 SteamOS 或 Steam 内部主动更改。",
                           now: false, key: .followMacTime)
                }
            }
            Section {
                Toggle(isOn: $settings.shareClipboard) {
                    Label2(title: "与 SteamOS 共享剪贴板",
                           detail: "在 Mac 上复制的文本和图片可直接粘贴至 SteamOS（Ctrl+V），反之亦然；最高支持 1 MB 文本与 16 MB 图片。支持桌面模式。",
                           now: true)
                }
                Toggle(isOn: $settings.shareConcealedClipboard) {
                    Label2(title: "包含密码管理器隐藏内容",
                           detail: "除非开启此项，否则类似 1Password、Bitwarden 或 KeePassXC 标记为隐藏或临时密码的内容将保留在 Mac 上而不被同步。",
                           now: true)
                }
                .disabled(!settings.shareClipboard)
            }
            Section {
                Toggle(isOn: $settings.muteInBackground) {
                    Label2(title: "静音", detail: "淡出静音；切换回前台时恢复原音量。", now: true)
                }
                Toggle(isOn: $settings.pauseInBackground) {
                    Label2(title: "暂停游戏",
                           detail: "冻结当前焦点的游戏进程（Steam 本身、后台下载和更新仍会继续运行）。联机网游在暂停时可能会断开连接。",
                           now: true)
                }
            } header: {
                Text("当启动器处于后台时")
            }
            Section {
                CrashReportsToggle(settings: settings, showsApplies: true)
                Toggle(isOn: $settings.checkForUpdates) {
                    Label2(title: "启动时检查更新",
                           detail: "至多每 6 小时向 GitHub (api.github.com) 查询最新版本；仅发送应用程序版本号。"
                               + (CrashReporting.buildKind == .development
                                   ? "开发版本在启动时不自动检查；可通过 菜单栏 FX Steam Launcher > 检查更新… 手动查询。"
                                   : "可通过 菜单栏 FX Steam Launcher > 检查更新… 随时手动查询。"),
                           now: true)
                }
                Toggle(isOn: $settings.perfStats) {
                    Label2(title: "记录帧率与节奏统计日志",
                           detail: "每 5 秒记录一次：客机画面刷新与渲染间隔、延迟、掉帧数。",
                           now: true, key: .perfStats)
                }
            } footer: {
                if AppBundle.resources != nil {
                    Text("日志：\((AppBundle.logPath as NSString).abbreviatingWithTildeInPath)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("反馈问题")
                        Text("描述遇到的问题并将选定的诊断日志发送给开发者（关闭崩溃报告时亦可使用）。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("反馈问题…") { context.reportProblem?() }
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
        "\(p.width) × \(p.height) (\(p.label))" + (p.width > fit.0 || p.height > fit.1 ? " — 超出当前屏幕" : "")
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.dpiSource) {
                    Text("自动（根据屏幕）").tag(LauncherSettings.DPISource.auto)
                    Text("固定 DPI").tag(LauncherSettings.DPISource.dpi)
                    Text("固定尺寸 (mm)").tag(LauncherSettings.DPISource.mm)
                } label: {
                    Label2(title: "物理尺寸参考源",
                           detail: "设置客机界面 UI 缩放比例。自动 = 根据此 Mac 屏幕上的实际窗口物理大小决定。",
                           now: false, key: .dpiSource)
                }
                if settings.dpiSource == .dpi {
                    Stepper(value: intBinding($settings.fixedDPI, 50...600), in: 50...600, step: 5) {
                        Text("DPI: \(settings.fixedDPI)")
                    }
                }
                if settings.dpiSource == .mm {
                    HStack {
                        Text("默认窗口对应的物理尺寸")
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
                    Label2(title: "客机分辨率跟随窗口大小自动调整",
                           detail: "关闭时：客机保持固定分辨率，画面等比缩放至当前窗口。",
                           now: true)
                }
                Picker(selection: preset) {
                    ForEach(LauncherSettings.sizePresets) { Text(presetTitle($0)).tag($0.id) }
                    Divider()
                    Text(verbatim: "适应屏幕 (\(fit.0) × \(fit.1))").tag(LauncherSettings.fitPreset)
                    Text(verbatim: "自定义…").tag(LauncherSettings.customPreset)
                } label: {
                    Label2(title: "默认窗口大小",
                           detail: "客机像素 = 窗口点数（Retina 视网膜分辨率下每边翻倍）；最小 800 × 500。",
                           now: false, key: .windowSizePreset)
                }
                if settings.windowSizePreset == LauncherSettings.customPreset {
                    HStack {
                        Text("自定义大小")
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
                    Label2(title: "Retina 视网膜超清分辨率",
                           detail: settings.retinaResolution
                               ? "客机将获得屏幕全像素渲染密度（Retina 屏幕下每点对应 2×2 真实像素），UI 缩放比例保持一致：文字极为锐利，但游戏需渲染 4 倍像素。推荐做法：保持此项关闭并开启下方的 MetalFX 超级分辨率，以极低的性能开销将画面 2 倍超分至 Retina 屏幕。"
                               : "关闭时：每点对应 1 个客机像素，等比放大至 Retina 屏幕（可由 MetalFX 超级分辨率锐化）。开启时：客机以屏幕全物理像素密度原生渲染。",
                           now: false, key: .retinaResolution)
                }
            }
            Section {
                Toggle(isOn: $settings.metalHUD) {
                    Label2(title: "Metal 性能监控 HUD",
                           detail: "在窗口右上角显示 Apple 原生帧率性能面板：FPS、帧间隔、GPU 耗时、显存占用（快捷键 Ctrl+Cmd+P，或在“视图”菜单中切换）。",
                           now: true)
                }
                Toggle(isOn: $settings.superResolution) {
                    Label2(title: "MetalFX 超级分辨率 (超分)",
                           detail: !Renderer.superResolutionSupported ? "此 Mac 的 GPU 不支持此功能。"
                               : "当窗口像素多于客机原生分辨率时（如 Retina 屏幕、拉大窗口或全屏模式），使用 Apple MetalFX 硬件级升频算法锐化画面，代替普通的双线性缩放。"
                                   + (settings.retinaResolution ? "（开启 Retina 分辨率时此选项作用有限）。" : ""), 
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
                    Label2(title: "进入游戏时自动捕获鼠标",
                           detail: "当游戏处于焦点时，点击窗口即可捕获指针（提供第一人称视角相对位移）。",
                           now: true, key: .autoCaptureGames)
                }
                LabeledContent("释放鼠标捕获") { Text("快捷键 Ctrl+Option（Ctrl+Cmd+G 可直接切换）").foregroundStyle(.secondary) }
                LabeledContent("Steam 界面与桌面") {
                    Text("鼠标指针 1:1 跟随 Mac 原生光标（绝对坐标）").foregroundStyle(.secondary)
                }
            }
            Section {
                if settings.games.isEmpty {
                    Text("在 SteamOS 中运行过的游戏将显示在此处。")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.games) { g in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.name ?? "未知游戏")
                            Text("App ID \(String(g.appid))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: choice(g)) {
                            Text(settings.globalAutoCapture ? "默认 (自动捕获)" : "默认 (关闭)").tag(0)
                            Text("自动捕获").tag(1)
                            Text("关闭").tag(2)
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            settings.removeGame(g.appid)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("清除此游戏设置")
                    }
                }
            } header: {
                HStack {
                    Text("独立游戏配置")
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
                    Label2(title: "虚拟手柄",
                           detail: "当 Mac 连接手柄时，自动为 SteamOS 映射一个虚拟游戏手柄。",
                           now: true, key: .virtualPad)
                }
                Picker(selection: $settings.padType) {
                    Text("自动识别").tag(LauncherSettings.PadType.auto)
                    Text("Xbox 360 手柄").tag(LauncherSettings.PadType.xbox360)
                    Text("DualSense (PS5 手柄)").tag(LauncherSettings.PadType.dualSense)
                    Text("DualShock 4 (PS4 手柄)").tag(LauncherSettings.PadType.dualShock4)
                } label: {
                    Label2(title: "在 SteamOS 中模拟为",
                           detail: "决定 Steam 中的按键图标与布局。自动：根据物理手柄类型自动选择（DualSense、DualShock 4 或 Xbox 360）。支持按键、摇杆、扳机和震动（触摸板、陀螺仪和灯条仅在 DualSense 直通模式下支持）。",
                           now: true, key: .padType)
                }
                .disabled(!settings.virtualPad)
                Toggle(isOn: $settings.dualSensePassthrough) {
                    Label2(title: "开启 DualSense 原生直通",
                           detail: "当 DualSense 识别为 DualSense 时，SteamOS 将直接获取完整手柄功能：触摸板、体感传感器、指示灯条、静音按键及灯光、触觉反馈及自适应扳机（体验如同 Steam Deck 原生手柄）。下方的按键互换和死区设置在直通模式下不生效。",
                           now: true)
                }
                .disabled(!settings.virtualPad)
                Picker(selection: $settings.controllerID) {
                    Text("首个连接的手柄").tag("")
                    ForEach(monitor.controllers, id: \.self) { c in
                        Text(GamepadBridge.displayName(of: c)).tag(GamepadBridge.identifier(of: c))
                    }
                    if !settings.controllerID.isEmpty,
                       !monitor.controllers.contains(where: { GamepadBridge.identifier(of: $0) == settings.controllerID }) {
                        Text("\(settings.controllerID.replacingOccurrences(of: "|", with: " · ")) (未连接)")
                            .tag(settings.controllerID)
                    }
                } label: {
                    Label2(title: "指定映射物理手柄", now: true)
                }
                Toggle(isOn: $settings.swapABXY) {
                    Label2(title: "交换 A/B 与 X/Y 按键", detail: "适用于任天堂风格的按键键位布局。", now: true)
                }
                VStack(alignment: .leading) {
                    HStack {
                        Label2(title: "摇杆死区", now: true)
                        Spacer()
                        Text("\(settings.stickDeadzone) %").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { Double(settings.stickDeadzone) },
                                          set: { settings.stickDeadzone = Int($0.rounded()) }), in: 0...30, step: 1)
                }
            }
            Section {
                if monitor.controllers.isEmpty {
                    Text("未检测到已连接的手柄。请在“系统设置 › 蓝牙”中配对或通过 USB 线缆插入连接。")
                        .foregroundStyle(.secondary)
                }
                ForEach(monitor.controllers, id: \.self) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(GamepadBridge.displayName(of: c)).font(.headline)
                            if c === feeding && context.vmHasPad {
                                Text("正在驱动虚拟手柄").font(.caption)
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
                    Text("已连接手柄 — 实时输入测试")
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
        if context.sound == nil { return "当前窗口未运行虚拟机。" }
        if !context.vmHasSound { return context.sound?.noDeviceReason ?? "本次启动未启用音频设备。" }
        return nil
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.soundEnabled) {
                    Label2(title: "音频输出", detail: "客机虚拟音频设备 (virtio-snd → CoreAudio)。",
                           now: false, key: .soundEnabled)
                }
            }
            Section {
                Picker(selection: $settings.soundOutputUID) {
                    Text("系统默认" + (monitor.defaultName.map { " (\($0))" } ?? "")).tag("")
                    ForEach(monitor.devices) { Text($0.name).tag($0.uid) }
                    if !settings.soundOutputUID.isEmpty, !monitor.devices.contains(where: { $0.uid == settings.soundOutputUID }) {
                        Text("\(settings.soundOutputUID) (未连接)").tag(settings.soundOutputUID)
                    }
                } label: {
                    Label2(title: "音频输出设备", detail: "系统默认设备将自动跟随 macOS 系统设置的变更。", now: true)
                }
                .disabled(!probe.canSelectDevice)
                VStack(alignment: .leading) {
                    HStack {
                        Label2(title: "音量", detail: "在 SteamOS 系统音量基础上进行二次调节。", now: true)
                        Spacer()
                        Text(settings.soundMute ? "已静音" : "\(Int((settings.soundVolume * 100).rounded())) %")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $settings.soundVolume, in: 0...1)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }
                .disabled(!probe.canSetVolume)
                Toggle(isOn: $settings.soundMute) { Label2(title: "静音", now: true) }
                    .disabled(!probe.canSetVolume)
                Picker(selection: $settings.soundLatency) {
                    Text("低延迟 (10 ms)").tag(LauncherSettings.Latency.low)
                    Text("正常 (20 ms)").tag(LauncherSettings.Latency.normal)
                    Text("安全缓冲 (60 ms)").tag(LauncherSettings.Latency.safe)
                } label: {
                    Label2(title: "缓冲区大小", detail: "数值越低延迟越小；“安全缓冲”可避免高负载下的爆音。", now: true)
                }
                .disabled(!probe.canSetBuffer)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let p = liveProblem {
                        Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    Text("麦克风：客机将录制 macOS 系统默认输入音频；首次使用时 macOS 会提示授予麦克风权限。")
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
        if let d = AppBundle.defaultDisk() { return ("默认: " + (d as NSString).abbreviatingWithTildeInPath, true) }
        return ("默认: 未找到", false)
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(get: { settings.cpus == 0 },
                                          set: { settings.cpus = $0 ? 0 : min(AdvancedTab.maxCPUs, AdvancedTab.autoCPUs) })) {
                    Text("自动（此 Mac 推荐 \(AdvancedTab.autoCPUs) 核心）").tag(true)
                    Text("自定义").tag(false)
                } label: {
                    Label2(title: "虚拟 CPU (vCPU)", detail: "自动：按此 Mac 性能核心数一对一分配（2 到 8 核）。",
                           now: false, key: .cpus)
                }
                if settings.cpus > 0 {
                    Stepper(value: intBinding($settings.cpus, 1...AdvancedTab.maxCPUs), in: 1...AdvancedTab.maxCPUs) {
                        HStack {
                            Text("自定义 vCPU 核心数")
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
                    Text("自动（此 Mac 推荐 \(AdvancedTab.autoGiB) GB）").tag(true)
                    Text("Custom").tag(false)
                } label: {
                    Label2(title: "虚拟机内存 (RAM)", detail: "自动：分配此 Mac 物理内存的一半（4 到 16 GB）。因 Apple 芯片采用统一内存架构，GPU 共享相同内存，剩余内存将保留给 macOS 系统及游戏图形显存。",
                           now: false, key: .memMiB)
                }
                Text("GPU 显存预算：\(VMSizing.gpuBudgetMiB(memMiB: settings.memMiB > 0 ? settings.memMiB : AdvancedTab.autoGiB * 1024, host: AdvancedTab.host)) MiB。macOS 系统及驱动保留：\(VMSizing.hostReserveMiB(AdvancedTab.host)) MiB。")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.memMiB > 0 {
                    Stepper(value: Binding(get: { settings.memMiB / 1024 },
                                           set: { settings.memMiB = min(AdvancedTab.maxGiB, max(2, $0)) * 1024 }),
                            in: 2...AdvancedTab.maxGiB) {
                        HStack {
                            Text("自定义内存大小")
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
                    Label2(title: "开启 SSH 服务", detail: "关闭时：Mac 上不监听端口且 SteamOS 中禁用 sshd 服务。开启时：自动为 steamos 用户生成访问密码（关闭 SSH 时仍保留该密码）。",
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
                    LabeledContent("登录信息") { Text("未选择磁盘镜像").foregroundStyle(.secondary) }
                } else if let state = password.state {
                    LabeledContent("用户名") { Text(GuestPassword.user).textSelection(.enabled) }
                    LabeledContent("密码") {
                        HStack {
                            Text(password.shown ?? "••••••••••••••••••••").font(.body.monospaced()).textSelection(.enabled)
                            Button(password.shown == nil ? "显示" : "隐藏") { password.toggleShown() }
                            Button("复制") { password.copy(password: true, port: settings.sshPort) }
                        }
                    }
                    LabeledContent("连接命令") {
                        HStack {
                            Text("ssh -p \(settings.sshPort) \(GuestPassword.user)@127.0.0.1").font(.callout.monospaced())
                                .textSelection(.enabled)
                            Button("复制") { password.copy(password: false, port: settings.sshPort) }
                        }
                    }
                    HStack {
                        Text(state == .applied ? "密码已在 SteamOS 中应用" : "密码将在下次启动时应用")
                            .font(.caption).foregroundStyle(state == .applied ? Color.secondary : Color.orange)
                        Spacer()
                        Button("重新生成密码") { password.regenerate() }
                    }
                } else {
                    HStack {
                        Text("此磁盘未生成专用密码（使用 Docker 构建的磁盘默认密码为 steamos）。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("生成新密码") { password.ensure() }
                    }
                }
                if let error = password.error { Text(error).font(.caption).foregroundStyle(.red) }
                Toggle(isOn: $settings.network) {
                    Label2(title: "虚拟网络连接", detail: "关闭时：不启用 virtio-net / gvproxy（客机完全离线，SSH 亦不可用）。",
                           now: false, key: .network)
                }
                Toggle(isOn: $settings.lanRemotePlay) {
                    Label2(title: "局域网远程畅玩 (Remote Play)",
                           detail: "允许同局域网内的 Steam Link 发现此虚拟机。将在 Mac 打开 UDP 27031–27036 与 TCP 27036–27037 端口。请允许“本地网络”权限；若 Mac 原生 Steam 占用上述端口请先退出。",
                           now: false, key: .lanRemotePlay)
                }
                .disabled(!settings.network)
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label2(title: "虚拟磁盘镜像", detail: "SteamOS 原始 GPT 磁盘镜像，原地直接读写（不复制）。若 Steam 提示空间不足，“扩容磁盘…”可为游戏扩充分区容量而无需重建磁盘。Mac 上的可用空间不会自动扩大 SteamOS 内部容量。",
                           now: false, key: .diskImage)
                    HStack {
                        Text(diskStatus.0)
                            .font(.callout).foregroundStyle(diskStatus.1 ? Color.secondary : Color.red)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        Button("新建磁盘…") { CreateDiskWindowController.show(settings: settings) }
                        Button("扩容磁盘…") { growDisk() }.disabled(nextDisk == nil)
                        Button("选择已有磁盘…") { chooseDisk() }
                        Button("使用默认磁盘") { settings.diskImage = "" }.disabled(settings.diskImage.isEmpty)
                    }
                }
                Picker(selection: $settings.steamClient) {
                    ForEach(LauncherSettings.SteamClient.allCases) { Text(SteamClientPicker.itemTitle($0)).tag($0) }
                } label: {
                    Label2(title: "Steam 客户端通道",
                           detail: settings.steamClient.detail + " " + LauncherSettings.SteamClient.switchNote,
                           now: false, key: .steamClient)
                }
                Picker(selection: $settings.vulkanDriver) {
                    ForEach(LauncherSettings.VulkanDriver.allCases) { d in
                        Text(d.title).tag(d)
                            .disabled(d.unavailableReason != nil && d != settings.vulkanDriver)
                    }
                } label: {
                    Label2(title: "Vulkan 图形驱动",
                           detail: settings.vulkanDriver.detail + " " + LauncherSettings.VulkanDriver.switchNote
                               + (settings.vulkanDriver.unavailableReason.map {
                                   " 当前不可用: \($0)；将使用 MoltenVK。" } ?? ""),
                           now: false, key: .vulkanDriver)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("重置所有设置…", role: .destructive) { confirmReset = true }
                }
            }
        }
        .onAppear { password.load(disk: nextDisk) }
        .onChange(of: settings.diskImage) { password.load(disk: nextDisk) }
        .confirmationDialog("确定要将 FX Steam Launcher 的所有设置重置为默认值吗？", isPresented: $confirmReset) {
            Button("重置", role: .destructive) { settings.resetAll() }
        } message: {
            Text("针对单个游戏的鼠标设置和已选定的磁盘镜像路径也将被清除。")
        }
    }

    private func growDisk() {
        guard let path = nextDisk else { return }
        do {
            let table = try GPT.read(path: path)
            guard let home = table.entries.last, home.name == "home" else { throw OptionError("不是有效的 SteamOS 磁盘") }
            let current = Double(home.sectors * 512) / Double(1 << 30)
            let alert = NSAlert()
            alert.messageText = "扩容 SteamOS 磁盘"
            let running = context.diskPath == path && context.restart != nil
            alert.informativeText = String(format: "游戏分区当前容量为 %.1f GiB。请输入更大的 home 分区容量（单位 GiB，最大支持 4096）。此操作绝不会缩小或删除现有数据。APFS / Mac OS 扩展格式仅在写入时占用 Mac 空间；exFAT 则会立即预分配全部新增空间并需要足够的剩余空间。" + (running ? "SteamOS 将正常关机，在停机状态下自动完成磁盘扩容，随后重新启动。" : "SteamOS 必须处于停止状态。分区与文件系统将在下次开机时完成扩容。"), current)
            let field = NSTextField(string: String(min(4096, Int(ceil(current)) + 64)))
            field.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: running ? "扩容并重启" : "开始扩容")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard let size = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw OptionError("请输入整数的 GiB 容量")
            }
            let request = try DiskGrower.request(path: path, homeGiB: size)
            if running, let runDir = Supervisor.runDir {
                try DiskGrower.queue(request, runDir: runDir)
                context.restart?()
            } else {
                try DiskGrower.grow(request)
                let done = NSAlert()
                done.messageText = "SteamOS 磁盘已扩容"
                done.informativeText = "请启动 SteamOS，系统将在开机阶段自动扩展 home 分区与文件系统。"
                done.runModal()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "SteamOS 磁盘扩容失败"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    private func chooseDisk() {
        let panel = NSOpenPanel()
        panel.title = "选择 SteamOS 磁盘镜像文件"
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
        if shown == nil { error = "无法从钥匙串 (Keychain) 读取密码。" }
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
