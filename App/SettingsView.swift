import AppKit
import SwiftUI
import YobirinCore

final class SettingsModel: ObservableObject {
    @Published var config: Config
    @Published var recording: HotkeyAction?
    var onSave: (Config) -> Void = { _ in }
    var onRecordingChange: (Bool) -> Void = { _ in }
    private var monitor: Any?

    // MARK: スニペット（snippets.json）
    @Published var drafts: [SnippetDraft] = [] {
        didSet { if !loadingSnippets { snippetsEdited() } }
    }
    @Published var selection: UUID?
    @Published var snippetStatus: String = ""
    var onSnippetsSaved: () -> Void = {}
    private var loadedStamp: FileStamp?
    private var loadingSnippets = false
    private var dirty = false
    private var saveWork: DispatchWorkItem?
    var snippetsURL: URL = Paths.snippetsFile

    init(config: Config) {
        self.config = config
        loadSnippets()
    }

    /// 外から書き換えられたファイルを読む（未保存の編集があるときは何もしない）
    func reloadSnippetsIfIdle() {
        guard !dirty, FileStamp.of(snippetsURL) != loadedStamp else { return }
        loadSnippets()
    }

    func loadSnippets() {
        loadingSnippets = true
        let keep = selection.flatMap { id in drafts.first { $0.id == id }?.name }
        drafts = SnippetFile.load(from: snippetsURL).map { SnippetDraft(name: $0.name, text: $0.text) }
        selection = drafts.first { $0.name == keep }?.id ?? drafts.first?.id
        loadedStamp = FileStamp.of(snippetsURL)
        dirty = false
        saveWork?.cancel()
        loadingSnippets = false
        snippetStatus = ""
    }

    func addSnippet() {
        var n = 1
        let names = Set(drafts.map(\.name))
        while names.contains("新しいスニペット\(n == 1 ? "" : " \(n)")") { n += 1 }
        let d = SnippetDraft(name: "新しいスニペット\(n == 1 ? "" : " \(n)")", text: "")
        drafts.append(d)
        selection = d.id
    }

    func removeSelectedSnippet() {
        guard let sel = selection, let i = drafts.firstIndex(where: { $0.id == sel }) else { return }
        drafts.remove(at: i)
        selection = drafts.isEmpty ? nil : drafts[min(i, drafts.count - 1)].id
    }

    var snippetIssues: [Int: SnippetFile.Issue] { SnippetFile.issues(in: drafts.map(\.snippet)) }

    private func snippetsEdited() {
        dirty = true
        snippetStatus = snippetIssues.isEmpty ? "編集中…（止まると自動で保存）" : "名前が空か重複しているため、まだ保存していません"
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flushSnippets() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    /// 保存。名前が空・重複なら保存しない。ファイルが開いたあとに外から変わっていたら、上書きせず読み直す
    func flushSnippets() {
        saveWork?.cancel()
        guard dirty else { return }
        guard snippetIssues.isEmpty else {
            snippetStatus = "名前が空か重複しているため、まだ保存していません"
            return
        }
        if FileStamp.of(snippetsURL) != loadedStamp {
            loadSnippets()
            snippetStatus = "ファイルが外で変更されていたため、読み直しました（直前の編集は反映されていません）"
            return
        }
        do {
            try SnippetFile.save(drafts.map(\.snippet), to: snippetsURL)
            loadedStamp = FileStamp.of(snippetsURL)
            dirty = false
            snippetStatus = "保存しました"
            onSnippetsSaved()
        } catch {
            snippetStatus = "保存できませんでした: \(error.localizedDescription)"
        }
    }

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

struct SnippetDraft: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var text: String
    var snippet: Snippet { Snippet(name: name, text: text) }
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
            Section("スニペット") {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 4) {
                        List(selection: $model.selection) {
                            ForEach(Array(model.drafts.enumerated()), id: \.element.id) { i, d in
                                HStack {
                                    Text(d.name.isEmpty ? "（名前なし）" : d.name).lineLimit(1)
                                    if model.snippetIssues[i] != nil {
                                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    }
                                }
                                .tag(d.id)
                            }
                        }
                        .frame(width: 150, height: 150)
                        HStack(spacing: 6) {
                            Button { model.addSnippet() } label: { Image(systemName: "plus") }
                            Button { model.removeSelectedSnippet() } label: { Image(systemName: "minus") }
                                .disabled(model.selection == nil)
                            Spacer()
                        }
                    }
                    if let i = model.drafts.firstIndex(where: { $0.id == model.selection }) {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("名前", text: $model.drafts[i].name)
                            if let issue = model.snippetIssues[i] {
                                Text(issue == .emptyName ? "名前が空です" : "同じ名前のスニペットがあります")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            TextEditor(text: $model.drafts[i].text)
                                .font(.body)
                                .frame(height: 100)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                        }
                    } else {
                        Text("左の＋でスニペットを追加します。").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack {
                    Text(model.snippetStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("再読込") { model.loadSnippets() }
                }
                Text("入力が止まって 0.5 秒後に自動で保存します。名前が空・重複のあいだは保存しません。")
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
