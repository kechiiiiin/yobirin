import Foundation

public struct ScriptArgument: Codable, Equatable {
    public var type: String
    public var placeholder: String
    public var optional: Bool

    public init(type: String = "text", placeholder: String = "", optional: Bool = false) {
        self.type = type
        self.placeholder = placeholder
        self.optional = optional
    }

    enum CodingKeys: String, CodingKey { case type, placeholder, optional }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "text"
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
        optional = try c.decodeIfPresent(Bool.self, forKey: .optional) ?? false
    }
}

public enum ScriptMode: String {
    case fullOutput, compact, silent, inline
}

/// Raycast のスクリプトコマンド書式（`# @raycast.title` など）のヘッダを読んだもの
public struct ScriptCommand: Equatable {
    public var path: String
    public var title: String
    public var icon: String?
    public var mode: ScriptMode
    public var packageName: String?
    public var description: String?
    public var argument1: ScriptArgument?

    public var id: String { "script:" + path }
}

public enum RaycastScriptParser {
    /// ヘッダとして読むのは先頭のこの行数まで
    static let headerLineLimit = 60

    public static func parse(contents: String, path: String) -> ScriptCommand? {
        var fields: [String: String] = [:]
        for line in contents.components(separatedBy: .newlines).prefix(headerLineLimit) {
            let t = line.trimmingCharacters(in: .whitespaces)
            // `#`（シェル・Python・Ruby）と `//`（JS/Swift）のコメントを受ける
            var body: Substring
            if t.hasPrefix("#") { body = t.dropFirst() } else if t.hasPrefix("//") { body = t.dropFirst(2) } else { continue }
            body = body.drop(while: { $0 == " " || $0 == "\t" })
            guard body.hasPrefix("@raycast.") else { continue }
            let rest = body.dropFirst("@raycast.".count)
            guard let sp = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let key = String(rest[..<sp])
            let value = rest[sp...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }
        guard let title = fields["title"], !title.isEmpty else { return nil }
        var arg: ScriptArgument?
        if let raw = fields["argument1"], let data = raw.data(using: .utf8) {
            arg = try? JSONDecoder().decode(ScriptArgument.self, from: data)
        }
        return ScriptCommand(
            path: path,
            title: title,
            icon: fields["icon"].flatMap { $0.isEmpty ? nil : $0 },
            mode: ScriptMode(rawValue: fields["mode"] ?? "") ?? .fullOutput,
            packageName: fields["packageName"],
            description: fields["description"],
            argument1: arg
        )
    }

    /// フォルダ直下の実行可能なファイルを読む
    public static func scan(folder: URL) -> [ScriptCommand] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        var result: [ScriptCommand] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                  fm.isExecutableFile(atPath: url.path),
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let data = (try? handle.read(upToCount: 16 * 1024)) ?? Data()
            try? handle.close()
            guard let text = String(data: data, encoding: .utf8),
                  let cmd = parse(contents: text, path: url.path) else { continue }
            result.append(cmd)
        }
        return result
    }

    /// 出力の最終行（空行を除く）。HUD に出す
    public static func lastLine(of output: String) -> String {
        output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
    }
}
