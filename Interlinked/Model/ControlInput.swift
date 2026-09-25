import AppKit

/// A key press named on the control channel, like `escape`, `f cmd`,
/// `cmd+shift+g`, or a raw key code such as `53`, turned into what an
/// NSEvent needs. Key codes are the US ANSI layout's.
struct ControlKey: Equatable {
    var keyCode: UInt16
    var characters: String
    var charactersIgnoringModifiers: String
    var modifiers: NSEvent.ModifierFlags

    static func parse(_ words: [String]) -> ControlKey? {
        let tokens = words.flatMap { $0.split(separator: "+").map { $0.lowercased() } }
        var modifiers: NSEvent.ModifierFlags = []
        var keys: [String] = []
        for token in tokens {
            if let flag = modifier(token) { modifiers.insert(flag) } else { keys.append(token) }
        }
        guard keys.count == 1, let (code, base) = key(keys[0]) else { return nil }
        // Shift changes what a letter types; the app compares lowercased.
        let typed = modifiers.contains(.shift) && base.count == 1 && base.first!.isLetter ? base.uppercased() : base
        return ControlKey(keyCode: code, characters: typed, charactersIgnoringModifiers: typed, modifiers: modifiers)
    }

    static func modifier(_ token: String) -> NSEvent.ModifierFlags? {
        switch token {
        case "cmd", "command", "⌘": .command
        case "shift", "⇧": .shift
        case "opt", "option", "alt", "⌥": .option
        case "ctrl", "control", "⌃": .control
        case "fn", "function": .function
        default: nil
        }
    }

    /// A single digit is the digit key; longer numbers are key codes.
    private static func key(_ token: String) -> (UInt16, String)? {
        if token.count > 1, let code = UInt16(token) {
            return (code, names.values.first { $0.0 == code }?.1 ?? "")
        }
        return names[token]
    }

    /// Names and single characters, each with its key code and the character
    /// the key types without modifiers.
    static let names: [String: (UInt16, String)] = {
        var table: [String: (UInt16, String)] = [:]
        let printable: [(UInt16, String)] = [
            (0, "a"), (1, "s"), (2, "d"), (3, "f"), (4, "h"), (5, "g"), (6, "z"), (7, "x"), (8, "c"), (9, "v"),
            (11, "b"), (12, "q"), (13, "w"), (14, "e"), (15, "r"), (16, "y"), (17, "t"), (18, "1"), (19, "2"),
            (20, "3"), (21, "4"), (22, "6"), (23, "5"), (24, "="), (25, "9"), (26, "7"), (27, "-"), (28, "8"),
            (29, "0"), (30, "]"), (31, "o"), (32, "u"), (33, "["), (34, "i"), (35, "p"), (37, "l"), (38, "j"),
            (39, "'"), (40, "k"), (41, ";"), (42, "\\"), (43, ","), (44, "/"), (45, "n"), (46, "m"), (47, "."),
            (50, "`"),
        ]
        for (code, character) in printable { table[character] = (code, character) }
        // Words for the punctuation shells make awkward.
        let spelled = [
            "comma": ",", "period": ".", "slash": "/", "backslash": "\\", "minus": "-", "equals": "=",
            "semicolon": ";", "quote": "'", "grave": "`", "left-bracket": "[", "right-bracket": "]",
        ]
        for (name, character) in spelled { table[name] = table[character] }
        let named: [(String, UInt16, Int)] = [
            ("return", 36, 0x0D), ("enter", 36, 0x0D), ("tab", 48, 0x09), ("space", 49, 0x20),
            ("delete", 51, 0x7F), ("backspace", 51, 0x7F), ("escape", 53, 0x1B), ("esc", 53, 0x1B),
            ("forward-delete", 117, 0xF728), ("home", 115, 0xF729), ("end", 119, 0xF72B),
            ("page-up", 116, 0xF72C), ("page-down", 121, 0xF72D),
            ("left", 123, 0xF702), ("right", 124, 0xF703), ("down", 125, 0xF701), ("up", 126, 0xF700),
        ]
        for (name, code, scalar) in named { table[name] = (code, String(Character(UnicodeScalar(scalar)!))) }
        return table
    }()
}

/// A Settings value by the name the control channel uses for it.
enum ControlSetting: String, CaseIterable {
    case siteMenu = "site-menu"
    case usefulAddress = "useful-info.address"
    case usefulContact = "useful-info.contact"
    case blocking
    case darkPages = "dark-pages"
    case jev
    case appleIntelligence = "apple-intelligence"
    case refineLabels = "refine-labels"
    case criticalReading = "critical-reading"
    case sharingScreenMode = "sharing-screen-mode"
    case browsingHistory = "browsing-history"
    case onboardingAlwaysShow = "onboarding.always-show"
    case searchProvider = "search-provider"
    case remoteSuggestions = "remote-suggestions"
    case suggestionProvider = "suggestion-provider"

    /// The suggestion provider choice that follows the search provider.
    static let sameAsSearch = "same"

    enum Value: Equatable {
        case bool(Bool)
        case choice(String)
    }

    /// What `set` accepts. Switches take on or off.
    var choices: [String] {
        switch self {
        case .darkPages: PageDarkMode.allCases.map(\.rawValue)
        case .criticalReading: CriticalReadingMode.allCases.map(\.rawValue)
        case .searchProvider: SearchProvider.allCases.map(\.rawValue)
        case .suggestionProvider: [Self.sameAsSearch] + SearchProvider.allCases.map(\.rawValue)
        default: ["on", "off"]
        }
    }

    func parse(_ raw: String) -> Value? {
        let written = Self.folded(raw)
        switch self {
        case .darkPages, .criticalReading, .searchProvider, .suggestionProvider:
            return choices.first { Self.folded($0) == written }.map(Value.choice)
        default:
            switch written {
            case "on", "true", "yes", "1": return .bool(true)
            case "off", "false", "no", "0": return .bool(false)
            default: return nil
            }
        }
    }

    /// `on-request`, `on_request`, and `onRequest` name the same choice.
    private static func folded(_ text: String) -> String {
        text.lowercased().filter { $0 != "-" && $0 != "_" }
    }
}
