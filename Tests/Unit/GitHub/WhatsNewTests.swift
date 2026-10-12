import XCTest
@testable import WallpaperMachine

@MainActor
final class WhatsNewTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    func testFreshInstallAndSameVersionRelaunchDoNotAnnounce() throws {
        let history = try history()
        XCTAssertNil(store("1.0.0").announcement(history: history, existingUser: false))
        XCTAssertNil(store("1.0.0").announcement(history: history, existingUser: true))
        XCTAssertEqual(store("1.1.0").announcement(history: history, existingUser: true)?.previousVersion, "1.0.0")
    }

    func testUpgradeIncludesSkippedVersionsButNotPreviousOrFutureReleases() throws {
        let history = try history()
        _ = store("1.0.0").announcement(history: history, existingUser: false)
        let current = store("1.2.0")
        let announcement = try XCTUnwrap(current.announcement(history: history, existingUser: true))
        XCTAssertEqual(announcement.currentVersion, "1.2.0")
        XCTAssertEqual(announcement.previousVersion, "1.0.0")
        XCTAssertEqual(announcement.releases.map(\.version.display), ["1.2.0", "1.1.0"])
        XCTAssertEqual(announcement.releases.last?.english.sections.first?.items, ["Added a library filter."])
        XCTAssertEqual(announcement.releases.last?.chinese.sections.first?.items, ["新增媒体库筛选功能。"])
        XCTAssertNotNil(store("1.2.0").announcement(history: history, existingUser: true), "An interrupted presentation must retry")
        current.didPresent(announcement)
        XCTAssertNil(store("1.2.0").announcement(history: history, existingUser: true))
    }

    func testCheckboxImmediatelySuppressesFutureVersionsAcrossStoreReloads() throws {
        let history = try history()
        _ = store("1.0.0").announcement(history: history, existingUser: false)
        let current = store("1.1.0")
        let announcement = try XCTUnwrap(current.announcement(history: history, existingUser: true))
        let controller = WhatsNewViewController(
            announcement: announcement, preferences: current, initialLanguage: .english, close: {})
        _ = controller.view
        controller.suppressionCheckbox.performClick(nil)
        XCTAssertNil(store("1.2.0").announcement(history: history, existingUser: true))
        XCTAssertNil(store("2.0.0").announcement(history: history, existingUser: true))
        controller.suppressionCheckbox.performClick(nil)
        XCTAssertFalse(store("2.0.0").isSuppressed)
        XCTAssertNil(store("1.2.0").announcement(history: history, existingUser: true), "Suppressed versions still advance the high-water mark")
    }

    func testLanguageSelectionReplacesAllReleaseTranslationsAndCanSwitchBack() throws {
        let history = try AppReleaseHistory(markdown: entry("1.1.0") + entry("1.2.0")
            .replacingOccurrences(of: "Added a library filter.", with: "Fixed playback.")
            .replacingOccurrences(of: "新增媒体库筛选功能。", with: "修复播放问题。"))
        _ = store("1.0.0").announcement(history: history, existingUser: false)
        let current = store("1.2.0")
        let announcement = try XCTUnwrap(current.announcement(history: history, existingUser: true))
        let controller = WhatsNewViewController(
            announcement: announcement, preferences: current, initialLanguage: .english, close: {})
        _ = controller.view

        func select(_ segment: Int) {
            controller.languageControl.selectedSegment = segment
            controller.languageControl.sendAction(controller.languageControl.action, to: controller.languageControl.target)
        }
        select(0)
        let english = controller.notesView.string
        XCTAssertTrue(english.contains("Fixed playback."))
        XCTAssertTrue(english.contains("Added a library filter."))
        XCTAssertFalse(english.contains("修复播放问题。"))
        XCTAssertFalse(english.contains("新增媒体库筛选功能。"))
        select(1)
        let chinese = controller.notesView.string
        XCTAssertTrue(chinese.contains("修复播放问题。"))
        XCTAssertTrue(chinese.contains("新增媒体库筛选功能。"))
        XCTAssertFalse(chinese.contains("Fixed playback."))
        XCTAssertFalse(chinese.contains("Added a library filter."))
        XCTAssertLessThan(try XCTUnwrap(chinese.range(of: "1.2.0")?.lowerBound),
                          try XCTUnwrap(chinese.range(of: "1.1.0")?.lowerBound))
        select(0)
        XCTAssertEqual(controller.notesView.string, english)
    }

    func testInitialTranslationFollowsSavedAppLanguageAndSystemSelection() throws {
        let history = try history()
        let current = store("1.2.0")
        let announcement = try XCTUnwrap(current.announcement(history: history, existingUser: true))
        let cases = [
            ("zh-Hans", "en", true), ("zh-Hant", "en", true),
            ("en", "zh-CN", false), ("ja", "zh-CN", false),
            ("system", "zh-CN", true), ("system", "en", false),
        ]
        for (preference, systemLanguage, chinese) in cases {
            let language = AppLanguageStore(defaults: defaults, systemLanguages: [systemLanguage])
            try language.set(preference)
            let controller = WhatsNewViewController(
                announcement: announcement, preferences: current, initialLanguage: language.effective, close: {})
            _ = controller.view
            let expected = chinese ? "新增媒体库筛选功能。" : "Added a library filter."
            let excluded = chinese ? "Added a library filter." : "新增媒体库筛选功能。"
            XCTAssertTrue(controller.notesView.string.contains(expected), "\(preference), system: \(systemLanguage)")
            XCTAssertFalse(controller.notesView.string.contains(excluded), "\(preference), system: \(systemLanguage)")
        }
    }

    func testDowngradeAndReturnDoNotRepeatAnAnnouncement() throws {
        let history = try history()
        _ = store("1.2.0").announcement(history: history, existingUser: false)
        XCTAssertNil(store("1.0.0").announcement(history: history, existingUser: true))
        XCTAssertNil(store("1.2.0").announcement(history: history, existingUser: true))
        XCTAssertEqual(store("2.0.0").announcement(history: history, existingUser: true)?.previousVersion, "1.2.0")
    }

    func testLegacyInstallationShowsCurrentNotesWithoutInventingPreviousVersion() throws {
        let history = try history()
        let current = store("1.2.0")
        let announcement = try XCTUnwrap(current.announcement(history: history, existingUser: true))
        XCTAssertNil(announcement.previousVersion)
        XCTAssertEqual(announcement.releases.map(\.version.display), ["1.2.0"])
        current.didPresent(announcement)
        XCTAssertNil(store("1.2.0").announcement(history: history, existingUser: true))
    }

    func testMissingCurrentNotesDoNotConsumeAnUpgrade() throws {
        let incomplete = try AppReleaseHistory(markdown: entry("1.0.0"))
        _ = store("1.0.0").announcement(history: incomplete, existingUser: false)
        XCTAssertNil(store("1.2.0").announcement(history: incomplete, existingUser: true))
        XCTAssertEqual(store("1.2.0").announcement(history: try history(), existingUser: true)?.previousVersion, "1.0.0")
        XCTAssertNil(store("not-a-version").announcement(history: try history(), existingUser: true))
    }

    func testHistoryRejectsMissingTranslationsAndDuplicateVersions() throws {
        XCTAssertThrowsError(try AppReleaseHistory(markdown: "## 1.0.0 — 2026-01-01\n### English\n- Added a filter."))
        XCTAssertThrowsError(try AppReleaseHistory(markdown: entry("1.0.0") + entry("1.0.0")))
        XCTAssertThrowsError(try AppReleaseHistory(markdown: entry("invalid")))
        let history = try AppReleaseHistory(markdown: entry("1.0.0"))
        XCTAssertEqual(history.entries.first?.chinese.sections.first?.items, ["新增媒体库筛选功能。"], "Compare links are not release prose")
    }

    func testHistoryRejectsUnreleasedAndHeadingsInsideNotes() throws {
        XCTAssertThrowsError(try AppReleaseHistory(markdown: """
        ## Unreleased
        ### English
        - Soon.
        ### 简体中文
        - 即将发布。

        """)) { error in
            XCTAssertEqual(error as? AppReleaseHistory.InvalidHistory, .invalidVersion)
        }
        XCTAssertThrowsError(try AppReleaseHistory(markdown: entry("1.0.0").replacingOccurrences(
            of: "- Added a library filter.\n",
            with: "- Added a library filter.\n## Also see\n"
        )))
    }

    private func store(_ version: String) -> WhatsNewStore {
        WhatsNewStore(defaults: defaults, currentVersion: version)
    }

    private func history() throws -> AppReleaseHistory {
        try AppReleaseHistory(markdown: ["1.1.0", "2.0.0", "1.0.0", "1.2.0"].map(entry).joined())
    }

    private func entry(_ version: String) -> String {
        """
        ## \(version) — 2026-01-01
        ### English
        #### New
        - Added a library filter.
        ### 简体中文
        #### 新增
        - 新增媒体库筛选功能。
        **Full changelog**: https://example.com/compare

        """
    }
}
