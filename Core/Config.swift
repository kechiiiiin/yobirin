import Foundation

/// 保存先の場所
public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var configDirectory: URL { home.appendingPathComponent(".config/yobirin") }
    public static var configFile: URL { configDirectory.appendingPathComponent("config.json") }
    public static var snippetsFile: URL { configDirectory.appendingPathComponent("snippets.json") }
    public static var defaultScriptsFolder: String { "~/.config/yobirin/scripts" }
    public static var supportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/yobirin")
    }
    public static var usageFile: URL { supportDirectory.appendingPathComponent("usage.json") }
    public static var clipboardDirectory: URL { supportDirectory.appendingPathComponent("clipboard") }

    public static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

/// ホットキー。modifiers は Carbon の値（cmdKey=256, shiftKey=512, optionKey=2048, controlKey=4096）
public struct Hotkey: Codable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let cmd: UInt32 = 256
    public static let shift: UInt32 = 512
    public static let option: UInt32 = 2048
    public static let control: UInt32 = 4096

    /// ⌘Space
    public static let defaultLauncher = Hotkey(keyCode: 49, modifiers: cmd)
}

public enum HotkeyAction: String, CaseIterable, Codable {
    case launcher, snippets, clipboard, emoji, windowLeft, windowRight, windowMaximize

    public var label: String {
        switch self {
        case .launcher: return "呼鈴を開く"
        case .snippets: return "スニペット一覧"
        case .clipboard: return "クリップボード履歴"
        case .emoji: return "絵文字"
        case .windowLeft: return "左半分"
        case .windowRight: return "右半分"
        case .windowMaximize: return "最大化"
        }
    }
}

public struct Config: Codable, Equatable {
    /// 未登録のキーは含めない（null も同じ扱い）
    public var hotkeys: [String: Hotkey]
    public var scriptsFolder: String
    public var launchAtLogin: Bool
    /// 検索結果から除外した項目の id（app:パス・bookmark:URL・script:パス・snippet:名前）
    public var excluded: [String]
    /// hotkeys に加えて登録するキー（1 つの操作に複数のキー）。設定画面には出さず、ファイルで書く
    /// 例: パスワード欄では ⌥ だけのキーが文字入力に取られるので、⌃⌥V を足しておく
    public var extraHotkeys: [String: [Hotkey]]

    public init(hotkeys: [String: Hotkey] = [HotkeyAction.launcher.rawValue: .defaultLauncher],
                scriptsFolder: String = Paths.defaultScriptsFolder,
                launchAtLogin: Bool = true,
                excluded: [String] = [],
                extraHotkeys: [String: [Hotkey]] = [:]) {
        self.hotkeys = hotkeys
        self.scriptsFolder = scriptsFolder
        self.launchAtLogin = launchAtLogin
        self.excluded = excluded
        self.extraHotkeys = extraHotkeys
    }

    enum CodingKeys: String, CodingKey { case hotkeys, scriptsFolder, launchAtLogin, excluded, extraHotkeys }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: Hotkey?].self, forKey: .hotkeys)
        if let raw {
            hotkeys = raw.compactMapValues { $0 }
        } else {
            hotkeys = [HotkeyAction.launcher.rawValue: .defaultLauncher]
        }
        scriptsFolder = try c.decodeIfPresent(String.self, forKey: .scriptsFolder) ?? Paths.defaultScriptsFolder
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? []
        extraHotkeys = try c.decodeIfPresent([String: [Hotkey]].self, forKey: .extraHotkeys) ?? [:]
    }

    /// 書き出しでは、追加キーが無いときは extraHotkeys を省く（既存の config.json の見た目を変えない）
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hotkeys, forKey: .hotkeys)
        try c.encode(scriptsFolder, forKey: .scriptsFolder)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(excluded, forKey: .excluded)
        if !extraHotkeys.isEmpty { try c.encode(extraHotkeys, forKey: .extraHotkeys) }
    }

    /// 除外リストの id から、設定画面に出す名前を作る（アプリ・スクリプトはファイル名、スニペットは名前、ブックマークは URL）
    public static func displayName(forExcludedID id: String) -> String {
        if id.hasPrefix("app:") || id.hasPrefix("script:") {
            let path = String(id[id.index(after: id.firstIndex(of: ":")!)...])
            let base = (path as NSString).lastPathComponent
            return id.hasPrefix("app:") ? (base as NSString).deletingPathExtension : base
        }
        if id.hasPrefix("snippet:") { return String(id.dropFirst(8)) }
        if id.hasPrefix("bookmark:") { return String(id.dropFirst(9)) }
        return id
    }

    public func hotkey(_ action: HotkeyAction) -> Hotkey? { hotkeys[action.rawValue] }

    /// その操作に登録する全部のキー（hotkeys の 1 つ＋extraHotkeys。重複は除く）
    public func allHotkeys(_ action: HotkeyAction) -> [Hotkey] {
        var result: [Hotkey] = []
        for k in [hotkey(action)].compactMap({ $0 }) + (extraHotkeys[action.rawValue] ?? []) where !result.contains(k) {
            result.append(k)
        }
        return result
    }

    public mutating func setHotkey(_ action: HotkeyAction, _ key: Hotkey?) {
        hotkeys[action.rawValue] = key
    }

    public static func load(from url: URL) -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        return (try? JSONDecoder().decode(Config.self, from: data)) ?? Config()
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

public struct Snippet: Codable, Equatable {
    public var name: String
    public var text: String
    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
    public var id: String { "snippet:" + name }
}

public enum SnippetFile {
    public static func load(from url: URL) -> [Snippet] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Snippet].self, from: data)) ?? []
    }

    public static func save(_ snippets: [Snippet], to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try enc.encode(snippets)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public enum Issue: Equatable {
        case emptyName
        case duplicateName
    }

    /// 保存前の検査。名前が空（空白だけも）・重複（id が snippet:<名前> のため）を、並び順の位置ごとに返す
    public static func issues(in snippets: [Snippet]) -> [Int: Issue] {
        var counts: [String: Int] = [:]
        for s in snippets { counts[s.name, default: 0] += 1 }
        var result: [Int: Issue] = [:]
        for (i, s) in snippets.enumerated() {
            if s.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result[i] = .emptyName
            } else if counts[s.name, default: 0] > 1 {
                result[i] = .duplicateName
            }
        }
        return result
    }

    /// 無ければ空の雛形（[]）を作る
    public static func ensureExists(at url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("[]\n".utf8).write(to: url, options: .atomic)
    }
}

/// ファイルの更新日時で変化を見る
public struct FileStamp: Equatable {
    public var modified: Date?
    public var size: Int?

    public static func of(_ url: URL) -> FileStamp {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return FileStamp(modified: attrs?[.modificationDate] as? Date, size: (attrs?[.size] as? NSNumber)?.intValue)
    }
}
