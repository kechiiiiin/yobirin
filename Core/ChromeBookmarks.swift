import Foundation

public struct Bookmark: Equatable {
    public var title: String
    public var url: String
    /// 入っているフォルダ（例: "ブックマーク バー / 仕事"）
    public var folder: String

    public init(title: String, url: String, folder: String) {
        self.title = title
        self.url = url
        self.folder = folder
    }

    public var id: String { "bookmark:" + url }
}

/// Chrome の Bookmarks（JSON）から url ノードを全部取り出す
public enum ChromeBookmarksParser {
    public static func parse(data: Data) -> [Bookmark] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = obj["roots"] as? [String: Any] else { return [] }
        var result: [Bookmark] = []
        // 並び順を安定させる
        let order = ["bookmark_bar", "other", "synced"]
        let keys = order.filter { roots[$0] != nil } + roots.keys.filter { !order.contains($0) }.sorted()
        for key in keys {
            guard let node = roots[key] as? [String: Any] else { continue }
            walk(node, path: [], into: &result)
        }
        return result
    }

    private static func walk(_ node: [String: Any], path: [String], into result: inout [Bookmark]) {
        let type = node["type"] as? String
        let name = node["name"] as? String ?? ""
        if type == "url" {
            if let url = node["url"] as? String {
                result.append(Bookmark(title: name.isEmpty ? url : name, url: url, folder: path.joined(separator: " / ")))
            }
            return
        }
        if let children = node["children"] as? [[String: Any]] {
            let next = name.isEmpty ? path : path + [name]
            for child in children { walk(child, path: next, into: &result) }
        }
    }

    public static let defaultFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Bookmarks")
}
