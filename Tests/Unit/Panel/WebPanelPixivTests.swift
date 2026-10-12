import Foundation
import XCTest

@testable import WallpaperMachine

/// The pixiv tab's native half without a web view: what its snapshot says, which requests its
/// actions accept, which library ids count as saved pixiv pages, and which images its route
/// serves. pixiv is a fixture and the keychain an in-memory store.
@MainActor
final class WebPanelPixivTests: ControlPanelTestCase {
  private struct Context {
    let controller: WebPanelController
    let pixiv: PixivStore
    let sessions: PixivMemorySessionStore
    let workshop: WorkshopStore
  }

  private func makeContext() throws -> Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("web-pixiv-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let transport = PixivFixtureTransport(respondingToSession: { url, session in
      if url.path == "/touch/ajax/user/self/status" {
        return PixivFixtures.status(signedIn: session == PixivFixtures.session)
      }
      return PixivFixtures.ranking([PixivFixtures.rankingEntry(.init(id: 11), rank: 1)])
    })
    let sessions = PixivMemorySessionStore()
    let pixiv = PixivStore(
      service: PixivService(transport: transport, minimumInterval: .zero),
      packager: PixivWallpaperPackager(library: root.appendingPathComponent("Library")), sessions: sessions)
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root, defaults: defaults)
    let controller = WebPanelController(
      store: makeStore().store, navigation: ControlPanelNavigation(), workshop: workshop, pixiv: pixiv,
      defaults: defaults, appLanguage: .english())
    controller.signInToPixiv = { nil }
    return Context(controller: controller, pixiv: pixiv, sessions: sessions, workshop: workshop)
  }

  private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
      guard Date() < deadline else { return XCTFail("Timed out", file: file, line: line) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func search(_ overrides: [String: Any] = [:]) -> WebPanelRequest {
    var body: [String: Any] = [
      "text": "", "ranking": "daily", "order": "date_d", "orientation": "any", "minimumSize": "any",
      "hideAI": false, "ratings": ["Everyone"], "refresh": false,
    ]
    body.merge(overrides) { $1 }
    return WebPanelRequest(body)
  }

  func testInstalledPagesAreReadOffTheIDsThePackagerGives() {
    let pages = WebPanelController.installedPixivPages(in: [
      "pixiv-42-p3", "pixiv-42-p0", "pixiv-7-p0", "pixiv-42-p01", "pixiv-0-p0", "pixiv-42-p-1", "pixiv-42",
      "pixiv-x-p0", "other-42-p0", "pixiv-42-p2-extra", "pixiv-42-q1",
    ])
    XCTAssertEqual(pages, ["42": [0, 3], "7": [0]])
  }

  func testThumbnailRouteServesOnlyAnnouncedPixivImages() throws {
    let assets = WebPanelAssets()
    let image = try XCTUnwrap(URL(string: "https://i.pximg.net/c/480x960/img-master/img/1_p0_master1200.jpg"))
    assets.pixivThumbnails = [
      "1": image, "2": try XCTUnwrap(URL(string: "https://example.com/1.jpg")),
      "3": try XCTUnwrap(URL(string: "http://i.pximg.net/1.jpg")),
    ]

    XCTAssertEqual(WebPanelController.pixivAddress("1"), "mwe-ui://pixiv-thumbnail/1")
    XCTAssertEqual(assets.route(try XCTUnwrap(URL(string: "mwe-ui://pixiv-thumbnail/1"))), .pixivThumbnail(image))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://pixiv-thumbnail/2"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://pixiv-thumbnail/3"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://pixiv-thumbnail/4"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://pixiv-thumbnail:8080/1"))))
  }

  func testSearchAcceptsOnlyOfferedValuesAndAsksForR18OnlyWhenSignedIn() async throws {
    let context = try makeContext()
    let controller = context.controller
    defer { controller.stop() }

    XCTAssertTrue(try controller.performPixiv("pixivSearch", request: search(["ranking": "daily_r18", "ratings": ["Everyone", "Mature"]])))
    XCTAssertEqual(context.pixiv.query.ranking, .daily, "signed out, nothing R-18 is asked for")
    XCTAssertEqual(context.pixiv.query.ratings, [.everyone])

    for invalid: [String: Any] in [
      ["ratings": ["Grotesque"]], ["ratings": "Everyone"], ["ranking": "hourly"], ["order": "popular_d"],
      ["text": String(repeating: "a", count: 257)], ["hideAI": "yes"],
    ] {
      XCTAssertThrowsError(try controller.performPixiv("pixivSearch", request: search(invalid)), "\(invalid)")
    }
    XCTAssertThrowsError(try controller.performPixiv("pixivPage", request: WebPanelRequest(["page": 0])))
    XCTAssertThrowsError(try controller.performPixiv("pixivSelectPage", request: WebPanelRequest(["id": "11", "page": 0])))
    XCTAssertThrowsError(try controller.performPixiv("pixivSelect", request: WebPanelRequest(["id": "999"])))
    XCTAssertFalse(try controller.performPixiv("pixivSomethingElse", request: WebPanelRequest([:])))

    context.controller.signInToPixiv = { PixivFixtures.session }
    XCTAssertTrue(try controller.performPixiv("pixivSignIn", request: WebPanelRequest([:])))
    try await waitUntil { context.pixiv.account != nil }
    XCTAssertTrue(try controller.performPixiv("pixivSearch", request: search(["ranking": "daily_r18", "ratings": ["Everyone", "Mature"]])))
    XCTAssertEqual(context.pixiv.query.ranking, .dailyR18)
    XCTAssertEqual(context.pixiv.query.ratings, [.everyone, .mature])
    await context.workshop.steamCMDSetup.shutdown()
    await context.pixiv.downloads.shutdown()
  }

  func testSnapshotSaysWhoIsSignedInAndLogOutForgetsTheSession() async throws {
    let context = try makeContext()
    let controller = context.controller
    defer { controller.stop() }
    var account = try XCTUnwrap(controller.pixivSnapshot()["account"] as? [String: Any])
    XCTAssertEqual(account["signedIn"] as? Bool, false)
    XCTAssertEqual(account["signingIn"] as? Bool, false)
    XCTAssertTrue(account["name"] is NSNull)

    var opened = 0
    controller.signInToPixiv = {
      opened += 1
      return PixivFixtures.session
    }
    XCTAssertTrue(try controller.performPixiv("pixivSignIn", request: WebPanelRequest([:])))
    XCTAssertEqual(
      (controller.pixivSnapshot()["account"] as? [String: Any])?["signingIn"] as? Bool, true,
      "the page says to finish in the sign-in window")
    try await waitUntil { context.pixiv.account != nil && !context.pixiv.isSigningIn }
    XCTAssertTrue(try controller.performPixiv("pixivSignIn", request: WebPanelRequest([:])))
    XCTAssertEqual(opened, 1, "signed in, the action opens nothing")

    account = try XCTUnwrap(controller.pixivSnapshot()["account"] as? [String: Any])
    XCTAssertEqual(account["signedIn"] as? Bool, true)
    XCTAssertEqual(account["name"] as? String, "Tester")
    XCTAssertEqual(account["id"] as? String, "31415926")
    XCTAssertEqual(account["showsR18"] as? Bool, true)
    XCTAssertEqual(context.sessions.session, PixivFixtures.session)
    XCTAssertFalse(
      String(describing: controller.pixivSnapshot()).contains(PixivFixtures.session),
      "the session never reaches the page")

    XCTAssertTrue(try controller.performPixiv("pixivSignOut", request: WebPanelRequest([:])))
    account = try XCTUnwrap(controller.pixivSnapshot()["account"] as? [String: Any])
    XCTAssertEqual(account["signedIn"] as? Bool, false)
    XCTAssertTrue(account["name"] is NSNull)
    XCTAssertNil(context.sessions.session)
    await context.workshop.steamCMDSetup.shutdown()
    await context.pixiv.downloads.shutdown()
  }
}
