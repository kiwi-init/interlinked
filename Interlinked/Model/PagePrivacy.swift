import Foundation

/// Browser-side classification of whether a page can send readable text to AI.
/// DOM field types are one input, not the definition of a public page.
enum PagePrivacy {
    static func isAuthenticated(
        url: String,
        sensitive: Bool,
        cookieNames: [String],
        hasLogoutControl: Bool,
        httpOnlyCookieNames: [String]
    ) -> Bool {
        if sensitive || hasLogoutControl { return true }
        if URL(string: url)?.user != nil || URL(string: url)?.password != nil { return true }
        if cookieNames.contains(where: isSessionCookie) { return true }
        if httpOnlyCookieNames.contains(where: isSessionCookie) { return true }
        if httpOnlyCookieNames.contains(where: { !isTrackerCookie($0) }) { return true }
        return false
    }

    static func isSessionCookie(_ name: String) -> Bool {
        let folded = normalize(name)
        if sessionCookieNames.contains(folded) { return true }
        if folded.contains("session") { return true }
        if folded.hasSuffix("_sid") || folded.hasSuffix(".sid") { return true }
        if folded.contains("auth") && !folded.contains("oauth_state") { return true }
        if folded.contains("logged") || folded.contains("signin") || folded.contains("sign_in") { return true }
        return false
    }

    static func isTrackerCookie(_ name: String) -> Bool {
        let folded = normalize(name)
        if folded.hasPrefix("_ga") || folded.hasPrefix("_gid") || folded.hasPrefix("_gat") { return true }
        if folded.hasPrefix("__utm") || folded.hasPrefix("_pk_") { return true }
        if trackerCookieNames.contains(folded) { return true }
        if folded.contains("consent") || folded.contains("optanon") { return true }
        return false
    }

    private static func normalize(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    private static let sessionCookieNames: Set<String> = [
        "sid", "ssid", "hsid", "asid", "osid",
        "sessionid", "session_id", "sessid", "sess",
        "auth", "auth_token", "authorization", "authenticated",
        "token", "access_token", "refresh_token", "id_token", "jwt",
        "login", "logged_in", "userid", "user_id", "uid",
        "remember_me", "rememberme", "stay_signed_in"
    ]

    private static let trackerCookieNames: Set<String> = [
        "_fbp", "_fbc", "_gcl_au", "_hjid", "_hjSessionUser", "_clck", "_clsk",
        "amp_token", "_derived_epik"
    ]
}
