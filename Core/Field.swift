import CoreGraphics
import Foundation

// フィールド: 画面上に広げた枠に、選んだウィンドウだけを入れて ⌘1〜⌘9 で操作先を切り替える。
// ここには画面に依存しない判定・番号付け・保存だけを置く（座標はアクセシビリティ API の左上原点）。

/// フィールドに入れたウィンドウ 1 つ
public struct FieldMember: Equatable {
    /// CGWindowID（ウィンドウが閉じるまで変わらない）
    public let windowID: UInt32
    public let pid: Int32
    public let appName: String
    public var windowTitle: String
    /// いまの枠（左上原点）。番号の並びに使う
    public var frame: CGRect

    public init(windowID: UInt32, pid: Int32, appName: String, windowTitle: String, frame: CGRect = .zero) {
        self.windowID = windowID
        self.pid = pid
        self.appName = appName
        self.windowTitle = windowTitle
        self.frame = frame
    }
}

/// フィールドに入れたウィンドウの一覧。番号は 1 始まりで「左上から順」:
/// 各ウィンドウの左上の点で並べ、上端の y が rowTolerance 以内のものは同じ行として左から、行は上から。
/// 動いた・大きさが変わった・外れたら並べ直す（members は常に番号順）
public struct FieldRoster: Equatable {
    public static let maxNumber = 9
    public static let rowTolerance: CGFloat = 40

    public private(set) var members: [FieldMember] = []

    /// 左上から順に並べる（同じ位置なら元の並びを保つ）
    public static func ordered(_ ms: [FieldMember], rowTolerance: CGFloat = rowTolerance) -> [FieldMember] {
        let byY = ms.enumerated().sorted { a, b in
            a.element.frame.minY != b.element.frame.minY ? a.element.frame.minY < b.element.frame.minY : a.offset < b.offset
        }
        var rows: [[(offset: Int, element: FieldMember)]] = []
        for e in byY {
            if let top = rows.last?.first, e.element.frame.minY - top.element.frame.minY <= rowTolerance {
                rows[rows.count - 1].append(e)
            } else {
                rows.append([e])
            }
        }
        return rows.flatMap { row in
            row.sorted { a, b in
                a.element.frame.minX != b.element.frame.minX ? a.element.frame.minX < b.element.frame.minX : a.offset < b.offset
            }.map(\.element)
        }
    }

    private mutating func reorder() { members = Self.ordered(members) }

    /// 枠を更新して並べ直す。番号が変わったら true
    @discardableResult
    public mutating func updateFrames(_ frames: [UInt32: CGRect]) -> Bool {
        let before = members.map(\.windowID)
        for i in members.indices {
            if let f = frames[members[i].windowID] { members[i].frame = f }
        }
        reorder()
        return members.map(\.windowID) != before
    }

    public init() {}

    public var isEmpty: Bool { members.isEmpty }

    public func contains(_ windowID: UInt32) -> Bool {
        members.contains { $0.windowID == windowID }
    }

    /// 入れる。既に入っているものは入れない（番号も変えない）
    @discardableResult
    public mutating func add(_ m: FieldMember) -> Bool {
        guard !contains(m.windowID) else { return false }
        members.append(m)
        reorder()
        return true
    }

    @discardableResult
    public mutating func remove(windowID: UInt32) -> Bool {
        let before = members.count
        members.removeAll { $0.windowID == windowID }
        return members.count != before
    }

    /// 終了したアプリのウィンドウをまとめて外す
    @discardableResult
    public mutating func remove(pid: Int32) -> Bool {
        let before = members.count
        members.removeAll { $0.pid == pid }
        return members.count != before
    }

    /// まだ在るウィンドウだけ残す（閉じられたものを外す）
    @discardableResult
    public mutating func keepOnly(existing ids: Set<UInt32>) -> Bool {
        let before = members.count
        members.removeAll { !ids.contains($0.windowID) }
        return members.count != before
    }

    public mutating func removeAll() { members.removeAll() }

    /// 1 始まりの番号のウィンドウ。範囲外なら nil
    public func member(number: Int) -> FieldMember? {
        guard number >= 1, number <= members.count else { return nil }
        return members[number - 1]
    }

    public func number(of windowID: UInt32) -> Int? {
        members.firstIndex { $0.windowID == windowID }.map { $0 + 1 }
    }

    public mutating func updateTitle(windowID: UInt32, title: String) {
        guard let i = members.firstIndex(where: { $0.windowID == windowID }) else { return }
        members[i].windowTitle = title
    }

    /// 隅に出す一覧の文字（「1 Kindle」）。同じアプリが 2 つ以上あるときだけウィンドウ名を添える
    public func labels(titleLimit: Int = 24) -> [String] {
        var counts: [String: Int] = [:]
        for m in members { counts[m.appName, default: 0] += 1 }
        return members.enumerated().map { i, m in
            var s = "\(i + 1) \(m.appName)"
            let t = m.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if (counts[m.appName] ?? 0) > 1, !t.isEmpty {
                s += " – " + (t.count > titleLimit ? String(t.prefix(titleLimit)) + "…" : t)
            }
            return s
        }
    }
}

/// ウィンドウを離したときに、取り込む・外す・何もしない を決める
public enum FieldDropDecision: Equatable {
    case add, remove, none
}

public enum FieldDropJudge {
    /// - Parameters:
    ///   - before: 押したときのウィンドウの枠
    ///   - after: 離したときのウィンドウの枠
    ///   - cursor: 離したときのカーソル位置
    ///   - field: フィールドの枠
    ///   - isMember: そのウィンドウが既にフィールドに入っているか
    public static func decide(before: CGRect, after: CGRect, cursor: CGPoint, field: CGRect, isMember: Bool,
                              tolerance: CGFloat = 2) -> FieldDropDecision {
        // 位置が動いていて大きさが変わっていない＝ドラッグで動かした（端を掴んだ大きさ変更は除く）
        let moved = abs(before.minX - after.minX) > tolerance || abs(before.minY - after.minY) > tolerance
        let sameSize = abs(before.width - after.width) <= tolerance && abs(before.height - after.height) <= tolerance
        guard moved, sameSize else { return .none }
        let inside = field.contains(cursor)
        if inside && !isMember { return .add }
        if !inside && isMember { return .remove }
        return .none
    }
}

/// ⌘1〜⌘9 のキーコード（kVK_ANSI_1〜9。並びが番号順でないので表で持つ）
public enum FieldKeys {
    public static let digitKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    public static func number(forKeyCode code: UInt32) -> Int? {
        digitKeyCodes.firstIndex(of: code).map { $0 + 1 }
    }
}

/// フィールドの位置・大きさ（Cocoa の左下原点のまま保存する）
public struct FieldFrame: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ r: CGRect) {
        x = Double(r.minX); y = Double(r.minY); width = Double(r.width); height = Double(r.height)
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public static let minimumSize = CGSize(width: 240, height: 160)

    /// 前回の枠をそのまま使えるか確かめ、使えなければ画面の中央に既定の大きさで置く。
    /// どの画面とも十分に重ならない（画面の構成が変わった）ときは既定に戻す
    public static func restore(saved: FieldFrame?, screens: [CGRect], main: CGRect) -> CGRect {
        if let s = saved?.rect, s.width >= minimumSize.width, s.height >= minimumSize.height {
            let visible = screens.map { $0.intersection(s) }.filter { !$0.isNull }.map { $0.width * $0.height }.max() ?? 0
            if visible >= s.width * s.height * 0.5 { return s }
        }
        return defaultFrame(in: main)
    }

    public static func defaultFrame(in visible: CGRect) -> CGRect {
        let w = (visible.width * 0.8).rounded()
        let h = (visible.height * 0.8).rounded()
        return CGRect(x: (visible.midX - w / 2).rounded(), y: (visible.midY - h / 2).rounded(), width: w, height: h)
    }

    public static func load(from url: URL) -> FieldFrame? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FieldFrame.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// CGWindowListCopyWindowInfo の 1 件（座標は左上原点）。AX から窓が引けないアプリ（iPad 版の Kindle など）も
/// ここからなら見えるので、取り込み・番号付けはこれを土台にする
public struct FieldWindowInfo: Equatable {
    public let windowID: UInt32
    public let pid: Int32
    public let layer: Int
    public let bounds: CGRect
    public let name: String

    public init(windowID: UInt32, pid: Int32, layer: Int = 0, bounds: CGRect, name: String = "") {
        self.windowID = windowID
        self.pid = pid
        self.layer = layer
        self.bounds = bounds
        self.name = name
    }

    /// CGWindowListCopyWindowInfo の辞書から作る。足りない項目があれば nil
    public init?(_ d: [String: Any]) {
        guard let id = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let b = d[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b) else { return nil }
        self.init(windowID: id, pid: pid, layer: (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                  bounds: r, name: d[kCGWindowName as String] as? String ?? "")
    }
}

public enum FieldWindowPicker {
    /// これより小さい窓は、同じアプリの大きな窓に重ねた飾り（Kindle の信号ボタン部分の 66×20 など）とみなす
    public static let minimumSize = CGSize(width: 120, height: 80)

    /// カーソルの下で掴んだウィンドウを選ぶ。windows は手前から奥の順（CGWindowList の並び）。
    /// - 手前で最初に当たったものが layer 0 でなければ（メニューバー・Dock など）掴んでいない
    /// - 自分のウィンドウなら掴んでいない
    /// - 当たったものが小さな重ね窓で、同じアプリの大きな窓がその点を含むなら、そちらを掴んだとみなす
    public static func pick(at point: CGPoint, in windows: [FieldWindowInfo], excludingPID me: Int32) -> FieldWindowInfo? {
        guard let hit = windows.first(where: { $0.bounds.contains(point) }), hit.layer == 0, hit.pid != me else { return nil }
        guard isSmall(hit.bounds) else { return hit }
        return windows.first { w in
            w.pid == hit.pid && w.layer == 0 && !isSmall(w.bounds) && w.bounds.contains(point)
        } ?? hit
    }

    static func isSmall(_ r: CGRect) -> Bool {
        r.width < minimumSize.width || r.height < minimumSize.height
    }
}

/// CGWindowID からアクセシビリティの窓を選ぶ。
/// 候補は kAXWindows に加え AXFocusedWindow・AXMainWindow・AXChildren から集めたもの
/// （iPad 版アプリは kAXWindows が空でも、こちらからは窓が引ける）
public enum AXWindowMatch {
    public struct Candidate: Equatable {
        /// _AXUIElementGetWindow で引けた ID（引けなければ nil）
        public let windowID: UInt32?
        public let frame: CGRect?
        public init(windowID: UInt32?, frame: CGRect?) {
            self.windowID = windowID
            self.frame = frame
        }
    }

    /// ID が一致するものを優先し、無ければ枠が一致するもの（ID を引けないアプリ向け）。どれも違えば nil
    public static func select(_ candidates: [Candidate], windowID: UInt32, frame: CGRect, tolerance: CGFloat = 2) -> Int? {
        if let i = candidates.firstIndex(where: { $0.windowID == windowID }) { return i }
        return candidates.firstIndex { c in
            c.frame.map { WindowCycler.approximatelyEqual($0, frame, tolerance: tolerance) } ?? false
        }
    }
}
