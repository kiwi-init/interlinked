import Foundation

enum DownloadState: String, Codable {
    case choosingDestination
    case downloading
    case completed
    case cancelled
    case failed
    case interrupted

    var isActive: Bool { self == .choosingDestination || self == .downloading }
}

struct DownloadRecord: Identifiable, Codable, Equatable {
    var id: UUID
    var filename: String
    var origin: String
    var destination: URL?
    var state: DownloadState
    var fractionCompleted: Double?
    var receivedBytes: Int64
    var expectedBytes: Int64?
    var message: String?
    var resumeData: Data?
    var startedAt: Date
    var finishedAt: Date?

    var canReveal: Bool { state == .completed && destination != nil }
    var canResume: Bool { !state.isActive && state != .completed && resumeData != nil }
}

enum DownloadNaming {
    static func availableURL(
        directory: URL,
        suggestedFilename: String,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL {
        let proposed = directory.appendingPathComponent(sanitized(suggestedFilename))
        guard fileExists(proposed.path) else { return proposed }
        let stem = proposed.deletingPathExtension().lastPathComponent
        let ext = proposed.pathExtension
        for index in 2...10_000 {
            let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileExists(candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(sanitized(suggestedFilename))")
    }

    static func sanitized(_ filename: String) -> String {
        let name = URL(fileURLWithPath: filename).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "." ? "Download" : name
    }
}

enum DownloadFailure {
    static func message(for error: NSError) -> String {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorCancelled: return "Download cancelled."
            case NSURLErrorCannotWriteToFile: return "The destination cannot be written."
            case NSURLErrorNoPermissionsToReadFile: return "Interlinked does not have permission to write this file."
            case NSURLErrorHTTPTooManyRedirects: return "The server redirected this download too many times."
            case NSURLErrorBadServerResponse: return "The server returned an invalid response."
            case NSURLErrorTimedOut: return "The server took too long to respond."
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "The download server could not be reached."
            default: break
            }
        }
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileWriteOutOfSpaceError: return "There is not enough disk space for this download."
            case NSFileWriteNoPermissionError: return "Interlinked does not have permission to write this file."
            case NSFileWriteFileExistsError: return "A file already exists at the chosen destination."
            default: break
            }
        }
        return error.localizedDescription
    }
}
