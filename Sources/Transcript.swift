import Foundation

struct Transcript {
    private(set) var finalized: [String] = []
    private(set) var volatile = ""
    var text: String {
        (finalized + [volatile]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    mutating func receive(_ text: String, isFinal: Bool) {
        let segment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !segment.isEmpty { finalized.append(segment) }
            volatile = ""
        } else {
            volatile = segment
        }
    }
}
