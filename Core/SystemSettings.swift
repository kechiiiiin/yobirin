import Foundation

/// システム設定の 1 項目（画面）
public struct SettingsPane: Equatable {
    public enum Source: Equatable {
        /// ExtensionKit の設定拡張（x-apple.systempreferences:<bundle id> で開く）
        case settingsExtension
        /// サードパーティの .prefPane（システム設定に渡して開く）
        case prefPane(path: String)
    }

    public var bundleID: String
    /// 表示名（日本語があれば日本語）
    public var title: String
    /// 検索に使う名前（日本語・英語・ファイル名）
    public var names: [String]
    public var source: Source

    public init(bundleID: String, title: String, names: [String], source: Source) {
        self.bundleID = bundleID
        self.title = title
        self.names = names
        self.source = source
    }

    public var id: String { "settings:" + bundleID }

    /// 設定拡張を開く URL。例: x-apple.systempreferences:com.apple.Displays-Settings.extension
    public var url: URL? { SystemSettingsParser.url(forBundleID: bundleID) }
}

/// Info.plist・InfoPlist.loctable・InfoPlist.strings から名前を取り出す純関数
public enum SystemSettingsParser {
    public static let settingsPointIdentifier = "com.apple.Settings.extension.ui"

    /// システム設定の項目か（ExtensionKit の拡張ポイントが設定の UI のもの）
    public static func isSettingsExtension(info: [String: Any]) -> Bool {
        guard let attrs = info["EXAppExtensionAttributes"] as? [String: Any] else { return false }
        return attrs["EXExtensionPointIdentifier"] as? String == settingsPointIdentifier
    }

    public static func url(forBundleID id: String) -> URL? {
        guard !id.isEmpty else { return nil }
        return URL(string: "x-apple.systempreferences:" + id)
    }

    /// 内部名にしか見えないもの（"XxxExtension"・パスの断片）は表示名にしない
    static func isUsableName(_ s: String?) -> Bool {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return false }
        if s.contains(".appex") || s.contains("/") { return false }
        if !s.contains(" "), s.hasSuffix("Extension") { return false }
        return true
    }

    /// loctable（言語 → [キー: 値]）か strings（キー → 値）から名前を 1 つ選ぶ
    static func name(from table: [String: Any]?) -> String? {
        guard let table else { return nil }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let v = table[key] as? String, isUsableName(v) { return v.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return nil
    }

    /// 日本語名と英語名。
    /// - loctable: InfoPlist.loctable を読んだもの（["ja": ["CFBundleDisplayName": …], …]）
    /// - lprojStrings: 言語 → InfoPlist.strings の中身（loctable が無いバンドル用。"ja"・"Japanese"・"en"・"English" など）
    /// 英語は loctable の en → en.lproj → Info.plist の CFBundleDisplayName → CFBundleName の順
    public static func names(info: [String: Any], loctable: [String: Any]?, lprojStrings: [String: [String: Any]] = [:])
        -> (ja: String?, en: String?)
    {
        func localized(_ langs: [String]) -> String? {
            for l in langs {
                if let n = name(from: loctable?[l] as? [String: Any]) { return n }
                if let n = name(from: lprojStrings[l]) { return n }
            }
            return nil
        }
        let ja = localized(["ja", "Japanese"])
        var en = localized(["en", "English", "Base"])
        if en == nil { en = name(from: info) }
        return (ja, en)
    }

    /// 拡張の Info.plist に表示名が無いもの（実物で確認）の補い。実物から取れた名前が使えないときだけ効く
    static let fallbackNames: [String: (ja: String, en: String)] = [
        "com.apple.Battery-Settings.extension": ("バッテリー", "Battery"),
        "com.apple.HeadphoneSettings": ("ヘッドフォン", "Headphones"),
    ]

    /// 項目を作る。名前がどれも使えなければ nil
    public static func pane(bundleID: String, ja: String?, en: String?, fileBaseName: String?, source: SettingsPane.Source) -> SettingsPane? {
        var ja = ja, en = en
        if let f = fallbackNames[bundleID] {
            if !isUsableName(ja) { ja = f.ja }
            if !isUsableName(en) { en = f.en }
        }
        var names: [String] = []
        for n in [ja, en, fileBaseName] {
            if isUsableName(n), let n = n?.trimmingCharacters(in: .whitespacesAndNewlines), !names.contains(n) { names.append(n) }
        }
        guard !bundleID.isEmpty, let title = names.first else { return nil }
        return SettingsPane(bundleID: bundleID, title: title, names: names, source: source)
    }
}

/// この Mac の実物から項目を集める
public enum SystemSettingsScanner {
    public static let extensionsFolder = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions")
    public static var prefPaneFolders: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/PreferencePanes"),
         URL(fileURLWithPath: "/Library/PreferencePanes")]
    }

    static func plist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return obj as? [String: Any]
    }

    public static func scan(extensionsFolder: URL = extensionsFolder, prefPaneFolders: [URL] = prefPaneFolders) -> [SettingsPane] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [SettingsPane] = []

        let appexes = ((try? fm.contentsOfDirectory(at: extensionsFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "appex" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for appex in appexes {
            let contents = appex.appendingPathComponent("Contents")
            guard let info = plist(at: contents.appendingPathComponent("Info.plist")),
                  SystemSettingsParser.isSettingsExtension(info: info),
                  let bundleID = info["CFBundleIdentifier"] as? String else { continue }
            let res = contents.appendingPathComponent("Resources")
            let loc = plist(at: res.appendingPathComponent("InfoPlist.loctable"))
            let n = SystemSettingsParser.names(info: info, loctable: loc, lprojStrings: lprojStrings(in: res))
            let base = appex.deletingPathExtension().lastPathComponent
            if let p = SystemSettingsParser.pane(bundleID: bundleID, ja: n.ja, en: n.en, fileBaseName: base, source: .settingsExtension),
               seen.insert(bundleID).inserted {
                result.append(p)
            }
        }

        // サードパーティの prefPane（システム標準のものは設定拡張に置き換わっているので対象外）
        for folder in prefPaneFolders {
            let panes = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "prefPane" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for pane in panes {
                let contents = pane.appendingPathComponent("Contents")
                guard let info = plist(at: contents.appendingPathComponent("Info.plist")),
                      let bundleID = info["CFBundleIdentifier"] as? String else { continue }
                var info2 = info
                if let label = info["NSPrefPaneIconLabel"] as? String, info2["CFBundleDisplayName"] == nil { info2["CFBundleDisplayName"] = label }
                let res = contents.appendingPathComponent("Resources")
                let n = SystemSettingsParser.names(info: info2, loctable: plist(at: res.appendingPathComponent("InfoPlist.loctable")),
                                                   lprojStrings: lprojStrings(in: res))
                let base = pane.deletingPathExtension().lastPathComponent
                if let p = SystemSettingsParser.pane(bundleID: bundleID, ja: n.ja, en: n.en, fileBaseName: base, source: .prefPane(path: pane.path)),
                   seen.insert(bundleID).inserted {
                    result.append(p)
                }
            }
        }
        return result
    }

    /// <言語>.lproj/InfoPlist.strings を読む（ja・Japanese・en・English・Base だけ）
    static func lprojStrings(in resources: URL) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for lang in ["ja", "Japanese", "en", "English", "Base"] {
            let f = resources.appendingPathComponent("\(lang).lproj/InfoPlist.strings")
            if let d = plist(at: f) { out[lang] = d }
        }
        return out
    }
}
