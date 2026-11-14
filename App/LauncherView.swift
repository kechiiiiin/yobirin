import AppKit
import SwiftUI
import YobirinCore

/// 検索欄。↑↓・Enter・Tab・Esc を拾う。変換中（hasMarkedText）の Enter は決定に使わない
struct SearchField: NSViewRepresentable {
    @ObservedObject var model: LauncherModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 22)
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.delegate = context.coordinator
        f.placeholderString = model.placeholder
        model.field = f
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        f.placeholderString = model.placeholder
        let editor = f.currentEditor() as? NSTextView
        if f.stringValue != model.query && !(editor?.hasMarkedText() ?? false) {
            f.stringValue = model.query
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: LauncherModel
        init(model: LauncherModel) { self.model = model }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            model.query = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            // 日本語の変換中は IME に任せる
            if textView.hasMarkedText() { return false }
            switch sel {
            // ↑↓・⌃P/⌃N は AppDelegate のローカルモニタで処理する（ここでは二重に動かさない）
            case #selector(NSResponder.insertNewline(_:)): model.enter(); return true
            case #selector(NSResponder.insertTab(_:)): model.tab(); return true
            case #selector(NSResponder.cancelOperation(_:)): model.escape(); return true
            default: return false
            }
        }
    }
}

final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func image(_ icon: ItemIcon) -> NSImage? {
        switch icon {
        case .file(let path):
            if let i = cache[path] { return i }
            let i = NSWorkspace.shared.icon(forFile: path)
            cache[path] = i
            return i
        case .thumbnail(let url):
            if let i = cache[url.path] { return i }
            guard let i = NSImage(contentsOf: url) else { return nil }
            cache[url.path] = i
            return i
        default:
            return nil
        }
    }
}

struct IconView: View {
    let icon: ItemIcon
    var body: some View {
        Group {
            switch icon {
            case .emoji(let e):
                Text(e).font(.system(size: 20))
            case .symbol(let s):
                Image(systemName: s).font(.system(size: 17)).foregroundStyle(.secondary)
            case .file, .thumbnail:
                if let img = IconCache.shared.image(icon) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "questionmark.square").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 30, height: 30)
    }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let header = model.header {
                    Text(header)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "bell").font(.system(size: 18)).foregroundStyle(.secondary)
                }
                SearchField(model: model)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 700, height: 460)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .output:
            ScrollView {
                Text(model.running ? "実行中…" : model.output)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        case .argument(let s):
            VStack(alignment: .leading, spacing: 6) {
                Text(s.description ?? s.title).foregroundStyle(.secondary)
                Text("↩ で実行・⎋ で戻る").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
        default:
            if model.items.isEmpty {
                Text(model.query.isEmpty && model.mode == .all ? "打ち始めると、アプリ・ブックマーク・スクリプト・スニペットから探します" : "見つかりません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                                row(item, selected: idx == model.selected)
                                    .id(idx)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        model.selected = idx
                                        model.execute(item)
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selected) { _, new in
                        proxy.scrollTo(new)
                    }
                }
            }
        }
    }

    private func row(_ item: ResultItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            IconView(icon: item.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 14)).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(item.kind).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(selected ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Text(footerText).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
    }

    private var footerText: String {
        switch model.mode {
        case .argument: return "↩ 実行　⎋ 戻る"
        case .output: return "⎋ 戻る"
        default:
            if let item = model.selectedItem, case .script(let s) = item.action, s.argument1 != nil {
                return "↩ / ⇥ 引数を入れる　↑↓ 選ぶ　⎋ 閉じる"
            }
            return "↩ 実行　↑↓ 選ぶ　⎋ 閉じる"
        }
    }
}

/// キーを受けられる、アプリを前面にしないパネル
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
