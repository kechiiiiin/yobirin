import AppKit
import SwiftUI
import YobirinCore

final class SettingsModel: ObservableObject {
    @Published var config: Config
    @Published var recording: HotkeyAction?
    var onSave: (Config) -> Void = { _ in }
    var onRecordingChange: (Bool) -> Void = { _ in }
    private var monitor: Any?

    init(config: Config) { self.config = config }

    func startRecording(_ action: HotkeyAction) {
        stopRecording()
        recording = action
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recording else { return event }
            let mods = KeyNames.carbonModifiers(event.modifierFlags)
            if event.keyCode == 53 && mods == 0 {  // Esc だけなら取り消し
                self.stopRecording()
                return nil
            }
            let isFunctionKey = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].contains(Int(event.keyCode))
            guard mods != 0 || isFunctionKey else {
                NSSound.beep()
                return nil
            }
            self.config.setHotkey(action, Hotkey(keyCode: UInt32(event.keyCode), modifiers: mods))
            self.stopRecording()
            self.onSave(self.config)
            return nil
        }
    }

    func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if recording != nil {
            recording = nil
            onRecordingChange(false)
        }
    }

    func clear(_ action: HotkeyAction) {
        config.setHotkey(action, nil)
        onSave(config)
    }

    func restore(_ id: String) {
        config.excluded.removeAll { $0 == id }
        onSave(config)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Paths.expand(config.scriptsFolder)
        if panel.runModal() == .OK, let url = panel.url {
            let home = Paths.home.path
            config.scriptsFolder = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
            onSave(config)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("ショートカットキー") {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    HStack {
                        Text(action.label).frame(width: 140, alignment: .leading)
                        Button {
                            model.startRecording(action)
                        } label: {
                            Text(label(for: action))
                                .frame(minWidth: 160)
                        }
                        .buttonStyle(.bordered)
                        Button("クリア") { model.clear(action) }
                            .disabled(model.config.hotkey(action) == nil)
                    }
                }
                Text("欄を押してから、登録したいキーの組み合わせを押してください（⎋ で取り消し）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("スクリプト") {
                HStack {
                    TextField("フォルダ", text: Binding(
                        get: { model.config.scriptsFolder },
                        set: { model.config.scriptsFolder = $0 }
                    ))
                    .onSubmit { model.onSave(model.config) }
                    Button("選ぶ…") { model.chooseFolder() }
                }
                Text("Raycast のスクリプトコマンド書式（# @raycast.title など）のヘッダを読みます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("除外した項目") {
                if model.config.excluded.isEmpty {
                    Text("なし。検索欄で項目を選んで ⌘⌫ を押すと、ここに入ります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.config.excluded, id: \.self) { id in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Config.displayName(forExcludedID: id)).lineLimit(1)
                            Text(id).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("戻す") { model.restore(id) }
                    }
                }
            }
            Section("その他") {
                Toggle("ログイン時に起動", isOn: Binding(
                    get: { model.config.launchAtLogin },
                    set: { model.config.launchAtLogin = $0; model.onSave(model.config) }
                ))
                HStack {
                    Button("設定ファイルを開く") { NSWorkspace.shared.open(Paths.configFile) }
                    Button("スニペットを開く") { NSWorkspace.shared.open(Paths.snippetsFile) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func label(for action: HotkeyAction) -> String {
        if model.recording == action { return "キーを押してください…" }
        return model.config.hotkey(action).map(KeyNames.describe) ?? "未登録"
    }
}
