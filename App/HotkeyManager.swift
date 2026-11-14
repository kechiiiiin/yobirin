import Carbon
import YobirinCore

/// Carbon の RegisterEventHotKey で全体ショートカットを登録する
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var refs: [EventHotKeyRef] = []
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

    func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        handlers.removeAll()
        failures.removeAll()
    }
}
