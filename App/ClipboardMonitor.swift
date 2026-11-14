import AppKit
import YobirinCore

/// 0.5 秒ごとに changeCount を見て、文字と画像を履歴に入れる
final class ClipboardMonitor {
    let store: ClipboardStore
    private var lastCount: Int
    private var timer: Timer?
    private var pruneTimer: Timer?

    init(store: ClipboardStore) {
        self.store = store
        lastCount = NSPasteboard.general.changeCount
    }

    func start() {
        store.prune()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.store.prune() }
    }

    private func poll() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastCount else { return }
        lastCount = count
        if Paster.ignoreChangeCounts.remove(count) != nil { return }
        let types = (pb.types ?? []).map { $0.rawValue }
        if ClipboardFilter.shouldSkip(types: types) { return }

        if let s = pb.string(forType: .string), !s.isEmpty {
            store.addText(s)
        } else if let png = pb.data(forType: .png) {
            store.addImage(png, type: "png")
        } else if let tiff = pb.data(forType: .tiff) {
            // TIFF は大きいので PNG にして残す（変換できなければ TIFF のまま）
            if let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                store.addImage(png, type: "png")
            } else {
                store.addImage(tiff, type: "tiff")
            }
        }
    }
}
