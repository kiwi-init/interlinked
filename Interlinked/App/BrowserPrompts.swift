import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
enum BrowserPrompts {
    typealias AuthenticationResponse = (URLSession.AuthChallengeDisposition, URLCredential?)

    static func permissionOrigin(_ value: String) -> String? {
        guard let url = URL(string: value) else { return nil }
        return NavigationSafety.origin(url)
    }

    static func origin(_ securityOrigin: WKSecurityOrigin) -> String {
        var value = "\(securityOrigin.protocol)://\(securityOrigin.host)"
        if securityOrigin.port != 0 { value += ":\(securityOrigin.port)" }
        return value
    }

    static func origin(_ frame: WKFrameInfo) -> String {
        frame.request.url.flatMap(NavigationSafety.origin) ?? "This website"
    }

    static func showAlert(message: String, origin: String, window: NSWindow?) async {
        let alert = NSAlert()
        alert.messageText = origin
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = await run(alert, window: window)
    }

    static func showConfirm(message: String, origin: String, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = origin
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        return await run(alert, window: window) == .alertFirstButtonReturn
    }

    static func showPrompt(message: String, defaultText: String?, origin: String, window: NSWindow?) async -> String? {
        let alert = NSAlert()
        alert.messageText = origin
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        let field = NSTextField(string: defaultText ?? "")
        field.placeholderString = "Response"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        guard await run(alert, window: window) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Sign-in for HTTP Basic and Digest; WebKit checks server certificates.
    /// `presenting` receives the sign-in sheet, so the page can take it down
    /// when the load that asked for it goes away.
    static func authenticationResponse(
        for challenge: URLAuthenticationChallenge,
        window: NSWindow?,
        presenting: (NSAlert) -> Void = { _ in }
    ) async -> AuthenticationResponse {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodClientCertificate {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Client certificates aren't supported"
            alert.informativeText = "Interlinked cannot choose a client identity for \(challenge.protectionSpace.host). The connection was cancelled."
            alert.addButton(withTitle: "OK")
            _ = await run(alert, window: window)
            return (.cancelAuthenticationChallenge, nil)
        }
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
            return (.performDefaultHandling, nil)
        }
        guard challenge.previousFailureCount < 3 else { return (.cancelAuthenticationChallenge, nil) }

        let space = challenge.protectionSpace
        let alert = NSAlert()
        alert.messageText = "Sign in to \(space.host)"
        let realm = space.realm.map { "Realm: \($0)\n" } ?? ""
        alert.informativeText = "\(realm)Interlinked will use these credentials for this request only."
        alert.addButton(withTitle: "Sign In")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"

        let fields = NSStackView()
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        let username = NSTextField(string: challenge.proposedCredential?.user ?? "")
        username.placeholderString = "Username"
        let password = NSSecureTextField(string: "")
        password.placeholderString = "Password"
        fields.addArrangedSubview(username)
        fields.addArrangedSubview(password)
        alert.accessoryView = fields

        presenting(alert)
        guard await run(alert, window: window) == .alertFirstButtonReturn else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(user: username.stringValue, password: password.stringValue, persistence: .forSession))
    }

    /// The file picker for an upload field; `accept` is the field's accept attribute.
    static func chooseFiles(_ parameters: WKOpenPanelParameters, accepting accept: String?, window: NSWindow?) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let types = acceptedContentTypes(accept)
        if !types.isEmpty { panel.allowedContentTypes = types }
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        return response == .OK ? panel.urls : nil
    }

    static func acceptedContentTypes(_ accept: String?) -> [UTType] {
        guard let accept else { return [] }
        var types: [UTType] = []
        for raw in accept.split(separator: ",") {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let type: UTType?
            if value.hasPrefix(".") {
                type = UTType(filenameExtension: String(value.dropFirst()))
            } else if value.hasSuffix("/*") {
                switch value {
                case "audio/*": type = .audio
                case "image/*": type = .image
                case "video/*": type = .movie
                default: type = nil
                }
            } else if value.contains("/") {
                type = UTType(mimeType: value)
            } else {
                type = nil
            }
            if let type, !types.contains(type) { types.append(type) }
        }
        return types
    }

    static func requestPermission(
        origin: String,
        kind: WebsitePermissionKind,
        store: WebsitePermissionStore,
        window: NSWindow?
    ) async -> WebsitePermissionDecision {
        if let saved = store.decision(for: origin, kind: kind) { return saved }
        let alert = NSAlert()
        alert.messageText = "Allow \(kind.label.lowercased()) access?"
        alert.informativeText = "\(origin) is asking to use \(kind.label.lowercased()). You can revoke this decision in Settings."
        alert.addButton(withTitle: "Allow")
        let deny = alert.addButton(withTitle: "Don't Allow")
        deny.keyEquivalent = "\u{1b}"
        let decision: WebsitePermissionDecision = await run(alert, window: window) == .alertFirstButtonReturn
            ? .allow
            : .deny
        store.set(decision, for: origin, kind: kind)
        return decision
    }

    static func confirmNavigation(
        _ review: NavigationReview,
        store: NavigationExceptionStore,
        window: NSWindow?
    ) async -> Bool {
        let alert = NSAlert()
        let blocked = review.disposition == .block
        alert.alertStyle = .warning
        alert.messageText = blocked ? "Interlinked blocked this navigation" : "Check where this link is going"
        var details = ["Destination: \(review.destinationOrigin)"]
        if let source = review.sourceOrigin { details.append("From: \(source)") }
        details.append(contentsOf: review.reasons.map(\.rawValue))
        alert.informativeText = details.joined(separator: "\n\n")
        alert.addButton(withTitle: blocked ? "OK" : "Go Back")
        if !blocked { alert.addButton(withTitle: "Continue") }
        if !blocked, review.exceptionKey != nil {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Always allow this origin for these warnings"
        }
        guard !blocked else {
            _ = await run(alert, window: window)
            return false
        }
        let allowed = await run(alert, window: window) == .alertSecondButtonReturn
        if allowed, alert.suppressionButton?.state == .on { store.allow(review) }
        return allowed
    }

    static func showCertificateError(url: URL, error: String, window: NSWindow?) async {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Interlinked blocked an unsafe connection"
        alert.informativeText = "\(NavigationSafety.origin(url) ?? url.host ?? "This website") presented an invalid TLS certificate. \(error)"
        alert.addButton(withTitle: "OK")
        _ = await run(alert, window: window)
    }

    private static func run(_ alert: NSAlert, window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        }
        return alert.runModal()
    }
}
