import XCTest
@testable import YobirinCore

final class FieldRosterTests: XCTestCase {
    private func m(_ id: UInt32, _ app: String, _ f: CGRect = .zero, title: String = "", pid: Int32 = 1) -> FieldMember {
        FieldMember(windowID: id, pid: pid, appName: app, windowTitle: title, frame: f)
    }

    func testOrderTopLeftFirst() {
        // 左に縦長の Claude・右上にターミナル・右下に Kindle → 1 Claude、2 ターミナル、3 Kindle
        var r = FieldRoster()
        r.add(m(3, "Kindle", CGRect(x: 800, y: 520, width: 700, height: 480), pid: 3))
        r.add(m(2, "ターミナル", CGRect(x: 800, y: 40, width: 700, height: 460), pid: 2))
        r.add(m(1, "Claude", CGRect(x: 0, y: 30, width: 780, height: 970), pid: 1))
        XCTAssertEqual(r.members.map(\.windowID), [1, 2, 3])
        XCTAssertEqual(r.labels(), ["1 Claude", "2 ターミナル", "3 Kindle"])
        XCTAssertEqual(r.member(number: 2)?.appName, "ターミナル")
        XCTAssertNil(r.member(number: 0))
        XCTAssertNil(r.member(number: 4))
        XCTAssertEqual(r.number(of: 3), 3)
    }

    func testRowToleranceAndRows() {
        // 上端の差が 40 以内なら同じ行（左から）、超えたら次の行
        let a = m(1, "A", CGRect(x: 500, y: 100, width: 10, height: 10))
        let b = m(2, "B", CGRect(x: 0, y: 140, width: 10, height: 10))     // 差 40 → 同じ行
        let c = m(3, "C", CGRect(x: 0, y: 141.5, width: 10, height: 10))   // 差 41.5 → 次の行
        XCTAssertEqual(FieldRoster.ordered([a, b, c]).map(\.windowID), [2, 1, 3])
        // 同じ位置なら入れた順
        let d = m(4, "D", CGRect(x: 0, y: 0, width: 10, height: 10))
        let e = m(5, "E", CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(FieldRoster.ordered([e, d]).map(\.windowID), [5, 4])
    }

    func testRenumberWhenMovedAndRemoved() {
        var r = FieldRoster()
        r.add(m(1, "A", CGRect(x: 0, y: 0, width: 100, height: 100)))
        r.add(m(2, "B", CGRect(x: 200, y: 0, width: 100, height: 100)))
        r.add(m(3, "C", CGRect(x: 0, y: 300, width: 100, height: 100)))
        XCTAssertEqual(r.members.map(\.windowID), [1, 2, 3])
        // A を下へ動かすと付け直す
        XCTAssertTrue(r.updateFrames([1: CGRect(x: 300, y: 300, width: 100, height: 100)]))
        XCTAssertEqual(r.members.map(\.windowID), [2, 3, 1])
        XCTAssertFalse(r.updateFrames([1: CGRect(x: 301, y: 300, width: 100, height: 100)]))
        // 外したら詰める
        XCTAssertTrue(r.remove(windowID: 3))
        XCTAssertEqual(r.labels(), ["1 B", "2 A"])
        XCTAssertFalse(r.remove(windowID: 99))
    }

    func testAddIgnoresDuplicateAndRemovesClosed() {
        var r = FieldRoster()
        XCTAssertTrue(r.add(m(1, "A", pid: 10)))
        XCTAssertFalse(r.add(m(1, "A", pid: 10)))
        r.add(m(2, "B", CGRect(x: 10, y: 0, width: 1, height: 1), pid: 20))
        r.add(m(3, "B", CGRect(x: 20, y: 0, width: 1, height: 1), pid: 20))
        XCTAssertEqual(r.members.count, 3)
        XCTAssertTrue(r.remove(pid: 20))                  // アプリが終了
        XCTAssertEqual(r.members.map(\.windowID), [1])
        r.add(m(4, "C"))
        XCTAssertTrue(r.keepOnly(existing: [4]))          // 閉じられたウィンドウ
        XCTAssertEqual(r.members.map(\.windowID), [4])
        XCTAssertFalse(r.keepOnly(existing: [4, 5]))
    }

    func testLabelsAddTitleOnlyForSameApp() {
        var r = FieldRoster()
        r.add(m(1, "Chrome", CGRect(x: 0, y: 0, width: 1, height: 1), title: "とても長いページのタイトルがここに入りますよ"))
        r.add(m(2, "Chrome", CGRect(x: 100, y: 0, width: 1, height: 1), title: "メール"))
        r.add(m(3, "Kindle", CGRect(x: 200, y: 0, width: 1, height: 1), title: "本"))
        XCTAssertEqual(r.labels(titleLimit: 10), ["1 Chrome – とても長いページのタ…", "2 Chrome – メール", "3 Kindle"])
    }
}

final class FieldDropJudgeTests: XCTestCase {
    let field = CGRect(x: 100, y: 100, width: 800, height: 600)
    let before = CGRect(x: 1000, y: 100, width: 300, height: 200)

    func testDropInsideAddsMovedWindow() {
        let after = before.offsetBy(dx: -700, dy: 50)
        XCTAssertEqual(FieldDropJudge.decide(before: before, after: after, cursor: CGPoint(x: 400, y: 160), field: field, isMember: false), .add)
        // 既に入っていて中で動かしただけなら何もしない
        XCTAssertEqual(FieldDropJudge.decide(before: before, after: after, cursor: CGPoint(x: 400, y: 160), field: field, isMember: true), .none)
    }

    func testDropOutsideRemovesMember() {
        let after = before.offsetBy(dx: 50, dy: 0)
        XCTAssertEqual(FieldDropJudge.decide(before: before, after: after, cursor: CGPoint(x: 1100, y: 110), field: field, isMember: true), .remove)
        XCTAssertEqual(FieldDropJudge.decide(before: before, after: after, cursor: CGPoint(x: 1100, y: 110), field: field, isMember: false), .none)
    }

    func testClickOrResizeIsNotADrag() {
        // 動いていない（クリック・文字の選択）
        XCTAssertEqual(FieldDropJudge.decide(before: before, after: before, cursor: CGPoint(x: 400, y: 160), field: field, isMember: false), .none)
        // 左端を掴んだ大きさ変更（位置も変わるが大きさが変わる）
        let resized = CGRect(x: 850, y: 100, width: 450, height: 200)
        XCTAssertEqual(FieldDropJudge.decide(before: before, after: resized, cursor: CGPoint(x: 850, y: 150), field: field, isMember: false), .none)
        // 2pt 以内の揺れは動いていない扱い
        XCTAssertEqual(FieldDropJudge.decide(before: before, after: before.offsetBy(dx: 1, dy: 1), cursor: CGPoint(x: 400, y: 160), field: field, isMember: false), .none)
    }
}

final class FieldMiscTests: XCTestCase {
    func testDigitKeyCodes() {
        XCTAssertEqual(FieldKeys.digitKeyCodes.count, 9)
        XCTAssertEqual(FieldKeys.number(forKeyCode: 18), 1)
        XCTAssertEqual(FieldKeys.number(forKeyCode: 23), 5)
        XCTAssertEqual(FieldKeys.number(forKeyCode: 22), 6)
        XCTAssertEqual(FieldKeys.number(forKeyCode: 25), 9)
        XCTAssertNil(FieldKeys.number(forKeyCode: 29))   // 0 は使わない
    }

    func testRestoreFrame() {
        let main = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let screens = [main]
        // 保存が無ければ中央に 8 割
        XCTAssertEqual(FieldFrame.restore(saved: nil, screens: screens, main: main), CGRect(x: 100, y: 80, width: 800, height: 640))
        // 画面に収まっていれば前回のまま
        let s = CGRect(x: 50, y: 60, width: 400, height: 300)
        XCTAssertEqual(FieldFrame.restore(saved: FieldFrame(s), screens: screens, main: main), s)
        // ほとんど画面の外（外した画面にあった）なら既定へ
        let off = CGRect(x: 2000, y: 0, width: 400, height: 300)
        XCTAssertEqual(FieldFrame.restore(saved: FieldFrame(off), screens: screens, main: main), FieldFrame.defaultFrame(in: main))
        // 小さすぎるものも既定へ
        XCTAssertEqual(FieldFrame.restore(saved: FieldFrame(CGRect(x: 0, y: 0, width: 50, height: 50)), screens: screens, main: main),
                       FieldFrame.defaultFrame(in: main))
    }

    func testSaveAndLoadFrame() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yobirin-field-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(FieldFrame.load(from: url))
        let f = FieldFrame(CGRect(x: 10, y: 20, width: 640, height: 480))
        try f.save(to: url)
        XCTAssertEqual(FieldFrame.load(from: url), f)
    }
}
