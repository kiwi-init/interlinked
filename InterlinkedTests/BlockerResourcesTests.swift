import XCTest

final class BlockerResourcesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testBundledResourcesPassValidation() throws {
        XCTAssertNotNil(BlockerResources.validated(try Data(contentsOf: bundled)))
    }

    func testMalformedOrMisshapenResourcesAreRefused() throws {
        let good = try resources()
        XCTAssertNil(BlockerResources.validated(Data("{\"name\":".utf8)))
        XCTAssertNil(BlockerResources.validated(Data("{}".utf8)))
        XCTAssertNil(BlockerResources.validated(try encode(Array(good.prefix(10)))), "too few resources")
        XCTAssertNil(BlockerResources.validated(try encode(good.map { $0.filter { $0.key != "content" } })))
        XCTAssertNil(BlockerResources.validated(try encode(good.map { $0.merging(["content": "not base64!"]) { $1 } })))
        XCTAssertNil(BlockerResources.validated(try encode(good.map { $0.merging(["kind": "script"]) { $1 } })))
        XCTAssertNil(BlockerResources.validated(try encode(good.map { $0.merging(["aliases": "one"]) { $1 } })))
    }

    func testOversizedResourcesAreRefused() throws {
        var padded = try resources()
        padded[0]["aliases"] = [String(repeating: "a", count: BlockerResources.maximumBytes)]
        XCTAssertNil(BlockerResources.validated(try encode(padded)))
    }

    func testLoadFallsBackToTheBundledCopy() throws {
        let cache = directory.appendingPathComponent("blocker-resources.json")
        let bundledJSON = try String(contentsOf: bundled, encoding: .utf8)
        XCTAssertEqual(BlockerResources.load(cache: cache, bundled: bundled), bundledJSON, "no download yet")
        try Data("[]".utf8).write(to: cache)
        XCTAssertEqual(BlockerResources.load(cache: cache, bundled: bundled), bundledJSON, "invalid download")
        XCTAssertEqual(BlockerResources.load(cache: nil, bundled: bundled), bundledJSON, "no remote source")

        var remote = try resources()
        remote[0]["aliases"] = ["remote-alias"]
        try encode(remote).write(to: cache)
        XCTAssertTrue(BlockerResources.load(cache: cache, bundled: bundled).contains("remote-alias"))
    }

    func testRefreshReplacesTheSavedCopyOnlyWithAValidDownload() async throws {
        let cache = directory.appendingPathComponent("blocker-resources.json")
        let saved = try encode(try resources())
        try saved.write(to: cache)
        let remote = URL(string: "https://resources.example/blocker-resources.json")!

        for (status, body) in [(200, Data("[{\"name\":\"broken\"}]".utf8)), (500, saved), (200, Data())] {
            StubProtocol.response = (status, body)
            await BlockerResources.refresh(from: remote, cache: cache, session: StubProtocol.session)
            XCTAssertEqual(try Data(contentsOf: cache), saved, "status \(status)")
        }

        var update = try resources()
        update[0]["aliases"] = ["remote-alias"]
        StubProtocol.response = (200, try encode(update))
        await BlockerResources.refresh(from: remote, cache: cache, session: StubProtocol.session)
        XCTAssertEqual(try Data(contentsOf: cache), StubProtocol.response.body)
    }

    private var bundled: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Interlinked/Resources/blocker-resources.json")
    }

    private func resources() throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: bundled)) as? [[String: Any]])
    }

    private func encode(_ resources: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: resources)
    }
}

/// Answers every request with |response|.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (status: Int, body: Data) = (200, Data())
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.response.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
