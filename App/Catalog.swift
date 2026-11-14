import AppKit
import YobirinCore

enum ItemIcon {
    case file(String)        // アプリのパス（アイコンはあとで引く）
    case emoji(String)
    case symbol(String)
    case thumbnail(URL)
}

enum Builtin: String, CaseIterable {
    case settings, reload, quit, clipboardHistory, snippetList, windowLeft, windowRight, windowMaximize

    var title: String {
        switch self {
        case .settings: return "呼鈴の設定"
        case .reload: return "呼鈴を再読込"
        case .quit: return "呼鈴を終了"
        case .clipboardHistory: return "クリップボード履歴"
        case .snippetList: return "スニペット一覧"
        case .windowLeft: return "左半分"
        case .windowRight: return "右半分"
        case .windowMaximize: return "最大化"
        }
    }

    var keywords: [String] {
        switch self {
        case .settings: return ["yobirin settings", "preferences"]
        case .reload: return ["yobirin reload"]
        case .quit: return ["yobirin quit"]
        case .clipboardHistory: return ["clipboard history"]
        case .snippetList: return ["snippets"]
        case .windowLeft: return ["left half", "window left"]
        case .windowRight: return ["right half", "window right"]
        case .windowMaximize: return ["maximize", "window maximize"]
        }
    }

    var symbol: String {
        switch self {
        case .settings: return "gearshape"
        case .reload: return "arrow.clockwise"
        case .quit: return "power"
        case .clipboardHistory: return "doc.on.clipboard"
        case .snippetList: return "text.quote"
        case .windowLeft: return "rectangle.lefthalf.filled"
        case .windowRight: return "rectangle.righthalf.filled"
        case .windowMaximize: return "rectangle.fill"
        }
    }
}

enum ItemAction {
    case openApp(URL)
    case openBookmark(String)
    case script(ScriptCommand)
    case snippet(String)
    case clipboard(ClipboardEntry)
    case builtin(Builtin)
}

struct ResultItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let kind: String
    let icon: ItemIcon
    let action: ItemAction
    /// あいまい一致にかける文字列
    let searchTexts: [String]
}

struct AppEntry {
    let name: String
    let fileName: String
    let url: URL
}

/// 検索の対象をまとめて持つ
final class Catalog {
    private(set) var apps: [AppEntry] = []
    private(set) var bookmarks: [Bookmark] = []
    private(set) var scripts: [ScriptCommand] = []
    private(set) var snippets: [Snippet] = []

    private var bookmarkStamp: FileStamp?
    private var snippetStamp: FileStamp?
    private var scanning = false

    var scriptsFolder: URL = Paths.expand(Paths.defaultScriptsFolder)

    static let appFolders: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        Paths.home.appendingPathComponent("Applications"),
    ]

    /// パネルを開くたびに呼ぶ。変わったものだけ読み直す
    func refresh(force: Bool = false) {
        let bStamp = FileStamp.of(ChromeBookmarksParser.defaultFileURL)
        if force || bStamp != bookmarkStamp {
            bookmarkStamp = bStamp
            if let data = try? Data(contentsOf: ChromeBookmarksParser.defaultFileURL) {
                bookmarks = ChromeBookmarksParser.parse(data: data)
            } else {
                bookmarks = []
            }
        }
        let sStamp = FileStamp.of(Paths.snippetsFile)
        if force || sStamp != snippetStamp {
            snippetStamp = sStamp
            snippets = SnippetFile.load(from: Paths.snippetsFile)
        }
        scripts = RaycastScriptParser.scan(folder: scriptsFolder)
        scanApps()
    }

    private func scanApps() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Catalog.findApps()
            DispatchQueue.main.async {
                self.apps = found
                self.scanning = false
            }
        }
    }

    static func findApps() -> [AppEntry] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [AppEntry] = []
        func add(_ url: URL) {
            let path = url.resolvingSymlinksInPath().path
            guard seen.insert(path).inserted else { return }
            let fileName = url.deletingPathExtension().lastPathComponent
            var name = fm.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            result.append(AppEntry(name: name, fileName: fileName, url: url))
        }
        // 直下とその下のフォルダ（Utilities など）まで見る
        func scan(_ dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for u in items {
                if u.pathExtension == "app" {
                    add(u)
                } else if depth > 0, (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    scan(u, depth: depth - 1)
                }
            }
        }
        for dir in appFolders { scan(dir, depth: 2) }
        // Finder はアプリ一覧に無いので足す
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        return result
    }

    // MARK: - 検索欄に出す形にする

    func allItems() -> [ResultItem] {
        var items: [ResultItem] = []
        for a in apps {
            items.append(ResultItem(id: "app:" + a.url.path, title: a.name, subtitle: a.url.deletingLastPathComponent().path,
                                    kind: "アプリ", icon: .file(a.url.path), action: .openApp(a.url),
                                    searchTexts: [a.name, a.fileName]))
        }
        for b in Builtin.allCases {
            items.append(ResultItem(id: "builtin:" + b.rawValue, title: b.title, subtitle: "", kind: "コマンド",
                                    icon: .symbol(b.symbol), action: .builtin(b), searchTexts: [b.title] + b.keywords))
        }
        for s in scripts {
            items.append(scriptItem(s))
        }
        items.append(contentsOf: snippetItems())
        for b in bookmarks {
            items.append(ResultItem(id: b.id, title: b.title, subtitle: b.url, kind: "ブックマーク", icon: .symbol("bookmark"),
                                    action: .openBookmark(b.url), searchTexts: [b.title, b.url]))
        }
        return items
    }

    func scriptItem(_ s: ScriptCommand) -> ResultItem {
        let subtitle = [s.packageName, s.description].compactMap { $0 }.joined(separator: " — ")
        let icon: ItemIcon = s.icon.map { $0.count <= 2 ? .emoji($0) : .symbol("terminal") } ?? .symbol("terminal")
        return ResultItem(id: s.id, title: s.title, subtitle: subtitle, kind: s.argument1 != nil ? "スクリプト ⇥" : "スクリプト",
                          icon: icon, action: .script(s), searchTexts: [s.title, s.packageName ?? ""])
    }

    func snippetItems() -> [ResultItem] {
        snippets.map { sn in
            ResultItem(id: sn.id, title: sn.name, subtitle: sn.text.replacingOccurrences(of: "\n", with: " ⏎ "),
                       kind: "スニペット", icon: .symbol("text.quote"), action: .snippet(sn.text),
                       searchTexts: [sn.name, sn.text])
        }
    }
}
