import Foundation

enum Intent {
    /// The control request for a sentence, if it names one.
    static func command(_ said: String) -> String? {
        let words = Self.words(said)
        func hasAny(_ choices: [String]) -> Bool { choices.contains { words.contains($0) } }
        guard !hasAny(["terminal", "shell", "console", "split", "divide", "pane", "panes", "panel", "file", "files", "agent", "swap"]) else { return nil }
        let page = hasAny(["tab", "tabs", "page", "pages"])
        if page && hasAny(["new", "open", "another", "add"]) { return "new-tab" }
        if page && hasAny(["next", "forward"]) { return "next-tab" }
        if page && hasAny(["previous", "prev", "back", "last"]) { return "prev-tab" }
        if hasAny(["close"]) && words.compactMap(number).isEmpty { return "close-tab" }
        if hasAny(["clear", "erase"]) { return "clear" }
        if page {
            for pair in zip(words, words.dropFirst()) where ["tab", "page"].contains(pair.0) {
                if let index = number(pair.1), index > 0 { return "focus-tab \(index - 1)" }
            }
        }
        return nil
    }

    static func words(_ said: String) -> [String] {
        said.lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    static func number(_ word: String) -> UInt64? {
        if let value = UInt64(word) { return value }
        switch word {
        case "one", "won": return 1
        case "two", "to", "too": return 2
        case "three": return 3
        case "four", "for": return 4
        case "five": return 5
        case "six": return 6
        case "seven": return 7
        case "eight": return 8
        case "nine": return 9
        default: return nil
        }
    }
}
