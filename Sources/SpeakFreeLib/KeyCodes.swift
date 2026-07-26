import Foundation

public struct KeyCodes {
    public static let nameToCode: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
        "`": 50, "delete": 51, "escape": 53,
        "rightcmd": 54, "cmd": 55, "leftcmd": 55,
        "shift": 56, "leftshift": 56,
        "capslock": 57,
        "option": 58, "leftoption": 58, "alt": 58, "leftalt": 58,
        "ctrl": 59, "leftctrl": 59, "control": 59,
        "rightshift": 60,
        "rightoption": 61, "rightalt": 61,
        "rightctrl": 62, "rightcontrol": 62,
        "fn": 63, "globe": 63,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "f13": 105, "f14": 107, "f15": 113,
    ]

    public static let codeToName: [UInt16: String] = {
        var result: [UInt16: String] = [:]
        for (name, code) in nameToCode {
            if result[code] == nil {
                result[code] = name
            }
        }
        return result
    }()

    public static func parse(_ input: String) -> (keyCode: UInt16, modifiers: [String])? {
        let parts = input.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }

        guard let keyName = parts.last, let code = nameToCode[keyName] else {
            return nil
        }

        let modifiers = Array(parts.dropLast())
        return (code, modifiers)
    }

    /// The Globe / fn key. Named because it is special-cased in several places: it is the
    /// default hotkey, it is the only modifier with no left/right sides, and it is the only
    /// one macOS attaches its own action to (the emoji drawer).
    public static let fnKeyCode: UInt16 = 63

    /// Right Option — the recommended alternative when the fn key's own macOS action gets in
    /// the way. No system action is bound to it, so nothing has to be given up.
    public static let rightOptionKeyCode: UInt16 = 61

    /// Human-readable name for a hotkey, matching the labels in the Settings picker.
    ///
    /// `codeToName` is NOT usable for user-facing text: it is built by folding `nameToCode`,
    /// whose iteration order is undefined, so keycode 55 comes back as either "cmd" or
    /// "leftcmd" from run to run. This table is explicit and stable, and is the single
    /// source both the Help window and the Settings hotkey banner read from.
    public static func displayName(keyCode: UInt16) -> String {
        switch keyCode {
        case 63: return "the Globe / fn key"
        case 55: return "Left Command (\u{2318})"
        case 54: return "Right Command (\u{2318})"
        case 58: return "Left Option (\u{2325})"
        case 61: return "Right Option (\u{2325})"
        case 59: return "Left Control (\u{2303})"
        case 62: return "Right Control (\u{2303})"
        case 56: return "Left Shift (\u{21E7})"
        case 60: return "Right Shift (\u{21E7})"
        default:
            if let name = codeToName[keyCode] { return "the \(name) key" }
            return "key \(keyCode)"
        }
    }

    public static func describe(keyCode: UInt16, modifiers: [String]) -> String {
        let keyName = codeToName[keyCode] ?? "key(\(keyCode))"
        if modifiers.isEmpty {
            return keyName
        }
        return (modifiers + [keyName]).joined(separator: "+")
    }
}
