import Carbon
import YobirinCore

/// Carbon の RegisterEventHotKey で全体ショートカットを登録する
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var refs: [EventHotKeyRef] = []
    /// フィールドを開いている間だけの ⌘1〜⌘9。設定の読み直し（unregisterAll）では外さない
    private var fieldRefs: [(ref: EventHotKeyRef, id: UInt32)] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var installed = false
    /// 登録できなかったもの（他のアプリ・システムと重複など）
    private(set) var failures: [String] = []

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if status == noErr {
                let id = hkID.id
                DispatchQueue.main.async { HotkeyManager.shared.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(_ key: Hotkey, label: String, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5942_524E) /* 'YBRN' */, id: id)
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            handlers[id] = handler
        } else {
            failures.append("\(label)（\(KeyNames.describe(key))）")
            NSLog("呼鈴: ホットキーを登録できませんでした \(label) status=\(status)")
        }
    }

    /// フィールド用のキーを登録する（失敗しても failures には入れない）。登録できたら true
    @discardableResult
    func registerField(_ key: Hotkey, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5942_524E), id: id)
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("呼鈴: フィールドのキーを登録できませんでした keyCode=\(key.keyCode) status=\(status)")
            return false
        }
        fieldRefs.append((ref, id))
        handlers[id] = handler
        return true
    }

    func unregisterField() {
        for r in fieldRefs {
            UnregisterEventHotKey(r.ref)
            handlers[r.id] = nil
        }
        fieldRefs.removeAll()
    }

    func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        let keep = Set(fieldRefs.map(\.id))
        handlers = handlers.filter { keep.contains($0.key) }
        failures.removeAll()
    }
}
