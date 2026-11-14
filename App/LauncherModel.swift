import AppKit
import SwiftUI
import YobirinCore

enum LauncherMode: Equatable {
    case all
    case snippets
    case clipboard
    case argument(ScriptCommand)
    case output(String)
}

final class LauncherModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { selected = 0; refilter() } } }
    @Published private(set) var items: [ResultItem] = []
    @Published var selected = 0
    @Published private(set) var mode: LauncherMode = .all
    @Published private(set) var output = ""
    @Published private(set) var running = false

    let catalog: Catalog
    let usage: UsageStore
    let clipboard: ClipboardStore
    weak var field: NSTextField?

    /// パネルを閉じる
    var onClose: () -> Void = {}
    /// 組み込みコマンドの実行
    var onBuiltin: (Builtin) -> Void = { _ in }

    init(catalog: Catalog, usage: UsageStore, clipboard: ClipboardStore) {
        self.catalog = catalog
        self.usage = usage
        self.clipboard = clipboard
    }

    var placeholder: String {
        switch mode {
        case .all: return "呼鈴で探す"
        case .snippets: return "スニペットを探す"
        case .clipboard: return "クリップボード履歴を探す"
        case .argument(let s): return s.argument1?.placeholder.isEmpty == false ? s.argument1!.placeholder : "引数"
        case .output: return ""
        }
    }

    var header: String? {
        switch mode {
        case .all: return nil
        case .snippets: return "スニペット"
        case .clipboard: return "クリップボード履歴"
        case .argument(let s): return s.title
        case .output(let title): return title
        }
    }

    func reset(to mode: LauncherMode) {
        self.mode = mode
        output = ""
        running = false
        selected = 0
        if query.isEmpty { refilter() } else { query = "" }
        field?.stringValue = ""
    }

    func refilter() {
        let now = Date()
        switch mode {
        case .all:
            let all = catalog.allItems()
            let idx = Ranker.rank(all.map { RankCandidate(id: $0.id, texts: $0.searchTexts) }, query: query, usage: usage.records, now: now)
            items = idx.map { all[$0] }
        case .snippets:
            let all = catalog.snippetItems()
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                items = all
            } else {
                let idx = Ranker.rank(all.map { RankCandidate(id: $0.id, texts: $0.searchTexts) }, query: query, usage: usage.records, now: now)
                items = idx.map { all[$0] }
            }
        case .clipboard:
            let q = query.trimmingCharacters(in: .whitespaces)
            let entries = clipboard.entries.filter { e in
                guard !q.isEmpty else { return true }
                guard let t = e.text else { return false }
                return FuzzyMatcher.score(query: q, candidate: t) != nil
            }
            items = entries.prefix(300).map(clipboardItem)
        case .argument, .output:
            items = []
        }
        selected = min(selected, max(items.count - 1, 0))
    }

    private func clipboardItem(_ e: ClipboardEntry) -> ResultItem {
        let df = DateFormatter()
        df.dateFormat = "M/d HH:mm"
        let when = df.string(from: e.date)
        switch e.kind {
        case .text:
            let t = (e.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ⏎ ")
            return ResultItem(id: "clip:" + e.id.uuidString, title: String(t.prefix(200)), subtitle: when, kind: "文字",
                              icon: .symbol("doc.text"), action: .clipboard(e), searchTexts: [])
        case .image:
            let url = clipboard.imageURL(for: e)
            return ResultItem(id: "clip:" + e.id.uuidString, title: "画像", subtitle: when, kind: "画像",
                              icon: url.map { .thumbnail($0) } ?? .symbol("photo"), action: .clipboard(e), searchTexts: [])
        }
    }

    // MARK: - キー操作

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
    }

    var selectedItem: ResultItem? { items.indices.contains(selected) ? items[selected] : nil }

    /// Tab: 引数のあるスクリプトなら引数入力へ
    func tab() {
        if case .all = mode, let item = selectedItem, case .script(let s) = item.action, s.argument1 != nil {
            reset(to: .argument(s))
        }
    }

    /// Esc: 引数入力・出力表示なら検索に戻る。それ以外は閉じる
    func escape() {
        switch mode {
        case .argument, .output: reset(to: .all)
        default: onClose()
        }
    }

    func enter() {
        if case .argument(let s) = mode {
            let arg = query
            if arg.isEmpty && !(s.argument1?.optional ?? false) {
                NSSound.beep()
                return
            }
            usage.record(s.id)
            runScript(s, argument: arg)
            return
        }
        if case .output = mode { reset(to: .all); return }
        guard let item = selectedItem else { return }
        execute(item)
    }

    func execute(_ item: ResultItem) {
        switch item.action {
        case .openApp(let url):
            usage.record(item.id)
            onClose()
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .openBookmark(let url):
            usage.record(item.id)
            onClose()
            openInChromeDefault(url)
        case .script(let s):
            usage.record(item.id)
            if s.argument1 != nil {
                reset(to: .argument(s))
            } else {
                runScript(s, argument: nil)
            }
        case .snippet(let text):
            usage.record(item.id)
            onClose()
            Paster.pasteText(text)
        case .clipboard(let e):
            onClose()
            switch e.kind {
            case .text:
                Paster.pasteText(e.text ?? "")
            case .image:
                if let url = clipboard.imageURL(for: e), let data = try? Data(contentsOf: url) {
                    Paster.pasteImage(data: data, type: e.imageType ?? "png")
                }
            }
        case .builtin(let b):
            usage.record(item.id)
            switch b {
            case .clipboardHistory: reset(to: .clipboard)
            case .snippetList: reset(to: .snippets)
            default:
                onClose()
                onBuiltin(b)
            }
        }
    }

    /// Default プロフィールの Chrome で開く（open -na "Google Chrome" --args --profile-directory=Default <url>）
    private func openInChromeDefault(_ url: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-na", "Google Chrome", "--args", "--profile-directory=Default", url]
        do {
            try p.run()
        } catch {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
    }

    private func runScript(_ s: ScriptCommand, argument: String?) {
        switch s.mode {
        case .fullOutput:
            reset(to: .output(s.title))
            running = true
            ScriptRunner.run(s, argument: argument) { [weak self] text, status in
                guard let self, case .output = self.mode else { return }
                self.running = false
                self.output = text.isEmpty ? (status == 0 ? "（出力なし）" : "終了コード \(status)") : text
            }
        case .compact, .silent, .inline:
            onClose()
            ScriptRunner.run(s, argument: argument) { text, status in
                let last = RaycastScriptParser.lastLine(of: text)
                HUD.show(last.isEmpty ? (status == 0 ? "\(s.title): 完了" : "\(s.title): 失敗（\(status)）") : last)
            }
        }
    }
}
