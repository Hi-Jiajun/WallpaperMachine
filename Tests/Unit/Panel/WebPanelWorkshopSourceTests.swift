import XCTest

@testable import WallpaperMachine

/// What the panel accepts and shows for Discover's sources: authors, collections and the
/// signed-in account's subscriptions. Steam is never reached: every request fails at once,
/// except the details of the one item a pasted link names.
@MainActor
final class WebPanelWorkshopSourceTests: XCTestCase {
  private var root: URL!
  private var defaults: UserDefaults!
  private var controller: WebPanelController!
  private var workshop: WorkshopStore!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-sources-\(UUID().uuidString)")
    defaults = try TemporaryDefaults.make(for: self).defaults
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OfflineProtocol.self]
    workshop = WorkshopStore(
      service: WorkshopService(session: URLSession(configuration: configuration)),
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root, defaults: defaults)
    controller = WebPanelController(
      store: BridgeStore(bridge: WallpaperBridge(noPointer: .init())), navigation: ControlPanelNavigation(),
      workshop: workshop, defaults: defaults, appLanguage: .english())
  }

  override func tearDown() {
    controller?.stop()
    workshop?.cancelSearch()
    try? FileManager.default.removeItem(at: root)
    controller = nil
    workshop = nil
  }

  func testAnAuthorOpensFromATileAndBackReturnsToTheList() async throws {
    XCTAssertEqual(source()["key"] as? String, "browse")
    XCTAssertEqual(source()["searchable"] as? Bool, true)

    for body: [String: Any] in [
      ["id": "123", "name": "Too short"], ["id": "7656119800000000x", "name": "Letters"],
      ["id": "76561198000000001", "name": String(repeating: "n", count: 257)],
    ] {
      do {
        try await controller.perform("workshopCreator", body: body)
        XCTFail("\(body) is not an author the panel can open")
      } catch {}
    }
    try await controller.perform("workshopCreator", body: ["id": "76561198000000001", "name": "Fixture Author"])
    XCTAssertEqual(source()["key"] as? String, "creator")
    XCTAssertEqual(source()["id"] as? String, "76561198000000001")
    XCTAssertEqual(source()["name"] as? String, "Fixture Author")
    XCTAssertEqual(source()["searchable"] as? Bool, false)
    XCTAssertEqual(source()["canGoBack"] as? Bool, true)

    try await controller.perform("workshopBack", body: [:])
    XCTAssertEqual(source()["key"] as? String, "browse")
    XCTAssertEqual(source()["canGoBack"] as? Bool, false)

    try await controller.perform("workshopCollection", body: ["id": "3768533622", "title": "Night skies"])
    XCTAssertEqual(source()["key"] as? String, "collection")
    do {
      try await controller.perform("workshopCollection", body: ["id": "../3", "title": ""])
      XCTFail("a collection id is digits only")
    } catch {}
    do {
      try await controller.perform("workshopSource", body: ["source": "creator"])
      XCTFail("an author is opened from a tile, not chosen as a list")
    } catch {}
    try await controller.perform("workshopSource", body: ["source": "collections"])
    XCTAssertEqual(source()["key"] as? String, "collections")
    XCTAssertEqual(source()["canGoBack"] as? Bool, false)
  }

  func testSubscriptionsSignInThroughSteamsPageAndSignOutForgetsTheSession() async throws {
    try await controller.perform("workshopSource", body: ["source": "subscriptions"])
    XCTAssertEqual(workshopSnapshot()["steamSignedIn"] as? Bool, false)

    controller.signInToSteamWeb = { "76561198000000001%7C%7C0123456789abcdef0123" }
    try await controller.perform("steamWebSignIn", body: [:])
    for _ in 0..<200 where workshop.steamWebSession == nil { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(workshopSnapshot()["steamSignedIn"] as? Bool, true)
    XCTAssertEqual(workshop.steamWebSession?.steamID, "76561198000000001")

    try await controller.perform("steamWebSignOut", body: [:])
    XCTAssertEqual(workshopSnapshot()["steamSignedIn"] as? Bool, false)
  }

  func testACollectionIsOpenedNotDownloaded() async throws {
    workshop.selectedItem = WorkshopItem(
      id: "900", title: "Collection", creator: "Test", summary: "", previewURL: nil, tags: [], size: 0,
      subscriptions: 0, collectionSize: 4)
    do {
      try await controller.perform("requestDownload", body: ["id": "900"])
      XCTFail("a collection is not one download")
    } catch {}
    XCTAssertTrue(workshop.downloadRequests.isEmpty)
    XCTAssertNil(workshop.downloader.download(for: "900"))
  }

  /// The panel says the sidebar does not apply only while the grid shows an item looked up
  /// from a pasted link, and not once something else has taken its place.
  func testTheSnapshotFlagsTheItemLookedUpFromAPastedLink() async throws {
    XCTAssertEqual(workshopSnapshot()["lookup"] as? Bool, false)
    func search(_ text: String) async throws {
      try await controller.perform("workshopSearch", body: [
        "text": text, "sort": "trend", "tags": [String](), "excludedTags": ["Mature", "Application"],
      ])
      for _ in 0..<400 where workshop.isLoading || !workshop.hasLoaded { try await Task.sleep(for: .milliseconds(5)) }
    }

    try await search("https://steamcommunity.com/sharedfiles/filedetails/?id=\(OfflineProtocol.itemID)")
    XCTAssertEqual(workshopSnapshot()["lookup"] as? Bool, true)
    let items = workshopSnapshot()["items"] as? [[String: Any]] ?? []
    XCTAssertEqual(items.map { $0["id"] as? String }, [OfflineProtocol.itemID])
    XCTAssertEqual(workshopSnapshot()["totalCount"] as? Int, 1)
    XCTAssertTrue((workshopSnapshot()["steamURL"] as? String ?? "").hasSuffix("id=\(OfflineProtocol.itemID)"))

    // A list that cannot be opened empties the grid, and the flag goes with the item.
    try await controller.perform("workshopSource", body: ["source": "collections"])
    for _ in 0..<400 where workshop.isLoading { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(workshopSnapshot()["lookup"] as? Bool, false)
    XCTAssertEqual((workshopSnapshot()["items"] as? [[String: Any]])?.count, 0)
  }

  private func workshopSnapshot() -> [String: Any] {
    controller.snapshot()["workshop"] as? [String: Any] ?? [:]
  }

  private func source() -> [String: Any] {
    workshopSnapshot()["source"] as? [String: Any] ?? [:]
  }
}

/// Fails every request at once, so the panel's Discover never reaches Steam in these tests,
/// except the details of `itemID`, the one Workshop item a pasted link can name here.
private final class OfflineProtocol: URLProtocol, @unchecked Sendable {
  static let itemID = "3632513108"

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url, url.host == "api.steampowered.com",
      url.path.contains("/ISteamRemoteStorage/GetPublishedFileDetails/")
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    let row: [String: Any] = [
      "publishedfileid": Self.itemID, "result": 1, "consumer_app_id": 431960, "creator_app_id": 431960,
      "title": "Pasted item", "creator": "76561198000000001", "tags": [["tag": "Scene"], ["tag": "Mature"]],
      "file_size": "2048", "subscriptions": 3, "time_updated": 1_700_000_000,
    ]
    let body = (try? JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails": [row]]])) ?? Data()
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
