import Foundation

/// 絵文字 1 つ分。名前は macOS の CoreEmoji が持つ日本語名・英語名（AppleName.strings）
public struct EmojiEntry: Equatable {
    public var emoji: String
    public var nameJa: String
    public var nameEn: String
    /// 日本語名の読み（ひらがな）。漢字の名前を「ねこ」などで当てるため
    public var reading: String

    public init(emoji: String, nameJa: String, nameEn: String, reading: String = "") {
        self.emoji = emoji
        self.nameJa = nameJa
        self.nameEn = nameEn
        self.reading = reading
    }

    public var id: String { "emoji:" + emoji }
    public var searchTexts: [String] { [nameJa, reading, nameEn].filter { !$0.isEmpty } }
}

public enum EmojiData {
    /// 絵文字ピッカーと同じ名前の置き場所（macOS 26.7.1 で確認。非公開フレームワークなので、無ければ空にする）
    public static let defaultResources = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/CoreEmoji.framework/Versions/A/Resources")

    /// Unicode の推奨の並び（EmojiOrder.swift。顔 → 人・手 → 動物・自然 → 食べ物 → 旅行 → 活動 → 物 → 記号 → 旗）
    public static var defaultOrder: [String] { EmojiOrder.list.split(separator: "\n").map(String.init) }

    /// ja.lproj と en.lproj の AppleName.strings を読む。並びは order の順。order に無いもの（新しい絵文字など）は後ろに文字コード順
    public static func load(resources: URL = defaultResources, order: [String] = defaultOrder) -> [EmojiEntry] {
        let ja = strings(resources.appendingPathComponent("ja.lproj/AppleName.strings"))
        let en = strings(resources.appendingPathComponent("en.lproj/AppleName.strings"))
        // 「🇭🇰@CH-SKU」のような地域向けの別名は絵文字そのものではないので除く
        let keys = Set(ja.keys).union(en.keys).filter { !$0.contains("@") }
        var rank: [String: Int] = [:]
        for (i, e) in order.enumerated() where rank[orderKey(e)] == nil { rank[orderKey(e)] = i }
        let sorted = keys.sorted { a, b in
            switch (rank[orderKey(a)], rank[orderKey(b)]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return codeOrder(a, b)
            }
        }
        return sorted.map { e in
            let nameJa = ja[e] ?? ""
            return EmojiEntry(emoji: e, nameJa: nameJa, nameEn: en[e] ?? "", reading: reading(of: nameJa))
        }
    }

    static func strings(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: String] else { return [:] }
        return dict
    }

    /// 異体字セレクタ（U+FE0F）の有無で ⚜️ と ⚜ が別物にならないよう、外して比べる
    static func orderKey(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value != 0xFE0F }))
    }

    /// 文字コード順。ただし #️⃣ 0️⃣ ©️ など基本の文字から始まるものは後ろに回し、空欄のときに顔の絵文字から並ぶようにする
    static func codeOrder(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> [UInt32] {
            let v = s.unicodeScalars.map(\.value)
            guard let first = v.first, first < 0x2000 else { return v }
            return [first + 0x110000] + v.dropFirst()
        }
        return key(a).lexicographicallyPrecedes(key(b))
    }

    /// 日本語の文をひらがなの読みにする（漢字を含まなければ空。CFStringTokenizer のローマ字表記 → ひらがな）
    public static func reading(of text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return "" }
        let cf = text as CFString
        let tokenizer = CFStringTokenizerCreate(nil, cf, CFRange(location: 0, length: CFStringGetLength(cf)),
                                                kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale)
        var out = ""
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let original = (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
               let kana = latin.applyingTransform(.latinToHiragana, reverse: false) {
                out += kana
            } else {
                out += original
            }
        }
        return out
    }
}
