import CoreGraphics

public enum WindowDirection: String, Codable {
    case left, right, maximize
}

/// 左・右・最大化の枠を計算し、同じ方向が続いたら 1/2 → 2/3 → 1/3 と回す。
/// 座標系は呼ぶ側に任せる（アクセシビリティ API の左上原点で使う）。
public final class WindowCycler {
    public static let fractions: [CGFloat] = [1.0 / 2.0, 2.0 / 3.0, 1.0 / 3.0]

    private var lastDirection: WindowDirection?
    private var lastFrame: CGRect?
    private var step = 0

    public init() {}

    public static func frame(direction: WindowDirection, fraction: CGFloat, in visible: CGRect) -> CGRect {
        switch direction {
        case .maximize:
            return visible
        case .left:
            let w = (visible.width * fraction).rounded()
            return CGRect(x: visible.minX, y: visible.minY, width: w, height: visible.height)
        case .right:
            let w = (visible.width * fraction).rounded()
            return CGRect(x: visible.maxX - w, y: visible.minY, width: w, height: visible.height)
        }
    }

    /// 次に合わせる枠。current はいまのウィンドウの枠（ユーザーが動かしたかの判定に使う）
    public func next(direction: WindowDirection, current: CGRect, visible: CGRect) -> CGRect {
        if direction == lastDirection, let lf = lastFrame, Self.approximatelyEqual(lf, current) {
            step = (step + 1) % Self.fractions.count
        } else {
            step = 0
        }
        let f = Self.frame(direction: direction, fraction: Self.fractions[step], in: visible)
        lastDirection = direction
        lastFrame = f
        return f
    }

    /// 実際にウィンドウが収まった枠を覚え直す（最小サイズのあるアプリなど）
    public func noteActualFrame(_ frame: CGRect) {
        lastFrame = frame
    }

    public func reset() {
        lastDirection = nil
        lastFrame = nil
        step = 0
    }

    public static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 8) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Cocoa（左下原点）の枠をアクセシビリティ（左上原点・主画面基準）の枠に変換する
    public static func cocoaToAX(_ r: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryScreenHeight - r.maxY, width: r.width, height: r.height)
    }
}
