import AppKit
import ApplicationServices
import Carbon
import YobirinCore

/// 入力ソースの切り替え（開いたら英字にする）
enum InputSource {
    static func selectABC() {
        for id in ["com.apple.keylayout.ABC", "com.apple.keylayout.US"] {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
                  let src = list.first else { continue }
            if TISSelectInputSource(src) == noErr { return }
        }
    }
}

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 未許可ならシステムの案内を出す
    @discardableResult
    static func promptIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

/// クリップボードに入れて ⌘V を送り、元の中身を戻す
enum Paster {
    /// 呼鈴自身が書いた変化はクリップボード履歴に残さない
    static var ignoreChangeCounts: Set<Int> = []

    struct SavedItem { let types: [NSPasteboard.PasteboardType: Data] }

    static func snapshot(_ pb: NSPasteboard) -> [SavedItem] {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return SavedItem(types: d)
        }
    }

    static func restore(_ items: [SavedItem], to pb: NSPasteboard) {
        pb.clearContents()
        let objs: [NSPasteboardItem] = items.map { s in
            let it = NSPasteboardItem()
            for (t, d) in s.types { it.setData(d, forType: t) }
            return it
        }
        if !objs.isEmpty { pb.writeObjects(objs) }
        ignoreChangeCounts.insert(pb.changeCount)
    }

    static func paste(write: (NSPasteboard) -> Void) {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        write(pb)
        ignoreChangeCounts.insert(pb.changeCount)
        // パネルが閉じて元のアプリにキーが戻るのを少し待つ
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            sendCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                restore(saved, to: pb)
            }
        }
    }

    static func pasteText(_ text: String) {
        paste { $0.setString(text, forType: .string) }
    }

    static func pasteImage(data: Data, type: String) {
        paste { $0.setData(data, forType: type == "tiff" ? .tiff : .png) }
    }

    static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// アクセシビリティ API で最前面アプリのフォーカスウィンドウを動かす
enum WindowManager {
    static let cycler = WindowCycler()

    static func apply(_ direction: WindowDirection) {
        guard Accessibility.isTrusted else {
            Accessibility.promptIfNeeded()
            HUD.show("アクセシビリティの許可が要ります")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winRef else {
            HUD.show("動かせるウィンドウがありません")
            return
        }
        let win = winRef as! AXUIElement
        guard let current = frame(of: win) else { return }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // ウィンドウの中心がある画面（無ければ一番重なる画面）
        let screens = NSScreen.screens
        let center = CGPoint(x: current.midX, y: current.midY)
        let screen = screens.first { WindowCycler.cocoaToAX($0.frame, primaryScreenHeight: primaryHeight).contains(center) }
            ?? screens.max { a, b in
                area(WindowCycler.cocoaToAX(a.frame, primaryScreenHeight: primaryHeight).intersection(current))
                    < area(WindowCycler.cocoaToAX(b.frame, primaryScreenHeight: primaryHeight).intersection(current))
            }
        guard let screen else { return }
        let visible = WindowCycler.cocoaToAX(screen.visibleFrame, primaryScreenHeight: primaryHeight)
        let target = cycler.next(direction: direction, current: current, visible: visible)
        // AXEnhancedUserInterface が有効なアプリ（Chrome・Electron・Finder など）は位置の変更をアニメーションで行い、
        // その間に入れた大きさが捨てられて「大きさはそのまま位置だけ動く」ことがある。動かす間だけ切る。
        let enhanced = enhancedUserInterface(axApp)
        if enhanced { setEnhancedUserInterface(axApp, false) }
        setFrame(win, target)
        if enhanced { setEnhancedUserInterface(axApp, true) }
        if let actual = frame(of: win) { cycler.noteActualFrame(actual) }
    }

    private static let enhancedUIAttribute = "AXEnhancedUserInterface" as CFString

    private static func enhancedUserInterface(_ axApp: AXUIElement) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, enhancedUIAttribute, &v) == .success,
              let b = v as? Bool else { return false }
        return b
    }

    private static func setEnhancedUserInterface(_ axApp: AXUIElement, _ on: Bool) {
        AXUIElementSetAttributeValue(axApp, enhancedUIAttribute, on as CFBoolean)
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    private static func frame(of win: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private static func setFrame(_ win: AXUIElement, _ r: CGRect) {
        var p = r.origin
        var s = r.size
        guard let pv = AXValueCreate(.cgPoint, &p), let sv = AXValueCreate(.cgSize, &s) else { return }
        // 画面をまたぐときに大きさが削られないよう 位置 → 大きさ → 位置 の順に入れる
        AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
        AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
    }
}

/// スクリプトの実行
enum ScriptRunner {
    static func run(_ cmd: ScriptCommand, argument: String?, completion: @escaping (String, Int32) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cmd.path)
            p.arguments = argument.map { [$0] } ?? []
            p.currentDirectoryURL = URL(fileURLWithPath: cmd.path).deletingLastPathComponent()
            var env = ProcessInfo.processInfo.environment
            let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = extra + (env["PATH"].map { ":" + $0 } ?? "")
            env["LANG"] = env["LANG"] ?? "ja_JP.UTF-8"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            var output = Data()
            do {
                try p.run()
                output = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
            } catch {
                DispatchQueue.main.async { completion("実行できませんでした: \(error.localizedDescription)", -1) }
                return
            }
            let text = String(data: output, encoding: .utf8) ?? ""
            DispatchQueue.main.async { completion(text, p.terminationStatus) }
        }
    }
}
