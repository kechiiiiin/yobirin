import Foundation

/// 検索欄に打った式を計算する。
/// 使えるもの: 数（3.14・1,000）・+ - * / ^（** も可）・括弧・後置の %（÷100）・
/// 関数 sqrt abs round floor ceil ln log（常用対数）sin cos tan（ラジアン）・定数 pi e。
/// 全角の数字・記号、×・÷・−も受け付ける。
public enum Calculator {
    public struct Result: Equatable {
        public let value: Double
        /// 一覧に出す形（3 桁ごとのカンマ付き）
        public let display: String
        /// コピーする形（カンマなし）
        public let plain: String
    }

    /// 計算結果を出すべき入力なら結果を返す。演算子も関数も無い入力（「123」「pi」「chrome」）や、
    /// 式として読めない・答えが有限でない（0 での割り算など）ときは nil
    public static func evaluate(_ input: String) -> Result? {
        let s = normalize(input)
        guard !s.isEmpty, let tokens = tokenize(s) else { return nil }
        var p = Parser(tokens: tokens)
        guard let v = p.parseExpression(), p.atEnd, p.sawOperation, v.isFinite else { return nil }
        return Result(value: v, display: format(v, grouping: true), plain: format(v, grouping: false))
    }

    static func normalize(_ input: String) -> String {
        var s = input.precomposedStringWithCompatibilityMapping   // 全角 → 半角
        let map: [Character: String] = ["×": "*", "÷": "/", "−": "-", "–": "-"]
        s = String(s.flatMap { map[$0] ?? String($0) })
        s = s.replacingOccurrences(of: "**", with: "^")
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func format(_ v: Double, grouping: Bool) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = grouping
        f.groupingSeparator = ","
        f.groupingSize = 3
        f.maximumFractionDigits = 10
        f.minimumFractionDigits = 0
        if abs(v) >= 1e15 || (v != 0 && abs(v) < 1e-10) {
            f.numberStyle = .scientific
            f.maximumFractionDigits = 10
        }
        let r = f.string(from: NSNumber(value: v)) ?? String(v)
        return r == "-0" ? "0" : r
    }

    // MARK: - 字句

    enum Token: Equatable {
        case number(Double)
        case ident(String)
        case op(Character)
        case lparen, rparen
    }

    static func tokenize(_ s: String) -> [Token]? {
        var tokens: [Token] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " { i += 1; continue }
            if c.isASCII && (c.isNumber || c == ".") {
                // 数。3 桁区切りのカンマは読み飛ばす（「1,000」）
                var text = ""
                while i < chars.count {
                    let d = chars[i]
                    if d.isASCII && (d.isNumber || d == ".") {
                        text.append(d)
                    } else if d == ",", i + 1 < chars.count, chars[i + 1].isASCII, chars[i + 1].isNumber {
                        // カンマは読み飛ばす
                    } else {
                        break
                    }
                    i += 1
                }
                guard let v = Double(text) else { return nil }
                tokens.append(.number(v))
                continue
            }
            if c.isASCII && c.isLetter {
                var text = ""
                while i < chars.count, chars[i].isASCII, chars[i].isLetter { text.append(chars[i]); i += 1 }
                tokens.append(.ident(text))
                continue
            }
            switch c {
            case "+", "-", "*", "/", "^", "%": tokens.append(.op(c))
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            default: return nil
            }
            i += 1
        }
        return tokens
    }

    // MARK: - 構文（再帰下降）

    static let functions: [String: (Double) -> Double] = [
        "sqrt": { $0.squareRoot() }, "abs": { Swift.abs($0) }, "round": { $0.rounded() },
        "floor": { $0.rounded(.down) }, "ceil": { $0.rounded(.up) },
        "ln": { Foundation.log($0) }, "log": { Foundation.log10($0) },
        "sin": { Foundation.sin($0) }, "cos": { Foundation.cos($0) }, "tan": { Foundation.tan($0) },
    ]
    static let constants: [String: Double] = ["pi": Double.pi, "e": M_E]

    struct Parser {
        let tokens: [Token]
        var pos = 0
        /// 二項演算子・% ・関数のどれかを使ったか（「123」だけでは結果を出さない）
        var sawOperation = false

        init(tokens: [Token]) { self.tokens = tokens }

        var atEnd: Bool { pos == tokens.count }
        var peek: Token? { pos < tokens.count ? tokens[pos] : nil }

        // expr = term (('+'|'-') term)*
        mutating func parseExpression() -> Double? {
            guard var v = parseTerm() else { return nil }
            while case .op(let o)? = peek, o == "+" || o == "-" {
                pos += 1
                guard let r = parseTerm() else { return nil }
                v = o == "+" ? v + r : v - r
                sawOperation = true
            }
            return v
        }

        // term = unary (('*'|'/') unary)*
        mutating func parseTerm() -> Double? {
            guard var v = parseUnary() else { return nil }
            while case .op(let o)? = peek, o == "*" || o == "/" {
                pos += 1
                guard let r = parseUnary() else { return nil }
                v = o == "*" ? v * r : v / r
                sawOperation = true
            }
            return v
        }

        // unary = ('-'|'+') unary | power   （-2^2 = -4）
        mutating func parseUnary() -> Double? {
            if case .op(let o)? = peek, o == "-" || o == "+" {
                pos += 1
                guard let v = parseUnary() else { return nil }
                return o == "-" ? -v : v
            }
            return parsePower()
        }

        // power = postfix ('^' unary)?   （右結合）
        mutating func parsePower() -> Double? {
            guard let base = parsePostfix() else { return nil }
            if case .op("^")? = peek {
                pos += 1
                guard let ex = parseUnary() else { return nil }
                sawOperation = true
                return Foundation.pow(base, ex)
            }
            return base
        }

        // postfix = primary '%'*
        mutating func parsePostfix() -> Double? {
            guard var v = parsePrimary() else { return nil }
            while case .op("%")? = peek {
                pos += 1
                v /= 100
                sawOperation = true
            }
            return v
        }

        // primary = number | '(' expr ')' | func '(' expr ')' | const
        mutating func parsePrimary() -> Double? {
            guard let t = peek else { return nil }
            switch t {
            case .number(let v):
                pos += 1
                return v
            case .lparen:
                pos += 1
                guard let v = parseExpression(), case .rparen? = peek else { return nil }
                pos += 1
                return v
            case .ident(let name):
                pos += 1
                if let f = Calculator.functions[name] {
                    guard case .lparen? = peek else { return nil }
                    pos += 1
                    guard let arg = parseExpression(), case .rparen? = peek else { return nil }
                    pos += 1
                    sawOperation = true
                    return f(arg)
                }
                return Calculator.constants[name]
            default:
                return nil
            }
        }
    }
}
