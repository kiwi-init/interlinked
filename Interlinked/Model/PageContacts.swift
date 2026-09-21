import Foundation

enum UsefulInfoPreference {
    static let addressKey = "usefulInfo.address"
    static let contactKey = "usefulInfo.contact"

    static func address(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: addressKey) as? Bool ?? true
    }

    static func contact(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: contactKey) as? Bool ?? true
    }
}

/// What the page itself says, before any detection: structured data, contact
/// links, and the text of its contact and footer regions.
struct PageContactSignals: Decodable, Equatable, Sendable {
    /// schema.org PostalAddress values. Trusted as addresses without detection.
    var structuredAddresses: [String] = []
    /// `<address>` elements. Often an address, sometimes only a name or email.
    var addressElements: [String] = []
    var phones: [String] = []
    var emails: [String] = []
    /// Footer and contact regions, for on-device detection.
    var text: String = ""
}

struct ContactOption: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case phone, email }
    var kind: Kind
    var value: String
    var id: String { value }
}

struct PageContacts: Equatable, Sendable {
    var address: String?
    var phones: [String] = []
    var emails: [String] = []

    var options: [ContactOption] {
        phones.map { ContactOption(kind: .phone, value: $0) } + emails.map { ContactOption(kind: .email, value: $0) }
    }
    var isEmpty: Bool { address == nil && phones.isEmpty && emails.isEmpty }
}

/// Finds a page's own address and contact details on this Mac. Structured
/// data and contact links come first; Apple's data detectors then read the
/// page's contact and footer text for anything the markup didn't declare.
enum PageContactDetector {
    static let maximumOptions = 3
    private static let maximumAddressLength = 180

    static func contacts(from signals: PageContactSignals) -> PageContacts {
        let detected = detect(in: signals.text)
        let elementAddresses = signals.addressElements.flatMap { detect(in: $0).addresses }
        let address = (signals.structuredAddresses.map(clean) + elementAddresses + detected.addresses)
            .first { !$0.isEmpty && $0.count <= maximumAddressLength }
        return PageContacts(
            address: address,
            phones: unique(signals.phones + detected.phones, key: phoneKey, valid: validPhone),
            emails: unique(signals.emails + detected.emails, key: { $0.lowercased() }, valid: validEmail)
        )
    }

    private static func detect(in text: String) -> (addresses: [String], phones: [String], emails: [String]) {
        guard !text.isEmpty else { return ([], [], []) }
        let types: NSTextCheckingResult.CheckingType = [.address, .phoneNumber, .link]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return ([], [], []) }
        var addresses: [String] = [], phones: [String] = [], emails: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let span = Range(match.range, in: text) else { continue }
            switch match.resultType {
            case .address: addresses.append(clean(String(text[span])))
            case .phoneNumber: phones.append(match.phoneNumber ?? String(text[span]))
            case .link:
                if let url = match.url, url.scheme?.lowercased() == "mailto" {
                    emails.append(String(url.absoluteString.dropFirst("mailto:".count)))
                }
            default: break
            }
        }
        return (addresses, phones, emails)
    }

    /// One line, the way it will be pasted.
    static func clean(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(,\s*)+"#, with: ", ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
    }

    private static func phoneKey(_ value: String) -> String {
        String(value.filter(\.isNumber).suffix(9))
    }

    private static func validPhone(_ value: String) -> Bool {
        (7...15).contains(value.filter(\.isNumber).count)
    }

    private static func validEmail(_ value: String) -> Bool {
        value.range(of: #"^[A-Z0-9._%+-]+@[A-Z0-9-]+(\.[A-Z0-9-]+)*\.[A-Z]{2,}$"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func unique(_ values: [String], key: (String) -> String, valid: (String) -> Bool) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for value in values.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where valid(value) {
            if seen.insert(key(value)).inserted { result.append(value) }
            if result.count == maximumOptions { break }
        }
        return result
    }
}
