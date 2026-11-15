import XCTest
@testable import YobirinCore

final class RaycastScriptParserTests: XCTestCase {
    // テスト用のダミー（実在のスクリプトは読まない・実行しない）
    let sample = """
    #!/bin/bash

    # Raycast Script Command
    # @raycast.schemaVersion 1
    # @raycast.title ダミーの送信
    # @raycast.mode compact
    # @raycast.packageName テスト用
    # @raycast.icon 🔔
    # @raycast.argument1 { "type": "text", "placeholder": "送る言葉" }
    #
    # Documentation:
    # @raycast.description 引数をそのまま表示するだけ
    # @raycast.author test

    echo "$1"
    """

    func testParsesHeader() throws {
        let cmd = try XCTUnwrap(RaycastScriptParser.parse(contents: sample, path: "/tmp/dummy.sh"))
        XCTAssertEqual(cmd.title, "ダミーの送信")
        XCTAssertEqual(cmd.mode, .compact)
        XCTAssertEqual(cmd.packageName, "テスト用")
        XCTAssertEqual(cmd.icon, "🔔")
        XCTAssertEqual(cmd.description, "引数をそのまま表示するだけ")
        XCTAssertEqual(cmd.argument1, ScriptArgument(type: "text", placeholder: "送る言葉", optional: false))
        XCTAssertEqual(cmd.id, "script:/tmp/dummy.sh")
    }

    func testDefaultsAndMissingTitle() {
        let noTitle = "#!/bin/bash\n# @raycast.mode silent\necho hi\n"
        XCTAssertNil(RaycastScriptParser.parse(contents: noTitle, path: "/x"))

        let minimal = "#!/usr/bin/env node\n// @raycast.title 最小\n// @raycast.argument1 {\"type\":\"text\",\"placeholder\":\"q\",\"optional\":true}\n"
        let cmd = RaycastScriptParser.parse(contents: minimal, path: "/y")
        XCTAssertEqual(cmd?.title, "最小")
        XCTAssertEqual(cmd?.mode, .fullOutput)
        XCTAssertNil(cmd?.icon)
        XCTAssertEqual(cmd?.argument1?.optional, true)
    }

    func testSilentModeAndBrokenArgument() {
        let s = "# @raycast.title 静か\n# @raycast.mode silent\n# @raycast.argument1 {壊れた JSON\n"
        let cmd = RaycastScriptParser.parse(contents: s, path: "/z")
        XCTAssertEqual(cmd?.mode, .silent)
        XCTAssertNil(cmd?.argument1)
    }

    func testScanFolderOnlyExecutables() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("a.sh")
        try sample.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let notExe = dir.appendingPathComponent("b.sh")
        try sample.write(to: notExe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notExe.path)
        let found = RaycastScriptParser.scan(folder: dir)
        XCTAssertEqual(found.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["a.sh"])
    }

    func testLastLine() {
        XCTAssertEqual(RaycastScriptParser.lastLine(of: "一行目\n送信しました\n\n"), "送信しました")
        XCTAssertEqual(RaycastScriptParser.lastLine(of: ""), "")
    }
}

final class FuzzyMatcherTests: XCTestCase {
    func testTierOrder() throws {
        let prefix = try XCTUnwrap(FuzzyMatcher.score(query: "goo", candidate: "Google Chrome"))
        let word = try XCTUnwrap(FuzzyMatcher.score(query: "chr", candidate: "Google Chrome"))
        let sub = try XCTUnwrap(FuzzyMatcher.score(query: "hro", candidate: "Google Chrome"))
        let fuzzy = try XCTUnwrap(FuzzyMatcher.score(query: "gc", candidate: "Google Chrome"))
        XCTAssertGreaterThan(prefix, word)
        XCTAssertGreaterThan(word, sub)
        XCTAssertGreaterThan(sub, fuzzy)
        XCTAssertNil(FuzzyMatcher.score(query: "xyz", candidate: "Google Chrome"))
    }

    func testCamelCaseWordStart() throws {
        let camel = try XCTUnwrap(FuzzyMatcher.score(query: "time", candidate: "QuickTimePlayer"))
        let inner = try XCTUnwrap(FuzzyMatcher.score(query: "ckti", candidate: "QuickTimePlayer"))
        XCTAssertGreaterThanOrEqual(camel, FuzzyMatcher.wordStartScore - 200)
        XCTAssertLessThan(inner, FuzzyMatcher.wordStartScore - 200)
    }

    func testJapaneseAndKanaInsensitive() {
        XCTAssertNotNil(FuzzyMatcher.score(query: "しすてむ", candidate: "システム設定"))
        XCTAssertNotNil(FuzzyMatcher.score(query: "ＳＡＦ", candidate: "Safari"))
    }

    func testRankerOrdersByTierThenUsage() {
        let items = [
            RankCandidate(id: "sub", texts: ["Notes Pro"]),     // 部分一致 "ote"
            RankCandidate(id: "prefix", texts: ["Otemachi"]),   // 先頭一致
            RankCandidate(id: "word", texts: ["Big Otello"]),    // 単語頭一致
            RankCandidate(id: "none", texts: ["Calendar"]),
        ]
        let order = Ranker.rank(items, query: "ote", usage: [:]).map { items[$0].id }
        XCTAssertEqual(order, ["prefix", "word", "sub"])

        // 同じ段なら、選んだ回数・最近さが多いほうが上
        let same = [RankCandidate(id: "a", texts: ["Slack"]), RankCandidate(id: "b", texts: ["Slides"])]
        let now = Date()
        let usage = ["b": UsageRecord(count: 10, lastUsed: now)]
        let order2 = Ranker.rank(same, query: "sl", usage: usage, now: now).map { same[$0].id }
        XCTAssertEqual(order2, ["b", "a"])
    }

    func testEmptyQueryShowsUsedItemsOnly() {
        let items = [RankCandidate(id: "a", texts: ["A"]), RankCandidate(id: "b", texts: ["B"])]
        let now = Date()
        let usage = ["b": UsageRecord(count: 1, lastUsed: now)]
        XCTAssertEqual(Ranker.rank(items, query: "", usage: usage, now: now), [1])
    }

    func testRecencyDecays() {
        let now = Date()
        let fresh = Ranker.usageBoost(UsageRecord(count: 3, lastUsed: now), now: now)
        let old = Ranker.usageBoost(UsageRecord(count: 3, lastUsed: now.addingTimeInterval(-30 * 86400)), now: now)
        XCTAssertGreaterThan(fresh, old)
        XCTAssertLessThan(fresh, 1000)
    }
}

final class WindowCyclerTests: XCTestCase {
    let visible = CGRect(x: 0, y: 25, width: 1200, height: 775)

    func testLeftCycles() {
        let c = WindowCycler()
        var current = CGRect(x: 300, y: 200, width: 500, height: 400)
        var widths: [CGFloat] = []
        for _ in 0..<4 {
            let f = c.next(direction: .left, current: current, visible: visible)
            XCTAssertEqual(f.minX, 0)
            XCTAssertEqual(f.minY, 25)
            XCTAssertEqual(f.height, 775)
            widths.append(f.width)
            current = f
        }
        XCTAssertEqual(widths, [600, 800, 400, 600])
    }

    func testRightAlignsToRightEdge() {
        let c = WindowCycler()
        let f1 = c.next(direction: .right, current: .zero, visible: visible)
        XCTAssertEqual(f1, CGRect(x: 600, y: 25, width: 600, height: 775))
        let f2 = c.next(direction: .right, current: f1, visible: visible)
        XCTAssertEqual(f2, CGRect(x: 400, y: 25, width: 800, height: 775))
        let f3 = c.next(direction: .right, current: f2, visible: visible)
        XCTAssertEqual(f3, CGRect(x: 800, y: 25, width: 400, height: 775))
    }

    func testResetWhenMovedOrDirectionChanges() {
        let c = WindowCycler()
        let f1 = c.next(direction: .left, current: .zero, visible: visible)
        // ユーザーがウィンドウを動かした → 1/2 からやり直し
        let moved = f1.offsetBy(dx: 100, dy: 50)
        XCTAssertEqual(c.next(direction: .left, current: moved, visible: visible).width, 600)
        // 方向が変わった → 1/2 から
        let l2 = c.next(direction: .left, current: CGRect(x: 0, y: 25, width: 600, height: 775), visible: visible)
        XCTAssertEqual(l2.width, 800)
        let r = c.next(direction: .right, current: l2, visible: visible)
        XCTAssertEqual(r.width, 600)
    }

    func testMaximizeAndCoordinateConversion() {
        let c = WindowCycler()
        XCTAssertEqual(c.next(direction: .maximize, current: .zero, visible: visible), visible)
        // 主画面 900pt の高さ・Cocoa で下から 70pt の位置にある高さ 800 の枠 → AX では上から 30
        let ax = WindowCycler.cocoaToAX(CGRect(x: 0, y: 70, width: 1440, height: 800), primaryScreenHeight: 900)
        XCTAssertEqual(ax, CGRect(x: 0, y: 30, width: 1440, height: 800))
    }
}

final class ChromeBookmarksTests: XCTestCase {
    func testNestedFolders() {
        let json = """
        {
          "checksum": "x",
          "roots": {
            "bookmark_bar": {
              "children": [
                { "name": "GitHub", "type": "url", "url": "https://github.com/" },
                { "name": "仕事", "type": "folder", "children": [
                    { "name": "勤怠", "type": "url", "url": "https://example.com/kintai" },
                    { "name": "深い", "type": "folder", "children": [
                        { "name": "", "type": "url", "url": "https://example.com/deep" }
                    ]}
                ]}
              ],
              "name": "ブックマーク バー", "type": "folder"
            },
            "other": { "children": [ { "name": "その他1", "type": "url", "url": "https://example.org/" } ], "name": "その他のブックマーク", "type": "folder" },
            "synced": { "children": [], "name": "モバイルのブックマーク", "type": "folder" }
          },
          "version": 1
        }
        """
        let b = ChromeBookmarksParser.parse(data: Data(json.utf8))
        XCTAssertEqual(b.map(\.url), ["https://github.com/", "https://example.com/kintai", "https://example.com/deep", "https://example.org/"])
        XCTAssertEqual(b[1].folder, "ブックマーク バー / 仕事")
        XCTAssertEqual(b[2].folder, "ブックマーク バー / 仕事 / 深い")
        XCTAssertEqual(b[2].title, "https://example.com/deep")  // 名前が空なら URL を出す
        XCTAssertEqual(b[3].folder, "その他のブックマーク")
    }

    func testBrokenJSON() {
        XCTAssertEqual(ChromeBookmarksParser.parse(data: Data("not json".utf8)), [])
    }
}

final class ClipboardStoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("yobirin-test-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSkipMarkers() {
        XCTAssertTrue(ClipboardFilter.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(ClipboardFilter.shouldSkip(types: ["org.nspasteboard.TransientType"]))
        XCTAssertTrue(ClipboardFilter.shouldSkip(types: ["org.nspasteboard.AutoGeneratedType", "public.png"]))
        XCTAssertFalse(ClipboardFilter.shouldSkip(types: ["public.utf8-plain-text", "public.html"]))
    }

    func testPruneOlderThan30Days() throws {
        let store = ClipboardStore(directory: dir)
        let now = Date()
        store.addText("古い", date: now.addingTimeInterval(-31 * 86400))
        store.addText("新しい", date: now.addingTimeInterval(-29 * 86400))
        let oldImage = try XCTUnwrap(store.addImage(Data([1, 2, 3]), type: "png", date: now.addingTimeInterval(-40 * 86400)))
        let oldImageURL = try XCTUnwrap(store.imageURL(for: oldImage))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldImageURL.path))

        XCTAssertEqual(store.prune(now: now), 2)
        XCTAssertEqual(store.entries.map(\.text), ["新しい"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldImageURL.path))

        // 読み直しても残っている
        let reloaded = ClipboardStore(directory: dir)
        XCTAssertEqual(reloaded.entries.map(\.text), ["新しい"])
    }

    func testDuplicateMovesToTop() {
        let store = ClipboardStore(directory: dir)
        let t0 = Date()
        store.addText("a", date: t0)
        store.addText("b", date: t0.addingTimeInterval(1))
        store.addText("a", date: t0.addingTimeInterval(2))
        XCTAssertEqual(store.entries.map(\.text), ["a", "b"])
        XCTAssertNil(store.addText("   \n"))
    }
}

final class ConfigTests: XCTestCase {
    func testDefaultsAndNullHotkeys() throws {
        let json = #"{"hotkeys": {"launcher": {"keyCode": 49, "modifiers": 256}, "snippets": null}}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(c.hotkey(.launcher), .defaultLauncher)
        XCTAssertNil(c.hotkey(.snippets))
        XCTAssertEqual(c.scriptsFolder, "~/.config/yobirin/scripts")
        XCTAssertTrue(c.launchAtLogin)
        XCTAssertEqual(Config().hotkey(.launcher), .defaultLauncher)
    }

    func testExcludedDefaultsToEmptyForOldFile() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"launchAtLogin": false}"#.utf8))
        XCTAssertEqual(c.excluded, [])
    }

    func testExcludedRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yobirin-cfg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var c = Config()
        c.excluded = ["app:/Applications/Chess.app", "bookmark:https://example.com/"]
        try c.save(to: url)
        XCTAssertEqual(Config.load(from: url).excluded, c.excluded)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("\"excluded\""))
    }

    func testDisplayNameForExcludedID() {
        XCTAssertEqual(Config.displayName(forExcludedID: "app:/Applications/Chess.app"), "Chess")
        XCTAssertEqual(Config.displayName(forExcludedID: "script:/x/y/hello.sh"), "hello.sh")
        XCTAssertEqual(Config.displayName(forExcludedID: "snippet:署名"), "署名")
        XCTAssertEqual(Config.displayName(forExcludedID: "bookmark:https://a.b/"), "https://a.b/")
    }

    func testExtraHotkeysAddToMainKeyWithoutDuplicates() throws {
        let json = #"""
        {"hotkeys": {"snippets": {"keyCode": 9, "modifiers": 2048}},
         "extraHotkeys": {"snippets": [{"keyCode": 9, "modifiers": 6144}, {"keyCode": 9, "modifiers": 2048}],
                          "windowMaximize": [{"keyCode": 126, "modifiers": 4608}]}}
        """#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(c.allHotkeys(.snippets), [Hotkey(keyCode: 9, modifiers: 2048), Hotkey(keyCode: 9, modifiers: 6144)])
        // 主のキーが無くても、追加キーだけで登録できる
        XCTAssertEqual(c.allHotkeys(.windowMaximize), [Hotkey(keyCode: 126, modifiers: 4608)])
        XCTAssertEqual(c.allHotkeys(.clipboard), [])
    }

    func testExtraHotkeysRoundTripAndOmittedWhenEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yobirin-cfg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Config().save(to: url)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("extraHotkeys"))
        XCTAssertEqual(Config.load(from: url).extraHotkeys, [:])

        var c = Config()
        c.extraHotkeys = ["clipboard": [Hotkey(keyCode: 8, modifiers: 6144)]]
        try c.save(to: url)
        XCTAssertEqual(Config.load(from: url), c)
    }
}

final class SnippetFileTests: XCTestCase {
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("yobirin-snip-\(UUID().uuidString)/snippets.json")
    }

    func testRoundTripWithNewlinesAndJapanese() throws {
        let url = tmp()
        let items = [Snippet(name: "署名", text: "よろしくお願いします。\n山内\n"), Snippet(name: "a/b", text: "\"引用\" と 😀")]
        try SnippetFile.save(items, to: url)
        XCTAssertEqual(SnippetFile.load(from: url), items)
    }

    func testAddEditDelete() throws {
        let url = tmp()
        var items = [Snippet(name: "一", text: "1")]
        try SnippetFile.save(items, to: url)
        items.append(Snippet(name: "二", text: "2\n2"))
        try SnippetFile.save(items, to: url)
        XCTAssertEqual(SnippetFile.load(from: url).count, 2)
        items[0].text = "改"
        try SnippetFile.save(items, to: url)
        XCTAssertEqual(SnippetFile.load(from: url)[0].text, "改")
        items.remove(at: 0)
        try SnippetFile.save(items, to: url)
        XCTAssertEqual(SnippetFile.load(from: url), [Snippet(name: "二", text: "2\n2")])
    }

    func testLoadsHandWrittenFormat() throws {
        let url = tmp()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"[{"name":"住所","text":"a\nb"}]"#.utf8).write(to: url)
        XCTAssertEqual(SnippetFile.load(from: url), [Snippet(name: "住所", text: "a\nb")])
    }

    func testIssues() {
        let items = [Snippet(name: "a", text: ""), Snippet(name: " ", text: "x"), Snippet(name: "a", text: "y"), Snippet(name: "b", text: "")]
        let issues = SnippetFile.issues(in: items)
        XCTAssertEqual(issues[0], .duplicateName)
        XCTAssertEqual(issues[1], .emptyName)
        XCTAssertEqual(issues[2], .duplicateName)
        XCTAssertNil(issues[3])
        XCTAssertTrue(SnippetFile.issues(in: []).isEmpty)
    }
}

final class SystemSettingsParserTests: XCTestCase {
    // 実物の形を真似たダミー（実在の設定は読まない）
    let info: [String: Any] = [
        "CFBundleIdentifier": "com.example.Dummy-Settings.extension",
        "CFBundleDisplayName": "Dummy Display",
        "CFBundleName": "DummyExt",
        "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": "com.apple.Settings.extension.ui"],
    ]

    func testIsSettingsExtension() {
        XCTAssertTrue(SystemSettingsParser.isSettingsExtension(info: info))
        var other = info
        other["EXAppExtensionAttributes"] = ["EXExtensionPointIdentifier": "com.apple.appintents-extension"]
        XCTAssertFalse(SystemSettingsParser.isSettingsExtension(info: other))
        XCTAssertFalse(SystemSettingsParser.isSettingsExtension(info: ["CFBundleIdentifier": "x"]))
    }

    func testNamesFromLoctable() {
        let loc: [String: Any] = [
            "ja": ["CFBundleDisplayName": "ディスプレイ"],
            "en": ["CFBundleDisplayName": "Displays", "CFBundleName": "DisplaysExt"],
        ]
        let n = SystemSettingsParser.names(info: info, loctable: loc)
        XCTAssertEqual(n.ja, "ディスプレイ")
        XCTAssertEqual(n.en, "Displays")
    }

    func testEnglishFallsBackToInfoAndJapaneseToStrings() {
        let n = SystemSettingsParser.names(info: info, loctable: nil, lprojStrings: ["ja": ["CFBundleName": "ダミー"]])
        XCTAssertEqual(n.ja, "ダミー")
        XCTAssertEqual(n.en, "Dummy Display")
        let none = SystemSettingsParser.names(info: ["CFBundleName": "FooExtension"], loctable: [:])
        XCTAssertNil(none.ja)
        XCTAssertNil(none.en)
    }

    func testPaneAndURL() throws {
        let p = try XCTUnwrap(SystemSettingsParser.pane(bundleID: "com.apple.Displays-Settings.extension", ja: "ディスプレイ",
                                                         en: "Displays", fileBaseName: "DisplaysExt", source: .settingsExtension))
        XCTAssertEqual(p.title, "ディスプレイ")
        XCTAssertEqual(p.names, ["ディスプレイ", "Displays", "DisplaysExt"])
        XCTAssertEqual(p.id, "settings:com.apple.Displays-Settings.extension")
        XCTAssertEqual(p.url?.absoluteString, "x-apple.systempreferences:com.apple.Displays-Settings.extension")
        XCTAssertNil(SystemSettingsParser.pane(bundleID: "a", ja: nil, en: "XExtension", fileBaseName: nil, source: .settingsExtension))
    }

    func testScanDummyFolders() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("yobirin-ss-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let ext = root.appendingPathComponent("Ext")
        func write(_ dict: [String: Any], to url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0).write(to: url)
        }
        try write(info, to: ext.appendingPathComponent("Dummy.appex/Contents/Info.plist"))
        try write(["ja": ["CFBundleDisplayName": "ダミー設定"]], to: ext.appendingPathComponent("Dummy.appex/Contents/Resources/InfoPlist.loctable"))
        var notSettings = info
        notSettings["CFBundleIdentifier"] = "com.example.Other"
        notSettings["EXAppExtensionAttributes"] = ["EXExtensionPointIdentifier": "com.apple.appintents-extension"]
        try write(notSettings, to: ext.appendingPathComponent("Other.appex/Contents/Info.plist"))
        let pp = root.appendingPathComponent("PP")
        try write(["CFBundleIdentifier": "com.example.pane", "CFBundleName": "ThirdPane"], to: pp.appendingPathComponent("Third.prefPane/Contents/Info.plist"))

        let panes = SystemSettingsScanner.scan(extensionsFolder: ext, prefPaneFolders: [pp])
        XCTAssertEqual(panes.map(\.bundleID), ["com.example.Dummy-Settings.extension", "com.example.pane"])
        XCTAssertEqual(panes[0].title, "ダミー設定")
        if case .prefPane(let path) = panes[1].source { XCTAssertTrue(path.hasSuffix("/PP/Third.prefPane")) } else { XCTFail() }
    }
}

final class EmojiDataTests: XCTestCase {
    func testLoadsJapaneseAndEnglishNamesFromStrings() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("yobirin-emoji-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for (lang, dict) in [("ja", ["🐈‍⬛": "黒猫", "😀": "にっこり笑う", "#️⃣": "番号記号", "🇹🇼@CH-SKU": "地域向けの別名"]),
                             ("en", ["🐈‍⬛": "black cat", "😀": "grinning face", "#️⃣": "number sign"])] {
            let dir = root.appendingPathComponent("\(lang).lproj")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
            try data.write(to: dir.appendingPathComponent("AppleName.strings"))
        }
        let all = EmojiData.load(resources: root)
        XCTAssertEqual(all.map(\.emoji), ["😀", "🐈‍⬛", "#️⃣"])   // Unicode の推奨の並び（顔 → 動物 → 記号）
        // 並び順に無いものは後ろに文字コード順。U+FE0F の有無は区別しない
        let custom = EmojiData.load(resources: root, order: ["#\u{20E3}", "🐈‍⬛"])
        XCTAssertEqual(custom.map(\.emoji), ["#️⃣", "🐈‍⬛", "😀"])
        let cat = try XCTUnwrap(all.first { $0.emoji == "🐈‍⬛" })
        XCTAssertEqual(cat.nameEn, "black cat")
        XCTAssertEqual(cat.reading, "くろねこ")
        XCTAssertEqual(cat.id, "emoji:🐈‍⬛")
        XCTAssertNotNil(FuzzyMatcher.bestScore(query: "ねこ", candidates: cat.searchTexts))
        XCTAssertNotNil(FuzzyMatcher.bestScore(query: "cat", candidates: cat.searchTexts))
    }

    func testDefaultOrderStartsWithFacesAndEndsWithFlags() {
        let order = EmojiData.defaultOrder
        XCTAssertGreaterThan(order.count, 1800)
        XCTAssertEqual(order.first, "😀")
        XCTAssertTrue(order.last?.unicodeScalars.first.map { (0x1F1E6...0x1F3F4).contains($0.value) } ?? false)
        XCTAssertFalse(order.contains { $0.unicodeScalars.contains { (0x1F3FB...0x1F3FF).contains($0.value) } })
    }

    func testMissingFolderGivesEmptyList() {
        XCTAssertTrue(EmojiData.load(resources: URL(fileURLWithPath: "/nonexistent/yobirin")).isEmpty)
    }
}
