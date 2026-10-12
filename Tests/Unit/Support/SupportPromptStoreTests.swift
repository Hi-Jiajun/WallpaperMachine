import XCTest
@testable import WallpaperMachine

@MainActor
final class SupportPromptStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    func testDownloadsWaitForSuccessfulActivation() {
        let store = SupportPromptStore(defaults: defaults)
        store.recordDownload(wallpaperID: "wallpaper-1")
        store.recordDownload(wallpaperID: "wallpaper-1")
        store.recordDownload(wallpaperID: "wallpaper-2")
        XCTAssertFalse(store.isPending)
    }

    func testUnrelatedActivationDoesNotConsumeDownloadedWallpaper() {
        let store = SupportPromptStore(defaults: defaults)
        store.recordDownload(wallpaperID: "downloaded")
        store.recordSuccessfulActivation(wallpaperID: "local-import")
        XCTAssertFalse(store.isPending)

        store.recordSuccessfulActivation(wallpaperID: "downloaded")
        XCTAssertTrue(store.isPending)
    }

    func testActivationBeforeDownloadDoesNotQualify() {
        let store = SupportPromptStore(defaults: defaults)
        store.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        store.recordDownload(wallpaperID: "wallpaper-1")
        XCTAssertFalse(store.isPending)

        store.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        XCTAssertTrue(store.isPending)
    }

    func testAnySuccessfullyDownloadedWallpaperCanQualify() {
        let store = SupportPromptStore(defaults: defaults)
        store.recordDownload(wallpaperID: "wallpaper-1")
        store.recordDownload(wallpaperID: "wallpaper-2")
        store.recordSuccessfulActivation(wallpaperID: "wallpaper-2")
        XCTAssertTrue(store.isPending)
    }

    func testDownloadedWallpaperCanBeActivatedAfterRelaunch() {
        let original = SupportPromptStore(defaults: defaults)
        original.recordDownload(wallpaperID: "wallpaper-1")

        let relaunched = SupportPromptStore(defaults: defaults)
        XCTAssertFalse(relaunched.isPending)
        relaunched.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        XCTAssertTrue(relaunched.isPending)
    }

    func testPendingPromptSurvivesRelaunchAndFurtherDownloads() {
        let original = SupportPromptStore(defaults: defaults)
        original.recordDownload(wallpaperID: "wallpaper-1")
        original.recordSuccessfulActivation(wallpaperID: "wallpaper-1")

        let relaunched = SupportPromptStore(defaults: defaults)
        XCTAssertTrue(relaunched.isPending)
        relaunched.recordDownload(wallpaperID: "wallpaper-2")
        relaunched.recordSuccessfulActivation(wallpaperID: "wallpaper-2")
        XCTAssertTrue(relaunched.isPending)
        XCTAssertTrue(SupportPromptStore(defaults: defaults).isPending)
    }

    func testPresentedPromptNeverReturnsAfterFurtherDownloadsOrRelaunch() {
        let original = SupportPromptStore(defaults: defaults)
        original.recordDownload(wallpaperID: "wallpaper-1")
        original.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        original.markPresented()
        XCTAssertFalse(original.isPending)

        original.recordDownload(wallpaperID: "wallpaper-2")
        original.recordSuccessfulActivation(wallpaperID: "wallpaper-2")
        XCTAssertFalse(original.isPending)

        let relaunched = SupportPromptStore(defaults: defaults)
        relaunched.recordDownload(wallpaperID: "wallpaper-3")
        relaunched.recordSuccessfulActivation(wallpaperID: "wallpaper-3")
        relaunched.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        relaunched.markPresented()
        XCTAssertFalse(relaunched.isPending)
        XCTAssertFalse(SupportPromptStore(defaults: defaults).isPending)
    }

    func testMarkPresentedWithoutPendingPromptDoesNotSuppressFutureOffer() {
        let original = SupportPromptStore(defaults: defaults)
        original.markPresented()

        let relaunched = SupportPromptStore(defaults: defaults)
        relaunched.recordDownload(wallpaperID: "wallpaper-1")
        relaunched.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        XCTAssertTrue(relaunched.isPending)
    }

    func testDeletedDownloadCannotQualifyUntilDownloadedAgain() {
        let original = SupportPromptStore(defaults: defaults)
        original.recordDownload(wallpaperID: "wallpaper-1")
        original.forgetDownload(wallpaperID: "wallpaper-1")

        let relaunched = SupportPromptStore(defaults: defaults)
        relaunched.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        XCTAssertFalse(relaunched.isPending)
        relaunched.recordDownload(wallpaperID: "wallpaper-1")
        relaunched.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        XCTAssertTrue(relaunched.isPending)
    }

    func testEmptyWallpaperIDCannotQualifyOrConsumeValidDownload() {
        let store = SupportPromptStore(defaults: defaults)
        store.recordDownload(wallpaperID: "")
        store.recordSuccessfulActivation(wallpaperID: "")
        XCTAssertFalse(store.isPending)

        store.recordDownload(wallpaperID: "wallpaper-1")
        store.recordSuccessfulActivation(wallpaperID: "")
        XCTAssertFalse(store.isPending)
        store.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        XCTAssertTrue(store.isPending)
    }
}
