import XCTest

@MainActor
final class BrowserHistoryControlTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("history.json") }
    private var defaults: UserDefaults!
    private var suite: String!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "history-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(retention: HistoryRetention = .standard) -> BrowserHistoryStore {
        BrowserHistoryStore(file: file, retention: retention, defaults: defaults, now: { [unowned self] in self.clock })
    }

    private func visit(_ url: String, _ title: String, daysAgo: Double) -> BrowserHistoryVisit {
        BrowserHistoryVisit(id: UUID(), url: url, title: title, visited: clock.addingTimeInterval(-daysAgo * 86_400))
    }

    func testRetentionDropsVisitsOlderThanTheWindowOnRecordAndLoad() throws {
        let history = store(retention: HistoryRetention(days: 90, limit: 100))
        history.record(URL(string: "https://old.test/"), title: "Old")
        clock = clock.addingTimeInterval(89 * 86_400)
        history.record(URL(string: "https://recent.test/"), title: "Recent")
        XCTAssertEqual(history.visits.map(\.title), ["Recent", "Old"])

        clock = clock.addingTimeInterval(2 * 86_400)
        history.record(URL(string: "https://new.test/"), title: "New")
        XCTAssertEqual(history.visits.map(\.title), ["New", "Recent"])
        history.save()

        clock = clock.addingTimeInterval(89 * 86_400)
        XCTAssertEqual(store(retention: HistoryRetention(days: 90, limit: 100)).visits.map(\.title), ["New"])
    }

    func testRetentionKeepsOnlyTheNewestVisitsUpToTheLimit() {
        let history = store(retention: HistoryRetention(days: 90, limit: 3))
        for index in 1...5 {
            clock = clock.addingTimeInterval(60)
            history.record(URL(string: "https://site\(index).test/"), title: "Page \(index)")
        }
        XCTAssertEqual(history.visits.map(\.title), ["Page 5", "Page 4", "Page 3"])
        history.save()
        XCTAssertEqual(store(retention: HistoryRetention(days: 90, limit: 2)).visits.map(\.title), ["Page 5", "Page 4"])
    }

    func testDeletesOneVisitEverySiteVisitAndTimeRanges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 12:00 UTC, so "today" began twelve hours ago.
        clock = Date(timeIntervalSince1970: 1_800_014_400)
        XCTAssertEqual(calendar.component(.hour, from: clock), 12)
        let history = store()
        let pages: [(String, TimeInterval)] = [
            ("https://www.docs.test/yesterday", 13 * 3_600),
            ("http://docs.test/morning", 5 * 3_600),
            ("https://news.test/morning", 4 * 3_600),
            ("https://docs.test/recent", 30 * 60),
            ("https://news.test/now", 60),
        ]
        let start = clock
        for (url, ago) in pages {
            clock = start.addingTimeInterval(-ago)
            history.record(URL(string: url), title: url)
        }
        clock = start

        let one = history.visits.first { $0.url == "https://news.test/morning" }!
        history.remove(one.id)
        XCTAssertFalse(history.visits.contains { $0.id == one.id })
        XCTAssertEqual(history.visits.count, 4)

        history.removeSite("docs.test")
        XCTAssertEqual(history.visits.map(\.url), ["https://news.test/now"])

        history.record(URL(string: "https://www.docs.test/yesterday"), title: "Again")
        history.remove(.lastHour, calendar: calendar)
        XCTAssertTrue(history.visits.isEmpty)

        for (url, ago) in pages {
            clock = start.addingTimeInterval(-ago)
            history.record(URL(string: url), title: url)
        }
        clock = start
        history.remove(.today, calendar: calendar)
        XCTAssertEqual(history.visits.map(\.url), ["https://www.docs.test/yesterday"])
        history.remove(.everything, calendar: calendar)
        XCTAssertTrue(history.visits.isEmpty)
        XCTAssertTrue(store().visits.isEmpty)
    }

    func testTurningHistoryOffClearsTheStoreAndStopsRecording() throws {
        let history = store()
        history.record(URL(string: "https://one.test/"), title: "One")
        history.save()
        XCTAssertEqual(history.visits.count, 1)

        history.enabled = false
        XCTAssertTrue(history.visits.isEmpty)
        XCTAssertFalse(BrowserHistoryPreference.enabled(in: defaults))
        history.record(URL(string: "https://two.test/"), title: "Two")
        XCTAssertTrue(history.visits.isEmpty)

        let reopened = store()
        XCTAssertFalse(reopened.enabled)
        XCTAssertTrue(reopened.visits.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        reopened.enabled = true
        reopened.record(URL(string: "https://three.test/"), title: "Three")
        XCTAssertEqual(reopened.visits.map(\.title), ["Three"])
    }

    func testMigratesTheVersionOneArrayFileAndAppliesRetention() throws {
        let legacy = [
            visit("https://kept.test/", "Kept", daysAgo: 3),
            visit("https://expired.test/", "Expired", daysAgo: 120),
        ]
        try JSONEncoder().encode(legacy).write(to: file)

        let history = store()
        XCTAssertEqual(history.visits.map(\.title), ["Kept"])
        XCTAssertEqual(history.visits.first?.id, legacy[0].id)

        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(written?["version"] as? Int, 2)
        XCTAssertEqual((written?["visits"] as? [Any])?.count, 1)
        XCTAssertEqual(store().visits, history.visits)
    }

    func testVisitsReachDiskInTheBackgroundAndADeletionAfterThemWins() async throws {
        let history = store()
        history.record(URL(string: "https://one.test/"), title: "One")
        let deadline = ContinuousClock.now + .seconds(5)
        while store().visits.isEmpty {
            guard ContinuousClock.now < deadline else { return XCTFail("The visit never reached disk") }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(store().visits.map(\.title), ["One"])

        // A deletion right after a visit lands after the visit's pending save.
        history.record(URL(string: "https://two.test/"), title: "Two")
        history.remove(.everything)
        XCTAssertTrue(store().visits.isEmpty)
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertTrue(store().visits.isEmpty)
    }
}

final class SessionStateTests: XCTestCase {
    private var directory: URL!
    private var path: URL { directory.appendingPathComponent("session.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func session(active: Int, order: [UInt64], closed: [ClosedTab] = []) -> Session {
        let tabs = order.map { Tab(id: TabID($0), pane: PaneID($0 * 10)) }
        return Session(
            version: 0, tabs: tabs, active: active,
            next_tab: 10, next_pane: 100, next_split: 1,
            surfaces: order.map { SurfacePair(pane: PaneID($0 * 10), surface: Surface(kind: .browser, line: "https://\($0).test/")) },
            tint: .ink, sidebar: 216, sidebar_last: 216,
            closed: closed,
            scroll: [ScrollMark(pane: PaneID(order[0] * 10), url: "https://\(order[0]).test/", title: "First", y: 640)]
        ).stamped()
    }

    func testNormalQuitRestoresSelectedTabOrderAndClosedTabs() throws {
        let writer = SessionWriter(delay: .seconds(60))
        let closed = [ClosedTab(url: "https://gone.test/", name: "Research", closed: Date(timeIntervalSince1970: 1_800_000_000))]
        let saved = session(active: 2, order: [3, 1, 2], closed: closed)
        writer.write(try XCTUnwrap(Session.data(saved)), to: path)
        writer.flush()

        let restored = try XCTUnwrap(Session.read(at: path))
        XCTAssertEqual(restored.version, Session.version)
        XCTAssertEqual(restored.tabs.map(\.id), [TabID(3), TabID(1), TabID(2)])
        XCTAssertEqual(restored.active, 2)
        XCTAssertEqual(restored.closed, closed)
        XCTAssertEqual(restored.scroll, saved.scroll)
        XCTAssertEqual(try Data(contentsOf: Session.backupPath(for: path)), try Data(contentsOf: path))
    }

    func testForcedTerminationKeepsTheLastFlushedSession() throws {
        let writer = SessionWriter(delay: .seconds(60))
        writer.write(try XCTUnwrap(Session.data(session(active: 0, order: [1, 2]))), to: path)
        writer.flush()
        // The process dies before the next write reaches disk.
        writer.write(try XCTUnwrap(Session.data(session(active: 1, order: [2, 1, 3]))), to: path)

        let restored = try XCTUnwrap(Session.read(at: path))
        XCTAssertEqual(restored.tabs.map(\.id), [TabID(1), TabID(2)])
        XCTAssertEqual(restored.active, 0)
    }

    func testCorruptSessionIsKeptAsideAndTheLastGoodCopyOpens() throws {
        let writer = SessionWriter(delay: .seconds(60))
        writer.write(try XCTUnwrap(Session.data(session(active: 1, order: [4, 5]))), to: path)
        writer.flush()
        let garbage = Data("{\"version\":2,\"tabs\":[".utf8)
        try garbage.write(to: path)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let restored = try XCTUnwrap(Session.read(at: path, now: now))
        XCTAssertEqual(restored.tabs.map(\.id), [TabID(4), TabID(5)])
        XCTAssertEqual(restored.active, 1)

        let aside = directory.appendingPathComponent("session.json.corrupt-1800000000000")
        XCTAssertEqual(try Data(contentsOf: aside), garbage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testCorruptSessionWithoutBackupStartsEmptyButKeepsTheFile() throws {
        try Data("not json".utf8).write(to: path)
        XCTAssertNil(Session.read(at: path, now: Date(timeIntervalSince1970: 1)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("session.json.corrupt-1000").path))
    }

    func testMissingSessionDoesNotFallBackToTheBackup() throws {
        let writer = SessionWriter(delay: .seconds(60))
        writer.write(try XCTUnwrap(Session.data(session(active: 0, order: [1]))), to: path)
        writer.flush()
        try FileManager.default.removeItem(at: path)
        XCTAssertNil(Session.read(at: path))
    }

    func testMigratesVersionOneSessions() throws {
        var tab = Tab(id: TabID(7), pane: PaneID(70))
        tab.name = "Mail"
        let old = Session(
            version: 1, tabs: [tab], active: 0, next_tab: 8, next_pane: 71, next_split: 1,
            surfaces: [SurfacePair(pane: PaneID(70), surface: Surface(kind: .browser, line: "https://mail.test/"))],
            tint: .ink, sidebar: 216, sidebar_last: 216
        )
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        legacy["closed"] = nil
        legacy["scroll"] = nil
        try JSONSerialization.data(withJSONObject: legacy).write(to: path)

        let restored = try XCTUnwrap(Session.read(at: path))
        XCTAssertEqual(restored.version, 2)
        XCTAssertEqual(restored.tabs, [tab])
        XCTAssertEqual(restored.surfaces.first?.surface.line, "https://mail.test/")
        XCTAssertTrue(restored.closed.isEmpty)
        XCTAssertTrue(restored.scroll.isEmpty)

        legacy["version"] = 3
        try JSONSerialization.data(withJSONObject: legacy).write(to: path)
        XCTAssertNil(Session.read(at: path, now: Date(timeIntervalSince1970: 2)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("session.json.corrupt-2000").path))
    }

    func testRecentlyClosedKeepsTheLast25() {
        var list: [ClosedTab] = []
        for index in 1...30 {
            list = ClosedTab.remember(ClosedTab(url: "https://\(index).test/", name: nil, closed: Date()), in: list)
        }
        XCTAssertEqual(list.count, 25)
        XCTAssertEqual(list.first?.url, "https://6.test/")
        XCTAssertEqual(list.last?.url, "https://30.test/")
    }

    func testScrollRestoresOnlyOnTheSameDocument() {
        let mark = ScrollMark(pane: PaneID(1), url: "https://docs.test/guide", title: "Guide", y: 1_200)
        XCTAssertTrue(mark.fits(url: URL(string: "https://docs.test/guide"), title: "Guide"))
        XCTAssertFalse(mark.fits(url: URL(string: "https://docs.test/guide"), title: "Guide (updated)"))
        XCTAssertFalse(mark.fits(url: URL(string: "https://docs.test/other"), title: "Guide"))
        XCTAssertFalse(mark.fits(url: nil, title: "Guide"))
        XCTAssertFalse(ScrollMark(pane: PaneID(1), url: "https://docs.test/guide", title: "Guide", y: 0)
            .fits(url: URL(string: "https://docs.test/guide"), title: "Guide"))
    }

    func testSessionSchemaHoldsNoFormPasswordOrPrivateWindowState() throws {
        let data = try XCTUnwrap(Session.data(session(active: 0, order: [1])))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), [
            "version", "tabs", "active", "next_tab", "next_pane", "next_split", "surfaces",
            "tint", "sidebar", "sidebar_last", "closed", "scroll",
        ])
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for word in ["password", "form", "private", "incognito", "back_list", "forward"] {
            XCTAssertFalse(text.contains(word), word)
        }
    }
}
