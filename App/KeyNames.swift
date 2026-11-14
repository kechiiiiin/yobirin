import AppKit
import Carbon
import YobirinCore

enum KeyNames {
    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 93: "¥", 94: "_",
        102: "英数", 104: "かな", 117: "⌦", 115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
        65: "Num.", 67: "Num*", 69: "Num+", 75: "Num/", 76: "Num↩", 78: "Num-", 81: "Num=",
        82: "Num0", 83: "Num1", 84: "Num2", 85: "Num3", 86: "Num4", 87: "Num5", 88: "Num6",
        89: "Num7", 91: "Num8", 92: "Num9",
    ]

    static func describe(_ key: Hotkey) -> String {
        var s = ""
        if key.modifiers & Hotkey.control != 0 { s += "⌃" }
        if key.modifiers & Hotkey.option != 0 { s += "⌥" }
        if key.modifiers & Hotkey.shift != 0 { s += "⇧" }
        if key.modifiers & Hotkey.cmd != 0 { s += "⌘" }
        return s + (names[key.keyCode] ?? "キー\(key.keyCode)")
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= Hotkey.cmd }
        if flags.contains(.shift) { m |= Hotkey.shift }
        if flags.contains(.option) { m |= Hotkey.option }
        if flags.contains(.control) { m |= Hotkey.control }
        return m
    }
}
