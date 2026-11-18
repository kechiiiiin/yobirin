import AppKit
import ApplicationServices
import SwiftUI
import YobirinCore

/// AXUIElement から CGWindowID を引く（公開 API が無い。Rectangle・AltTab なども使っている）
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// フィールド: 無地の枠を広げ、ドラッグで入れたウィンドウだけを ⌘1〜⌘9 で切り替える。
/// 判定・番号付けは YobirinCore（FieldRoster・FieldDropJudge）。ここは画面とアクセシビリティの橋渡し
final class FieldController: NSObject, NSWindowDelegate {
    private(set) var isOpen = false

    private var window: FieldWindow?
    private let viewModel = FieldViewModel()
    private var roster = FieldRoster() { didSet { viewModel.labels = roster.labels() } }
    /// 入れたウィンドウのアクセシビリティ要素（CGWindowID → 要素）
    private var axWindows: [UInt32: AXUIElement] = [:]
    private var lastFocused: UInt32?

    private var mouseMonitor: Any?
    private var pollTimer: Timer?
    private var terminateObserver: Any?
    /// 押したときのウィンドウ（離したときに比べる）
    private var pressed: (windowID: UInt32, pid: Int32, frame: CGRect)?

    private let frameFile = Paths.supportDirectory.appendingPathComponent("field.json")

    func toggle() { isOpen ? close() : open() }

    // MARK: - 開く／閉じる

    func open() {
        guard !isOpen else { return }
        guard Accessibility.isTrusted else {
            Accessibility.promptIfNeeded()
            HUD.show("アクセシビリティの許可が要ります")
            return
        }
        isOpen = true
        let w = window ?? makeWindow()
        window = w
        let screens = NSScreen.screens.map(\.visibleFrame)
        let main = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        w.setFrame(FieldFrame.restore(saved: FieldFrame.load(from: frameFile), screens: screens, main: main), display: true)
        roster.removeAll()
        axWindows.removeAll()
        lastFocused = nil
        w.orderFrontRegardless()

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in
            if e.type == .leftMouseDown { self?.mouseDown() } else { self?.mouseUp() }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            for m in self.roster.members where m.pid == pid { self.axWindows[m.windowID] = nil }
            self.roster.remove(pid: pid)
        }
        let hk = HotkeyManager.shared
        var failed = 0
        for (i, code) in FieldKeys.digitKeyCodes.enumerated() {
            let n = i + 1
            if !hk.registerField(Hotkey(keyCode: code, modifiers: Hotkey.cmd), handler: { [weak self] in self?.focus(number: n) }) {
                failed += 1
            }
        }
        if failed > 0 { HUD.show("⌘＋数字のうち \(failed) 個を登録できませんでした", duration: 2.5) }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        HotkeyManager.shared.unregisterField()
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
        pollTimer?.invalidate()
        pollTimer = nil
        if let o = terminateObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        terminateObserver = nil
        pressed = nil
        saveFrame()
        // 背景だけ消し、ウィンドウはその場に残す。取り込み状態は消す
        window?.orderOut(nil)
        roster.removeAll()
        axWindows.removeAll()
        lastFocused = nil
    }

    private func makeWindow() -> FieldWindow {
        let w = FieldWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = true }
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = FieldViewModel.background
        w.minSize = FieldFrame.minimumSize
        w.title = "フィールド"
        w.delegate = self
        w.onMouseDown = { [weak self] in
            // 背景を押したら、入れたウィンドウを全部フィールドの上へ
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.raiseMembers(refocus: false) }
        }
        let host = FieldHostingView(rootView: FieldView(model: viewModel))
        w.contentView = host
        return w
    }

    private func saveFrame() {
        guard let w = window else { return }
        try? FieldFrame(w.frame).save(to: frameFile)
    }

    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { if isOpen { saveFrame() } }

    // MARK: - ドラッグで入れる・外す

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// カーソル位置（左上原点）
    private var cursorAX: CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    private func mouseDown() {
        pressed = Self.windowUnder(cursorAX)
    }

    private func mouseUp() {
        guard let p = pressed else { return }
        pressed = nil
        // ウィンドウの位置が落ち着くのを少し待ってから比べる
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.isOpen, let w = self.window else { return }
            guard let after = Self.windowFrames()[p.windowID] else { return }
            let field = WindowCycler.cocoaToAX(w.frame, primaryScreenHeight: self.primaryHeight)
            switch FieldDropJudge.decide(before: p.frame, after: after, cursor: self.cursorAX, field: field,
                                         isMember: self.roster.contains(p.windowID)) {
            case .add: self.capture(windowID: p.windowID, pid: p.pid, frame: after)
            case .remove:
                self.roster.remove(windowID: p.windowID)
                self.axWindows[p.windowID] = nil
            case .none:
                if self.roster.contains(p.windowID) { self.roster.updateFrames([p.windowID: after]) }
            }
        }
    }

    private func capture(windowID: UInt32, pid: Int32, frame: CGRect) {
        guard let ax = Self.axWindow(pid: pid, windowID: windowID, frame: frame) else {
            HUD.show("このウィンドウは入れられませんでした")
            return
        }
        let app = NSRunningApplication(processIdentifier: pid)
        let appName = app?.localizedName ?? "?"
        axWindows[windowID] = ax
        roster.add(FieldMember(windowID: windowID, pid: pid, appName: appName, windowTitle: Self.title(of: ax), frame: frame))
        lastFocused = windowID
        if roster.members.count > FieldRoster.maxNumber {
            HUD.show("⌘＋数字で選べるのは 9 個までです")
        }
    }

    /// 閉じられたウィンドウを外し、動いた・大きさが変わったものは番号を付け直す
    private func poll() {
        guard isOpen, !roster.isEmpty else { return }
        let frames = Self.windowFrames()
        var r = roster
        if r.keepOnly(existing: Set(frames.keys)) {
            for id in axWindows.keys where !frames.keys.contains(id) { axWindows[id] = nil }
        }
        r.updateFrames(frames)
        if r != roster { roster = r }
    }

    // MARK: - 切り替え・持ち上げ

    func focus(number n: Int) {
        guard let m = roster.member(number: n), let ax = axWindows[m.windowID] else { return }
        lastFocused = m.windowID
        focus(ax, pid: m.pid)
    }

    private func focus(_ ax: AXUIElement, pid: Int32) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(ax, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, ax)
    }

    /// 入れたウィンドウを番号順にフィールドの上へ持ち上げる
    private func raiseMembers(refocus: Bool) {
        for m in roster.members {
            if let ax = axWindows[m.windowID] { AXUIElementPerformAction(ax, kAXRaiseAction as CFString) }
        }
        if refocus, let id = lastFocused, let m = roster.members.first(where: { $0.windowID == id }), let ax = axWindows[id] {
            focus(ax, pid: m.pid)
        }
    }

    // MARK: - ウィンドウを引く

    /// 画面上の普通のウィンドウ（layer 0）の枠。CGWindowID → 枠（左上原点）
    static func windowFrames() -> [UInt32: CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var out: [UInt32: CGRect] = [:]
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? UInt32,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { continue }
            out[id] = r
        }
        return out
    }

    /// カーソルの下にある、他のアプリの普通のウィンドウ（手前から探す）
    static func windowUnder(_ point: CGPoint) -> (windowID: UInt32, pid: Int32, frame: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.contains(point) else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            // メニューバー・Dock など手前の特別な層が上にあるときは、ウィンドウを掴んでいない
            guard layer == 0 else { return nil }
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != me else { return nil }
            return (id, pid, r)
        }
        return nil
    }

    static func axWindow(pid: Int32, windowID: UInt32, frame: CGRect) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let wins = ref as? [AXUIElement] else { return nil }
        for w in wins {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(w, &id) == .success, id == windowID { return w }
        }
        // 引けないアプリは枠が一致するもので代える
        return wins.first { w in axFrame(w).map { WindowCycler.approximatelyEqual($0, frame, tolerance: 2) } ?? false }
    }

    static func axFrame(_ w: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    static func title(of w: AXUIElement) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &ref) == .success else { return "" }
        return ref as? String ?? ""
    }
}

/// タイトルバーの無い（見えない）枠。押したことを知らせる
final class FieldWindow: NSWindow {
    var onMouseDown: () -> Void = {}

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onMouseDown() }
        super.sendEvent(event)
    }
}

/// 背景のどこを掴んでもフィールドを動かせるようにする
final class FieldHostingView: NSHostingView<FieldView> {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class FieldViewModel: ObservableObject {
    static let background = NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1)
    @Published var labels: [String] = []
}

struct FieldView: View {
    @ObservedObject var model: FieldViewModel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(nsColor: FieldViewModel.background)
            if model.labels.isEmpty {
                Text("ウィンドウをここへドラッグ")
                    .font(.system(size: 17))
                    .foregroundColor(.white.opacity(0.25))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.labels.enumerated()), id: \.offset) { _, s in
                        Text(s).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .padding(10)
            }
        }
        .ignoresSafeArea()
    }
}
