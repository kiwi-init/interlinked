import XCTest

final class FaviconDownloadTests: XCTestCase {
    private var server: Process?
    private var base: URL!

    override func setUpWithError() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("test-fixtures/server.py")
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "0"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        server = process

        // The first line names the port the server picked.
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data("\n".utf8) {
            line.append(byte)
        }
        // Keep draining request logs so the server never blocks on a full pipe.
        output.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        let address = String(decoding: line, as: UTF8.self).components(separatedBy: " ").last ?? ""
        base = try XCTUnwrap(URL(string: address), "Fixture server did not start: \(address)")
    }

    override func tearDown() {
        server?.terminate()
        server?.waitUntilExit()
        server = nil
    }

    private func fetch(_ path: String, within deadline: Duration) async -> (data: Data?, elapsed: Duration) {
        let request = URLRequest(url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        let clock = ContinuousClock()
        let start = clock.now
        let data = await FaviconDownload.data(for: request, until: start + deadline)
        return (data, clock.now - start)
    }

    func testEndlessStreamStopsAtTheByteCapBeforeTheDeadline() async {
        let result = await fetch("favicon/endless", within: .seconds(5))

        XCTAssertNil(result.data)
        XCTAssertLessThan(result.elapsed, .seconds(3))
    }

    func testSlowEndlessStreamEndsAtTheDeadline() async {
        // One byte every 0.2 seconds never trips the 8 second idle timeout.
        let result = await fetch("favicon/drip", within: .seconds(1))

        XCTAssertNil(result.data)
        XCTAssertGreaterThanOrEqual(result.elapsed, .milliseconds(900))
        XCTAssertLessThan(result.elapsed, .seconds(3))
    }

    func testDeclaredOversizedBodyIsRejectedFromItsHeaders() async {
        // The server declares 10 MB and sends it slowly, so reading up to the
        // byte cap would take about 13 seconds.
        let result = await fetch("favicon/oversized", within: .seconds(5))

        XCTAssertNil(result.data)
        XCTAssertLessThan(result.elapsed, .seconds(3))
    }
}

final class FaviconByteLimitTests: XCTestCase {
    func testCollectNeverReadsPastTheCap() async throws {
        let bytes = EndlessBytes()
        let data = try await FaviconDownload.collect(bytes, byteLimit: 4_096)

        XCTAssertNil(data)
        XCTAssertEqual(bytes.counter.pulled, 4_096)
    }

    func testCollectReturnsABodyUnderTheCap() async throws {
        let body = Data("icon".utf8)
        let data = try await FaviconDownload.collect(AsyncBytes(body), byteLimit: 4_096)

        XCTAssertEqual(data, body)
    }
}

private final class PullCounter: @unchecked Sendable {
    var pulled = 0
}

private struct EndlessBytes: AsyncSequence {
    typealias Element = UInt8
    let counter = PullCounter()

    struct AsyncIterator: AsyncIteratorProtocol {
        let counter: PullCounter
        mutating func next() async -> UInt8? {
            counter.pulled += 1
            return 0
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(counter: counter) }
}

private struct AsyncBytes: AsyncSequence {
    typealias Element = UInt8
    let data: Data
    init(_ data: Data) { self.data = data }

    struct AsyncIterator: AsyncIteratorProtocol {
        var bytes: Data.Iterator
        mutating func next() async -> UInt8? { bytes.next() }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(bytes: data.makeIterator()) }
}
