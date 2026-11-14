import Foundation

/// 選んだ回数と最後に選んだ時刻
public struct UsageRecord: Codable, Equatable {
    public var count: Int
    public var lastUsed: Date
    public init(count: Int, lastUsed: Date) {
        self.count = count
        self.lastUsed = lastUsed
    }
}

/// 使用履歴（Application Support/yobirin/usage.json）
public final class UsageStore {
    public private(set) var records: [String: UsageRecord] = [:]
    private let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let url = fileURL, let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            records = (try? dec.decode([String: UsageRecord].self, from: data)) ?? [:]
        }
    }

    public func record(_ id: String, at now: Date = Date()) {
        var r = records[id] ?? UsageRecord(count: 0, lastUsed: now)
        r.count += 1
        r.lastUsed = now
        records[id] = r
        save()
    }

    public func save() {
        guard let url = fileURL else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(records) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// 並べる対象の最小限の情報
public struct RankCandidate {
    public var id: String
    public var texts: [String]
    public init(id: String, texts: [String]) {
        self.id = id
        self.texts = texts
    }
}

public enum Ranker {
    /// 選んだ回数と最近さによる加点（最大でおよそ 900。一致の段の差 1000 は越えない）
    public static func usageBoost(_ r: UsageRecord?, now: Date) -> Int {
        guard let r else { return 0 }
        let freq = min(Int(log2(Double(r.count) + 1) * 100), 500)
        let days = max(now.timeIntervalSince(r.lastUsed) / 86400, 0)
        // 半減期 7 日
        let recency = Int(400 * pow(0.5, days / 7))
        return freq + recency
    }

    /// 当たったものを点数順に並べる。返すのは元の配列のインデックス
    public static func rank(_ items: [RankCandidate], query: String, usage: [String: UsageRecord], now: Date = Date(), limit: Int = 60) -> [Int] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var scored: [(Int, Int)] = []
        for (i, item) in items.enumerated() {
            if trimmed.isEmpty {
                // 空欄のときは使ったことがあるものだけを使用履歴順に
                guard let r = usage[item.id] else { continue }
                scored.append((i, usageBoost(r, now: now)))
            } else if let s = FuzzyMatcher.bestScore(query: trimmed, candidates: item.texts) {
                scored.append((i, s + usageBoost(usage[item.id], now: now)))
            }
        }
        scored.sort { a, b in a.1 != b.1 ? a.1 > b.1 : a.0 < b.0 }
        return scored.prefix(limit).map { $0.0 }
    }
}
