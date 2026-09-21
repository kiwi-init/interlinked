import AppKit

@MainActor
enum BrowserPrompts {
    static func permissionOrigin(_ value: String) -> String? {
        guard let url = URL(string: value) else { return nil }
        return NavigationSafety.origin(url)
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
        advice: String?,
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
        if let advice, !advice.isEmpty { details.append(advice) }
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
