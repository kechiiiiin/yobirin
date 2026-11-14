import AppKit
import ServiceManagement
import SwiftUI
import YobirinCore

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private var panel: LauncherPanel!
    private var model: LauncherModel!
    private let catalog = Catalog()
    private let usage = UsageStore(fileURL: Paths.usageFile)
    private lazy var clipboardStore = ClipboardStore(directory: Paths.clipboardDirectory)
    private lazy var clipboardMonitor = ClipboardMonitor(store: clipboardStore)
    private var config = Config()
    private var configStamp: FileStamp?
    private var configTimer: Timer?
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private var mouseMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        prepareFiles()
        setUpStatusItem()
        setUpPanel()
        loadConfig()
        catalog.refresh(force: true)
        clipboardMonitor.start()

        configTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if FileStamp.of(Paths.configFile) != self.configStamp { self.loadConfig() }
        }

        if !Accessibility.isTrusted {
            Accessibility.promptIfNeeded()
        }
    }

    // MARK: - 準備

    private func prepareFiles() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.configDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Paths.supportDirectory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Paths.configFile.path) {
            try? Config().save(to: Paths.configFile)
        }
        SnippetFile.ensureExists(at: Paths.snippetsFile)
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "呼鈴")
        let menu = NSMenu()
        menu.addItem(withTitle: "呼鈴を開く", action: #selector(openLauncherFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "設定…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "再読込", action: #selector(reloadAll), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "呼鈴を終了", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }

    private func setUpPanel() {
        model = LauncherModel(catalog: catalog, usage: usage, clipboard: clipboardStore)
        model.onClose = { [weak self] in self?.hidePanel() }
        model.onBuiltin = { [weak self] b in self?.runBuiltin(b) }

        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered, defer: false)
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        let host = NSHostingView(rootView: LauncherView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 460)
        panel.contentView = host
    }

    // MARK: - 設定

    private func loadConfig() {
        configStamp = FileStamp.of(Paths.configFile)
        config = Config.load(from: Paths.configFile)
        let folder = Paths.expand(config.scriptsFolder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        catalog.scriptsFolder = folder
        registerHotkeys()
        applyLoginItem()
        settingsModel?.config = config
    }

    private func saveConfig(_ c: Config) {
        do {
            try c.save(to: Paths.configFile)
        } catch {
            HUD.show("設定を保存できませんでした")
        }
        loadConfig()
    }

    private func registerHotkeys() {
        let hk = HotkeyManager.shared
        hk.unregisterAll()
        for action in HotkeyAction.allCases {
            guard let key = config.hotkey(action) else { continue }
            hk.register(key, label: action.label) { [weak self] in self?.handleHotkey(action) }
        }
        if !hk.failures.isEmpty {
            HUD.show("登録できなかったキー: " + hk.failures.joined(separator: "、"), duration: 3)
        }
    }

    private func handleHotkey(_ action: HotkeyAction) {
        switch action {
        case .launcher: togglePanel(.all)
        case .snippets: togglePanel(.snippets)
        case .clipboard: togglePanel(.clipboard)
        case .windowLeft: WindowManager.apply(.left)
        case .windowRight: WindowManager.apply(.right)
        case .windowMaximize: WindowManager.apply(.maximize)
        }
    }

    /// 呼鈴の場所が /Applications か ~/Applications のときだけ登録する（build/ のものを登録しない）
    private func applyLoginItem() {
        let path = Bundle.main.bundlePath
        let installed = path.hasPrefix("/Applications/") || path.hasPrefix(Paths.home.appendingPathComponent("Applications").path + "/")
        let service = SMAppService.mainApp
        do {
            if config.launchAtLogin && installed && service.status != .enabled {
                try service.register()
            } else if !config.launchAtLogin && service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("呼鈴: ログイン項目を変更できませんでした \(error)")
        }
    }

    // MARK: - パネル

    private func togglePanel(_ mode: LauncherMode) {
        if panel.isVisible && model.mode == mode {
            hidePanel()
        } else {
            showPanel(mode)
        }
    }

    private func showPanel(_ mode: LauncherMode) {
        catalog.refresh()
        model.reset(to: mode)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + vf.height * 0.08))
        }
        InputSource.selectABC()
        panel.makeKeyAndOrderFront(nil)
        if let f = model.field { panel.makeFirstResponder(f) }
        // アプリのアイコン一覧は裏で読み直しているので、少し後に並べ直す
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.model.refilter()
        }
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hidePanel()
            }
        }
    }

    private func hidePanel() {
        if let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
        }
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // キー登録の途中で閉じても、ホットキーを外したままにしない
        if (notification.object as? NSWindow) === settingsWindow { settingsModel?.stopRecording() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel { hidePanel() }
    }

    // MARK: - コマンド

    private func runBuiltin(_ b: Builtin) {
        switch b {
        case .settings: openSettings()
        case .reload: reloadAll()
        case .quit: quit()
        case .clipboardHistory: showPanel(.clipboard)
        case .snippetList: showPanel(.snippets)
        case .windowLeft: WindowManager.apply(.left)
        case .windowRight: WindowManager.apply(.right)
        case .windowMaximize: WindowManager.apply(.maximize)
        }
    }

    @objc private func openLauncherFromMenu() { showPanel(.all) }

    @objc private func reloadAll() {
        loadConfig()
        catalog.refresh(force: true)
        HUD.show("呼鈴を再読込しました")
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let sm = SettingsModel(config: config)
            sm.onSave = { [weak self] c in self?.saveConfig(c) }
            sm.onRecordingChange = { [weak self] recording in
                // 登録中は既存のホットキーを外し、押した組み合わせがそのまま届くようにする
                if recording { HotkeyManager.shared.unregisterAll() } else { self?.registerHotkeys() }
            }
            settingsModel = sm
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "呼鈴の設定"
            w.delegate = self
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: sm))
            w.center()
            settingsWindow = w
        }
        settingsModel?.config = config
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
