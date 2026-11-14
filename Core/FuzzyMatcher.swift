import Foundation

/// 文字の当たり具合を点数にする。先頭一致 > 単語頭一致 > 部分一致 > あいまい（飛び飛び）一致。
public enum FuzzyMatcher {
    public static let prefixScore = 4000
    public static let wordStartScore = 3000
    public static let substringScore = 2000
    public static let subsequenceScore = 1000

    /// 大小・全角半角・濁点・ひらがな/カタカナの違いを無視して比べるための正規化
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
        // カタカナ → ひらがな
        return folded.applyingTransform(.hiraganaToKatakana, reverse: true) ?? folded
    }

    /// 単語の頭の位置（正規化後の文字列での Character インデックス）
    static func wordStarts(original: String, normalized: [Character]) -> Set<Int> {
        var starts: Set<Int> = [0]
        let separators: Set<Character> = [" ", "-", "_", ".", "/", ":", "・", "　", "(", ")", "[", "]", "|", "｜"]
        for i in 1..<max(normalized.count, 1) where i < normalized.count {
            if separators.contains(normalized[i - 1]) && !separators.contains(normalized[i]) {
                starts.insert(i)
            }
        }
        // camelCase の境目（元の文字数と一致するときだけ）
        let orig = Array(original)
        if orig.count == normalized.count {
            for i in 1..<max(orig.count, 1) where i < orig.count {
                if orig[i].isUppercase && orig[i - 1].isLowercase { starts.insert(i) }
            }
        }
        return starts
    }

    /// 1つの候補文字列に対する点数。当たらなければ nil。
    public static func score(query: String, candidate: String) -> Int? {
        let q = Array(normalize(query).trimmingCharacters(in: .whitespaces))
        if q.isEmpty { return 0 }
        let c = Array(normalize(candidate))
        if c.isEmpty || q.count > c.count { return nil }
        let lengthPenalty = min(c.count - q.count, 200)

        if c.starts(with: q) {
            return prefixScore - lengthPenalty
        }
        // 部分一致の位置をすべて集める
        var positions: [Int] = []
        var i = 0
        while i + q.count <= c.count {
            if Array(c[i..<(i + q.count)]) == q { positions.append(i) }
            i += 1
        }
        if !positions.isEmpty {
            let starts = wordStarts(original: candidate, normalized: c)
            if let p = positions.first(where: { starts.contains($0) }) {
                return wordStartScore - lengthPenalty - min(p, 100)
            }
            return substringScore - lengthPenalty - min(positions[0], 100)
        }
        // 飛び飛びの一致（順番どおりに全部の文字が出てくる）
        var qi = 0
        var firstHit = -1
        var gaps = 0
        var last = -1
        for (ci, ch) in c.enumerated() where qi < q.count {
            if ch == q[qi] {
                if firstHit < 0 { firstHit = ci }
                if last >= 0 { gaps += ci - last - 1 }
                last = ci
                qi += 1
            }
        }
        if qi == q.count {
            return subsequenceScore - min(gaps * 10, 800) - min(lengthPenalty, 100)
        }
        return nil
    }

    /// 複数の候補文字列（表示名・ファイル名・URL など）のうち一番よい点数
    public static func bestScore(query: String, candidates: [String]) -> Int? {
        candidates.compactMap { score(query: query, candidate: $0) }.max()
    }
}
