import Foundation

struct Spacing {
    // AX selected ranges use UTF-16 offsets, not Swift Character offsets.
    static func prefix(value: String?, caretUTF16: Int?) -> String {
        guard let value, let caret = caretUTF16, caret > 0,
              caret <= value.utf16.count else { return "" }
        let before = (value as NSString).substring(to: caret)
        guard let character = before.last,
              !character.isWhitespace,
              !"([{〈《「『【〔〖〘〚（［｛".contains(character) else { return "" }
        return " "
    }
}
