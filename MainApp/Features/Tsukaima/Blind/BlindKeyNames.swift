import Foundation

/// HID 番号を日本語のキー名で読めるようにする表。入力文字は扱わず、キーの名前だけ。
enum BlindKeyNames {
    /// 表に無ければ nil。
    static func name(hid: Int) -> String? {
        switch hid {
        case 4...29: return String(UnicodeScalar(UInt8(65 + hid - 4)))  // A...Z
        case 30...38: return "\(hid - 29)"
        case 39: return "0"
        case 0x28: return "Enter"
        case 0x29: return "Esc"
        case 0x2A: return "Backspace"
        case 0x2B: return "Tab"
        case 0x2C: return "Space"
        case 0x35: return "半角/全角"
        case 0x39: return "CapsLock"
        case 0x3A...0x45: return "F\(hid - 0x39)"
        case 0x49: return "Insert"
        case 0x4B: return "PageUp"
        case 0x4C: return "Delete"
        case 0x4D: return "End"
        case 0x4E: return "PageDown"
        case 0x4F: return "→"
        case 0x50: return "←"
        case 0x51: return "↓"
        case 0x52: return "↑"
        case 0x53: return "NumLock"
        case 0x54: return "テンキー /"
        case 0x55: return "テンキー *"
        case 0x56: return "テンキー -"
        case 0x57: return "テンキー +"
        case 0x58: return "テンキー Enter"
        case 0x59...0x61: return "テンキー \(hid - 0x58)"
        case 0x62: return "テンキー 0"
        case 0x63: return "テンキー ."
        case 0x87: return "ろ (International1)"
        case 0x88: return "カタカナひらがな"
        case 0x89: return "¥ (International3)"
        case 0x8A: return "変換"
        case 0x8B: return "無変換"
        case 0x90: return "かな (LANG1)"
        case 0x91: return "英数 (LANG2)"
        case 0x92: return "LANG3"
        case 0x93: return "LANG4"
        case 0x94: return "LANG5"
        case 0xE0: return "左Ctrl"
        case 0xE1: return "左Shift"
        case 0xE2: return "左Alt/Option"
        case 0xE3: return "左Cmd"
        case 0xE4: return "右Ctrl"
        case 0xE5: return "右Shift"
        case 0xE6: return "右Alt/Option"
        case 0xE7: return "右Cmd"
        default: return nil
        }
    }

    /// 画面に出す名前。表の名前、無ければ呼び出し側の名前(String(describing:))、どちらも「hid 番号」を併記する。
    static func label(hid: Int, fallback: String? = nil) -> String {
        "\(name(hid: hid) ?? fallback ?? "キー")  hid \(hid)"
    }
}
