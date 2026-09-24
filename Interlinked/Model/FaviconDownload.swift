import Foundation

/// Fetches favicon candidates without letting a page's server hold memory or
/// time: a body stops at `byteLimit`, and every candidate for one domain
/// shares a single deadline.
enum FaviconDownload {
    static let byteLimit = 1_048_576
    /// Total time for one domain's favicon lookup. `URLRequest.timeoutInterval`
    /// only limits the idle time between packets, so a slow endless stream
    /// never trips it.
    static let deadline: Duration = .seconds(5)

    /// The body of a 200 response smaller than `byteLimit`, or nil when the
    /// request fails, the body is too large, or `deadline` passes first.
    static func data(
        for request: URLRequest,
        session: URLSession = .shared,
        byteLimit: Int = byteLimit,
        until deadline: ContinuousClock.Instant
    ) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask { await download(request, session: session, byteLimit: byteLimit) }
            group.addTask {
                try? await Task.sleep(until: deadline, clock: .continuous)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The whole sequence, or nil as soon as it reaches `byteLimit` bytes.
    /// Never reads more than `byteLimit` bytes.
    static func collect<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        byteLimit: Int
    ) async throws -> Data? where Bytes.Element == UInt8 {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= byteLimit { return nil }
        }
        return data
    }

    private static func download(_ request: URLRequest, session: URLSession, byteLimit: Int) async -> Data? {
        guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
        defer { bytes.task.cancel() }
        // expectedContentLength is -1 when the server does not declare one.
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength < Int64(byteLimit) else { return nil }
        return try? await collect(bytes, byteLimit: byteLimit)
    }
}
