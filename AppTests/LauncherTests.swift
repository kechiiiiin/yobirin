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
}
