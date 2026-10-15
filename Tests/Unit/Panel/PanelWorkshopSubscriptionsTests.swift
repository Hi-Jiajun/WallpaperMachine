import XCTest

@testable import WallpaperMachine

/// "Download the ones not in your library": Steam is read for the signed-in account's subscriptions,
/// and only what the library lacks is requested. Steam is a fixture: a profile page that lists the
/// subscriptions and a details endpoint that describes them.
@MainActor
final class PanelWorkshopSubscriptionsTests: MediaPanelTestCase {
  private func makePanel(subscribed: [String: String]) throws -> BrowsingPanel {
    SubscriptionsProtocol.subscribed = subscribed
    addTeardownBlock { SubscriptionsProtocol.subscribed = [:] }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SubscriptionsProtocol.self]
    let panel = try makeBrowsingPanel(service: WorkshopService(session: URLSession(configuration: configuration)))
    panel.controller.signInToSteamWeb = { "76561198000000001%7C%7C0123456789abcdef0123" }
    return panel
  }

  private func signIn(_ panel: BrowsingPanel) async throws {
    try await panel.controller.steamWebSignIn()
    await panel.controller.steamWebSignInTask?.value
  }

  private func installed(_ ids: [String]) -> BridgeLibrarySnapshot {
    BridgeLibrarySnapshot(
      wallpapers: ids.map {
        BridgeWallpaperEntry(
          id: $0, title: $0, kind: .video, supported: true, active: false, selected: false, previewPath: nil)
      },
      scanStatus: BridgeLibraryScanStatus(scanning: false, done: 0, total: 0), sceneCount: 0,
      videoCount: UInt64(ids.count), webpageCount: 0, unknownCount: 0)
  }

  func testOnlyWhatTheLibraryLacksIsRequestedAndApplicationsAreSkipped() async throws {
    let panel = try makePanel(subscribed: ["111": "Video", "222": "Application", "333": "Scene", "444": "Video"])
    panel.store.librarySnapshot = installed(["111"])
    try await signIn(panel)
    panel.controller.errors.actionError = "An earlier failure"

    try await panel.controller.downloadSubscribedWorkshopItems()
    XCTAssertEqual(
      Set(panel.workshop.downloadRequests.map(\.id)), ["333", "444"],
      "111 is installed and 222 is an Application, which cannot run here")
    XCTAssertNil(panel.controller.errors.actionError, "asking clears an older banner first")
  }

  func testWhenNothingIsMissingTheActionSaysSo() async throws {
    let panel = try makePanel(subscribed: ["111": "Video"])
    panel.store.librarySnapshot = installed(["111"])
    try await signIn(panel)
    await panel.controller.launch("subscribed") {
      try await panel.controller.downloadSubscribedWorkshopItems()
    }.value
    XCTAssertEqual(
      panel.controller.errors.message, "Every wallpaper you subscribe to is already in your library.")
    XCTAssertTrue(panel.workshop.downloadRequests.isEmpty)
  }

  func testSignedOutTheSteamReadFailsAndTheSessionIsForgotten() async throws {
    let panel = try makePanel(subscribed: ["111": "Video"])
    await panel.controller.launch("subscribed") {
      try await panel.controller.downloadSubscribedWorkshopItems()
    }.value
    XCTAssertEqual(
      panel.controller.errors.message,
      "Steam asked you to sign in again. Sign in to Steam to see your subscriptions.")
    XCTAssertFalse(panel.controller.workshopBrowse.isSignedInToSteam)
  }

  func testTheRequestsWaitInTheCommandQueueAndTheSteamReadDoesNot() async throws {
    let panel = try makePanel(subscribed: ["333": "Scene"])
    try await signIn(panel)
    let gate = Gate()
    let held = Task { await panel.store.commands.run { await gate.wait() } }
    try await waitFor { panel.store.commands.isBusy }
    let subscribed = panel.controller.launch("subscribed") {
      try await panel.controller.downloadSubscribedWorkshopItems()
    }
    // Steam is read while another command holds the queue; only the requests wait for it.
    try await waitFor { !panel.store.commands.waiting.isEmpty }
    XCTAssertTrue(panel.workshop.downloadRequests.isEmpty, "the requests wait their turn")
    await gate.open()
    _ = await held.value
    await subscribed.value
    XCTAssertEqual(panel.workshop.downloadRequests.map(\.id), ["333"])
  }
}

private actor Gate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    isOpen = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
}

/// Steam: the subscriptions profile page of one account, and the details of any item asked about.
private final class SubscriptionsProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var subscribed: [String: String] = [:]

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let body = Self.body(for: url, request: request) else {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    client?.urlProtocol(
      self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}

  private static func body(for url: URL, request: URLRequest) -> Data? {
    if url.host == "steamcommunity.com", url.path.contains("myworkshopfiles") {
      // Without the session cookie Steam shows its sign-in page.
      guard request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("steamLoginSecure=") == true else {
        return Data("<html><head><title>Sign In</title></head><body></body></html>".utf8)
      }
      let rows = subscribed.keys.sorted().map {
        "<div class=\"workshopItemSubscription \" id=\"Subscription\($0)\"></div>"
      }.joined()
      let count = subscribed.count
      return Data("<html><head><title>Steam Community</title></head><body>\(rows)Showing 1-\(count) of \(count) entries</body></html>".utf8)
    }
    if url.host == "api.steampowered.com", url.path.contains("/ISteamRemoteStorage/GetPublishedFileDetails/") {
      let stream = request.httpBodyStream
      var data = request.httpBody ?? Data()
      if data.isEmpty, let stream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
          let count = stream.read(&buffer, maxLength: buffer.count)
          if count <= 0 { break }
          data.append(buffer, count: count)
        }
      }
      let ids = String(decoding: data, as: UTF8.self).split(separator: "&").compactMap { field -> String? in
        let pair = field.split(separator: "=", maxSplits: 1)
        return pair.count == 2 && pair[0].hasPrefix("publishedfileids[") ? String(pair[1]) : nil
      }
      let rows: [[String: Any]] = ids.map { id in
        [
          "publishedfileid": id, "result": 1, "consumer_app_id": WorkshopApp.id, "title": "W\(id)",
          "tags": [["tag": subscribed[id] ?? "Video"]], "file_size": "2048", "subscriptions": 3,
          "time_updated": 1_700_000_000,
        ]
      }
      return try? JSONSerialization.data(
        withJSONObject: ["response": ["result": 1, "resultcount": rows.count, "publishedfiledetails": rows]])
    }
    return nil
  }
}
