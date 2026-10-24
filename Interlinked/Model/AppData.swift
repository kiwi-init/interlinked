import Foundation

/// The folder Interlinked keeps its files in: the session, history, favicons,
/// downloads, caches, and the control socket.
///
/// The app you use, `computer.interlinked`, keeps them in
/// ~/Library/Application Support/Interlinked. A build with another bundle ID,
/// such as a test or isolated copy, gets a folder of its own beside it
/// (`Interlinked.isolated` for `computer.interlinked.isolated`), so it never
/// reads or writes your session or history. A copy launched with a home of its
/// own (`CFFIXED_USER_HOME`, as `script/run-isolated` and the UI tests do)
/// already has its own Application Support, and keeps the usual name there.
enum AppData {
    static let bundleID = "computer.interlinked"

    static let directory = directory(
        bundleID: Bundle.main.bundleIdentifier,
        environment: ProcessInfo.processInfo.environment,
        support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    )

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func directory(bundleID: String?, environment: [String: String], support: URL) -> URL {
        let name: String
        if bundleID == Self.bundleID || environment["CFFIXED_USER_HOME"]?.isEmpty == false {
            name = "Interlinked"
        } else if let bundleID, bundleID.hasPrefix(Self.bundleID + ".") {
            // Short, so the control socket inside stays under the 104-byte limit.
            name = "Interlinked" + bundleID.dropFirst(Self.bundleID.count)
        } else {
            name = "Interlinked (\(bundleID ?? "unknown"))"
        }
        return support.appendingPathComponent(name, isDirectory: true)
    }
}
