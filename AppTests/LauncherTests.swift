import AppKit
import SwiftUI
import XCTest
@testable import Yobirin
import YobirinCore

/// 検索パネルのモデルと描画のテスト。パネルは出さず、画面外のウインドウに NSHostingView を置いて確かめる
final class LauncherTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("yobirin-apptests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// 実在しないパスのダミーアプリ（起動もアイコン読み込みもしない）
    private func app(_ name: String) -> AppEntry {
        AppEntry(name: name, fileName: name, url: URL(fileURLWithPath: "/nonexistent/yobirin-tests/\(name).app"))
    }

    private func makeModel() -> LauncherModel {
        let names = ["cmux", "Codex", "Chess", "Clock", "Claude", "ChatGPT", "Console", "Caret-T", "Calendar", "Safari"]
        let catalog = Catalog(apps: names.map(app),
                              snippets: [Snippet(name: "同じ名前", text: "一"), Snippet(name: "同じ名前", text: "二")])
        let model = LauncherModel(catalog: catalog, usage: UsageStore(fileURL: nil),
                                  clipboard: ClipboardStore(directory: tempDir))
        model.reset(to: .all)
        return model
    }

    // MARK: - モデル

    func testQueryChangeRefiltersEveryKeystroke() {
        let model = makeModel()
        model.query = "c"
        let afterC = model.items.map(\.title)
        XCTAssertTrue(afterC.contains("cmux"))
        model.query = "cl"
        model.query = "cla"
        let afterCla = model.items.map(\.title)
        XCTAssertNotEqual(afterC, afterCla)
        XCTAssertEqual(afterCla.first, "Claude")
        XCTAssertFalse(afterCla.contains("cmux"))
        XCTAssertEqual(model.selected, 0)
    }

    func testExpressionShowsCalculationFirst() {
        let model = makeModel()
        model.query = "12*3"
        XCTAssertEqual(model.items.first?.title, "= 36")
        if case .copyText(let t)? = model.items.first?.action { XCTAssertEqual(t, "36") } else { XCTFail("コピーの動作でない") }
        model.query = "cla"
        XCTAssertNotEqual(model.items.first?.id, "calc")
        XCTAssertFalse(model.excludeSelected() && model.items.first?.id == "calc")
    }

    func testRefilterDropsExcluded() {
        let model = makeModel()
        model.query = "cl"
        XCTAssertTrue(model.items.map(\.title).contains("Claude"))
        model.excluded = ["app:/nonexistent/yobirin-tests/Claude.app"]
        model.refilter()
        XCTAssertFalse(model.items.map(\.title).contains("Claude"))
        model.reset(to: .snippets)
        XCTAssertEqual(model.items.count, 1)   // 同名は先に出たほうだけ
        model.excluded = ["snippet:同じ名前"]
        model.refilter()
        XCTAssertTrue(model.items.isEmpty)
    }

    func testExcludeSelectedKeepsIndexAndSkipsBuiltin() {
        let model = makeModel()
        model.query = "cl"
        let titles = model.items.map(\.title)
        XCTAssertGreaterThan(titles.count, 2)
        model.selected = 1
        var got: ResultItem?
        model.onExclude = { got = $0 }
        XCTAssertTrue(model.excludeSelected())
        XCTAssertEqual(got?.title, titles[1])
        XCTAssertEqual(model.selected, 1)
        XCTAssertEqual(model.items.first(where: { $0.title == titles[1] })?.title, nil)
        XCTAssertEqual(model.selectedItem?.title, titles[2])
        // 組み込みコマンドは対象外
        model.query = "呼鈴の設定"
        XCTAssertEqual(model.selectedItem?.title, "呼鈴の設定")
        XCTAssertFalse(model.excludeSelected())
        XCTAssertTrue(model.excluded.count == 1)
    }

    func testMoveWrapsAndQueryResetsSelection() {
        let model = makeModel()
        model.query = "c"
        let n = model.items.count
        XCTAssertGreaterThan(n, 2)
        model.move(1)
        XCTAssertEqual(model.selected, 1)
        model.move(-2)
        XCTAssertEqual(model.selected, n - 1)
        model.move(1)
        XCTAssertEqual(model.selected, 0)
        model.move(1)
        model.query = "cl"
        XCTAssertEqual(model.selected, 0)
    }

    func testMoveOnEmptyListDoesNothing() {
        let model = makeModel()
        model.query = "zzzzqqq"
        XCTAssertTrue(model.items.isEmpty)
        model.move(1)
        XCTAssertEqual(model.selected, 0)
    }

    func testDuplicateIDsAreDropped() {
        let model = makeModel()
        model.query = "同じ名前"
        let ids = model.items.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(ids.filter { $0 == "snippet:同じ名前" }.count, 1)
    }

    func testEmojiModeSearchesAndListsUsedFirst() {
        let emojis = [EmojiEntry(emoji: "😀", nameJa: "にっこり笑う", nameEn: "grinning face"),
                      EmojiEntry(emoji: "🐈‍⬛", nameJa: "黒猫", nameEn: "black cat", reading: "くろねこ"),
                      EmojiEntry(emoji: "👍", nameJa: "いいね", nameEn: "thumbs up")]
        let usage = UsageStore(fileURL: nil)
        usage.record("emoji:👍")
        let model = LauncherModel(catalog: Catalog(apps: [app("Cat App")], emojis: emojis), usage: usage,
                                  clipboard: ClipboardStore(directory: tempDir))
        model.reset(to: .emoji)
        XCTAssertEqual(model.items.map(\.id), ["emoji:👍", "emoji:😀", "emoji:🐈‍⬛"])
        model.query = "ねこ"
        XCTAssertEqual(model.items.map(\.id), ["emoji:🐈‍⬛"])
        model.query = "cat"
        XCTAssertEqual(model.items.first?.title, "黒猫")
        XCTAssertFalse(model.items.contains { $0.kind == "アプリ" })   // 絵文字モードではアプリを出さない
        XCTAssertFalse(model.excludeSelected())
        // 最初の検索欄には絵文字を混ぜない。「絵文字を探す」から入る
        model.reset(to: .all)
        model.query = "絵文字"
        XCTAssertEqual(model.items.first?.id, "builtin:emojiPicker")
        model.query = "cat"
        XCTAssertFalse(model.items.contains { $0.kind == "絵文字" })
    }

    func testMoveInEmojiGrid() {
        let emojis = (0..<25).map { EmojiEntry(emoji: String(UnicodeScalar(0x1F600 + $0)!), nameJa: "顔\($0)", nameEn: "face \($0)") }
        let model = LauncherModel(catalog: Catalog(apps: [], emojis: emojis), usage: UsageStore(fileURL: nil),
                                  clipboard: ClipboardStore(directory: tempDir))
        model.reset(to: .emoji)
        XCTAssertEqual(LauncherModel.emojiColumns, 10)
        model.moveInGrid(dx: -1, dy: 0); XCTAssertEqual(model.selected, 0)    // 左端で止まる
        model.moveInGrid(dx: 0, dy: -1); XCTAssertEqual(model.selected, 0)    // 上端で止まる
        model.moveInGrid(dx: 3, dy: 0); XCTAssertEqual(model.selected, 3)
        model.moveInGrid(dx: 0, dy: 1); XCTAssertEqual(model.selected, 13)    // 1 行下
        model.moveInGrid(dx: 0, dy: 1); XCTAssertEqual(model.selected, 23)
        model.moveInGrid(dx: 0, dy: 1); XCTAssertEqual(model.selected, 23)    // 最後の行では止まる
        model.selected = 17
        model.moveInGrid(dx: 0, dy: 1); XCTAssertEqual(model.selected, 24)    // 下が足りなければ末尾へ
        model.moveInGrid(dx: 1, dy: 0); XCTAssertEqual(model.selected, 24)
        model.moveInGrid(dx: 0, dy: -1); XCTAssertEqual(model.selected, 14)
    }

    // MARK: - 描画

    private func render(_ view: NSView) -> Data {
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])!
    }

    private func host(_ model: LauncherModel) -> (NSWindow, NSView) {
        let w = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 700, height: 460),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        let h = NSHostingView(rootView: LauncherView(model: model))
        h.frame = NSRect(x: 0, y: 0, width: 700, height: 460)
        w.contentView = h
        w.orderFrontRegardless()
        return (w, h)
    }

    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }

    /// 打ち足し・選択移動のあとの画面が、同じ状態から作り直した画面と一致すること（途中で描画が止まっていないこと）
    func testHostingViewRedrawsAfterQueryAndMove() {
        let model = makeModel()
        let (w1, live) = host(model)
        defer { w1.orderOut(nil) }
        spin()

        model.query = "c"
        spin()
        let afterC = render(live)

        model.query = "cla"
        spin()
        let afterCla = render(live)
        XCTAssertNotEqual(afterC, afterCla, "絞り込みが画面に出ていない")
        do {
            let (w2, fresh) = host(model)
            spin()
            XCTAssertEqual(afterCla, render(fresh), "打ち足し後の画面が作り直した画面と違う")
            w2.orderOut(nil)
        }

        model.move(1)
        spin()
        let afterMove = render(live)
        XCTAssertNotEqual(afterCla, afterMove, "選択の移動が画面に出ていない")
        do {
            let (w3, fresh) = host(model)
            spin()
            XCTAssertEqual(afterMove, render(fresh), "選択移動後の画面が作り直した画面と違う")
            w3.orderOut(nil)
        }
    }

    /// 組み込みコマンド「フィールド」は、開いている間「フィールドを閉じる」として出る
    func testFieldBuiltinTitleFollowsState() {
        let saved = Builtin.fieldIsOpen
        defer { Builtin.fieldIsOpen = saved }
        let model = makeModel()
        Builtin.fieldIsOpen = { false }
        model.query = "フィールド"
        XCTAssertEqual(model.items.first?.id, "builtin:field")
        XCTAssertEqual(model.items.first?.title, "フィールド")
        Builtin.fieldIsOpen = { true }
        model.query = "フィールドを閉じる"
        XCTAssertEqual(model.items.first?.id, "builtin:field")
        XCTAssertEqual(model.items.first?.title, "フィールドを閉じる")
    }
}
