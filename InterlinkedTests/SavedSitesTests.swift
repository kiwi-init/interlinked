import XCTest

@MainActor
final class SavedSitesTests: XCTestCase {
    func testArtistCreditPointsAtTechniacus() {
        XCTAssertEqual(NewTabArt.artistName, "Techniacus")
        XCTAssertEqual(NewTabArt.artistURL.absoluteString, "https://x.com/Techniacus")
        XCTAssertEqual(NewTabArt.imageName, "NewTabArt")
    }

    func testOnlyHttpSitesAreSavedAndCredentialsAreStripped() {
        XCTAssertNil(SavedSiteAddress.normalize("not a site"))
        XCTAssertNil(SavedSiteAddress.normalize("about:blank"))
        XCTAssertNil(SavedSiteAddress.normalize("file:///tmp/page.html"))
        XCTAssertEqual(SavedSiteAddress.normalize("example.com")?.url, "https://example.com")
        XCTAssertEqual(SavedSiteAddress.normalize("https://user:secret@example.com/path")?.url, "https://example.com/path")
        XCTAssertEqual(SavedSiteAddress.normalize("https://www.wikipedia.org/")?.title, "wikipedia.org")
    }

    func testFavoritesAndBookmarksStaySeparateAndPersist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("saved-sites.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SavedSites(file: file)
        let favorite = try XCTUnwrap(store.add("https://example.com", title: "Example", to: .favorite))
        let bookmark = try XCTUnwrap(store.add("https://developer.apple.com/documentation", title: nil, to: .bookmark))
        XCTAssertEqual(store.favorites.map(\.title), ["Example"])
        XCTAssertEqual(store.bookmarks.map(\.title), ["developer.apple.com"])
        XCTAssertTrue(store.contains("example.com", in: .favorite))
        XCTAssertFalse(store.contains("example.com", in: .bookmark))
        XCTAssertEqual(store.add("https://example.com/", title: "Ignored", to: .favorite)?.id, favorite.id)
        XCTAssertEqual(store.favorites.count, 1)

        XCTAssertTrue(store.toggle("https://developer.apple.com/documentation", title: nil, in: .bookmark) == false)
        XCTAssertTrue(store.bookmarks.isEmpty)
        _ = store.add(bookmark.url, title: bookmark.title, to: .bookmark)

        let reloaded = SavedSites(file: file)
        XCTAssertEqual(reloaded.favorites.map(\.url), ["https://example.com"])
        XCTAssertEqual(reloaded.bookmarks.map(\.title), ["developer.apple.com"])
        reloaded.remove(favorite.id, from: .favorite)
        XCTAssertTrue(SavedSites(file: file).favorites.isEmpty)
        XCTAssertEqual(SavedSites(file: file).bookmarks.count, 1)
    }

    func testFavoriteLimitDoesNotSpillIntoBookmarks() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("saved-sites.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavedSites(file: file)
        for index in 1...SavedSiteAddress.favoriteLimit {
            XCTAssertNotNil(store.add("https://site-\(index).example", title: nil, to: .favorite))
        }
        XCTAssertNil(store.add("https://overflow.example", title: nil, to: .favorite))
        XCTAssertNotNil(store.add("https://overflow.example", title: nil, to: .bookmark))
        XCTAssertEqual(store.favorites.count, SavedSiteAddress.favoriteLimit)
        XCTAssertEqual(store.bookmarks.count, 1)
    }

    func testNewTabStripCanBeTurnedOffAndDefaultsOn() {
        let suite = "saved-sites-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("saved-sites.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SavedSites(file: file, defaults: defaults)
        XCTAssertTrue(store.showsOnNewTab)
        store.showsOnNewTab = false
        XCTAssertFalse(NewTabSavedSitesPreference.enabled(in: defaults))
        XCTAssertFalse(SavedSites(file: file, defaults: defaults).showsOnNewTab)
        store.showsOnNewTab = true
        XCTAssertTrue(SavedSites(file: file, defaults: defaults).showsOnNewTab)
    }

    func testSavedSiteIconsPersistOnTheRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("saved-sites.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavedSites(file: file)
        let site = try XCTUnwrap(store.add("https://example.com", title: "Example", to: .favorite))
        XCTAssertNil(site.icon)
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        store.setIcon(bytes, id: site.id)
        XCTAssertEqual(store.favorites.first?.icon, bytes)
        store.fillMissingIcon(Data([1, 2, 3]), domain: "example.com")
        XCTAssertEqual(store.favorites.first?.icon, bytes)
        XCTAssertEqual(SavedSites(file: file).favorites.first?.icon, bytes)
        XCTAssertEqual(store.domains, ["example.com"])
    }
}
