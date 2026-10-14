import AppKit
import WebKit
import XCTest

@testable import WallpaperMachine

/// pixiv tab, end to end through the bundled page and the native actions: browsing a ranking,
/// stepping through a work's pages, saving one to the library, and signing in for R-18 works.
/// pixiv is a fixture and the sign-in window a closure, so nothing leaves the machine and no
/// window opens.
@MainActor
final class ControlPanelPixivTests: ControlPanelTestCase {
  func testPixivTabSavesTheChosenPageOfAWorkWithoutWindow() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.show()
      _ = try await panel.js("document.querySelector('#sidebar [data-page=\"pixiv\"]').click()")
      try await panel.waitUntil(timeout: 5) { panel.pixiv.hasLoaded }
      try await panel.waitJS("document.querySelectorAll('#wallpaper-grid .tile-select').length === 2")
      try await panel.expectJS(
        "return [...document.querySelectorAll('#wallpaper-grid .tile-select')].map(node => node.dataset.id)",
        equals: ["301", "303"])

      _ = try await panel.js("document.querySelector('#wallpaper-grid .tile-select[data-id=\"301\"]').click()")
      try await panel.waitUntil(timeout: 5) { panel.pixiv.selectedPageList?.count == 2 }
      try await panel.waitJS(
        "document.querySelector('#inspector .pixiv-pages [role=\"status\"]')?.textContent.includes('Page 1 of 2')")
      _ = try await panel.js("document.querySelector('#inspector .pixiv-pages button:last-of-type').click()")
      try await panel.waitUntil { panel.pixiv.selectedPage == 1 }
      try await panel.waitJS(
        "document.querySelector('#inspector [data-action=\"pixivDownload\"]')?.textContent.includes('Download page 2')")
      _ = try await panel.js("document.querySelector('#inspector [data-action=\"pixivDownload\"]').click()")
      try await panel.waitUntil(timeout: 10) {
        panel.pixiv.downloads.download(for: "pixiv-301-p1")?.status == .finished
      }

      let project = panel.root.appendingPathComponent("Library/pixiv-301-p1/project.json")
      let manifest = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any])
      XCTAssertEqual(manifest["type"] as? String, "web")
      XCTAssertEqual((manifest["pixiv"] as? [String: Any])?["page"] as? Int, 1)
      XCTAssertNil(panel.controller.actionError)
      XCTAssertNil(panel.web.window)
    }
  }

  func testPausedPixivDownloadResumesFromTheSharedQueueWithoutWindow() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.show()
      _ = try await panel.js("document.querySelector('#sidebar [data-page=\"pixiv\"]').click()")
      try await panel.waitUntil(timeout: 5) { panel.pixiv.hasLoaded }
      let work = try XCTUnwrap(panel.pixiv.works.first { $0.id == "301" })
      panel.pixiv.requestDownload(work, page: 1)
      panel.pixiv.downloads.pause("pixiv-301-p1")
      try await panel.waitUntil { panel.pixiv.downloads.download(for: "pixiv-301-p1")?.status == .paused }
      try await panel.waitJS("document.querySelector('#wallpaper-grid [data-action=\"pixivResume\"]') !== null")
      _ = try await panel.js("document.querySelector('#top-actions [data-action=\"openDownloads\"]').click()")
      try await panel.waitJS("document.querySelector('.queue-row [data-action=\"pixivResume\"][data-id=\"pixiv-301-p1\"]') !== null")
      _ = try await panel.js("document.querySelector('.queue-row [data-action=\"pixivResume\"][data-id=\"pixiv-301-p1\"]').click()")
      try await panel.waitUntil(timeout: 10) { panel.pixiv.downloads.download(for: "pixiv-301-p1")?.status == .finished }
      XCTAssertNil(panel.controller.actionError)
      XCTAssertNil(panel.web.window)
    }
  }

  func testSigningInUnlocksMatureWorksAndLoggingOutLocksThemAgainWithoutWindow() async throws {
    try await withPanel { panel in
      var windowsOpened = 0
      panel.controller.signInToPixiv = {
        windowsOpened += 1
        return PixivFixtures.session
      }
      let mature = "#filter-sidebar [data-change=\"pixivRating\"][value=\"Mature\"]"
      try await panel.finishWelcome()
      panel.show()
      _ = try await panel.js("document.querySelector('#sidebar [data-page=\"pixiv\"]').click()")
      try await panel.waitUntil(timeout: 5) { panel.pixiv.hasLoaded }
      // The account and pixiv's own filters live in the Filters popover.
      _ = try await panel.js("document.querySelector('.browser-toolbar [data-action=\"toggleFilters\"]').click()")
      try await panel.waitJS("document.querySelector('\(mature)')?.disabled === true")

      _ = try await panel.js("document.querySelector('#filter-sidebar [data-action=\"pixivSignIn\"]').click()")
      try await panel.waitUntil(timeout: 5) { panel.pixiv.account != nil && !panel.pixiv.isLoading }
      XCTAssertEqual(windowsOpened, 1)
      XCTAssertEqual(panel.pixivSessions.session, PixivFixtures.session)
      try await panel.waitJS(
        "document.querySelector('#filter-sidebar .pixiv-account')?.textContent.includes('Signed in as Tester')")
      try await panel.waitJS("document.querySelector('\(mature)')?.disabled === false")

      _ = try await panel.js("document.querySelector('\(mature)').click()")
      try await panel.waitUntil { panel.pixiv.query.ratings.contains(.mature) }
      try await panel.waitJS(
        "[...document.getElementById('pixiv-sort').options].some(option => option.value === 'daily_r18')")
      _ = try await panel.js("""
        const sort = document.getElementById('pixiv-sort');
        sort.value = 'daily_r18';
        sort.dispatchEvent(new Event('change', { bubbles: true }));
        """)
      try await panel.waitUntil(timeout: 5) {
        panel.pixiv.committedQuery?.ranking == .dailyR18 && !panel.pixiv.isLoading
      }
      try await panel.waitJS("document.querySelectorAll('#wallpaper-grid .tile-badge.r18').length === 3")

      _ = try await panel.js("document.querySelector('#filter-sidebar [data-action=\"pixivSignOut\"]').click()")
      try await panel.waitUntil(timeout: 5) {
        !panel.pixiv.isSignedIn && panel.pixiv.committedQuery?.ranking == .daily && !panel.pixiv.isLoading
      }
      XCTAssertNil(panel.pixivSessions.session)
      try await panel.waitJS("document.getElementById('pixiv-sort').value === 'daily'")
      try await panel.expectJS("return document.querySelector('\(mature)').checked", equals: false)
      try await panel.expectJS("return document.querySelectorAll('#wallpaper-grid .tile-badge.r18').length", equals: 0)
      XCTAssertEqual(windowsOpened, 1)
      XCTAssertNil(panel.controller.actionError)
    }
  }
}
