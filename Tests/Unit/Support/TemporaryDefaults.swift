import Foundation
import XCTest

/// Preferences suites that leave nothing in `~/Library/Preferences`.
///
/// Removing a named suite's persistent domain is not enough: cfprefsd flushes the
/// removal asynchronously and writes an empty `<suite>.plist`, even when the test
/// deletes that file right away. A suite named by an absolute path keeps its plist in
/// that path's directory instead, and cfprefsd does not recreate a deleted directory,
/// so removing the domain and then the directory leaves no file behind.
enum TemporaryDefaults {
  /// A path-backed suite in a fresh temporary directory, removed when `test` ends.
  static func make(for test: XCTestCase) throws -> (defaults: UserDefaults, suite: String) {
    let suite = try makeSuite()
    test.addTeardownBlock { remove(suite) }
    return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
  }

  /// A path-backed suite removed when the running test case finishes, for fixtures
  /// that are built outside an `XCTestCase` and cannot register a teardown block.
  static func makeForCurrentTest() -> (defaults: UserDefaults, suite: String) {
    let suite = try! makeSuite()
    Cleanup.shared.track(suite)
    return (UserDefaults(suiteName: suite)!, suite)
  }

  private static func makeSuite() throws -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WallpaperMachine-defaults-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("defaults").path
  }

  fileprivate static func remove(_ suite: String) {
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: suite).deletingLastPathComponent())
  }

  /// Removes tracked suites after each test case, and any stragglers when the bundle ends.
  private final class Cleanup: NSObject, XCTestObservation {
    static let shared = Cleanup()
    private let lock = NSLock()
    private var suites: [String] = []
    private var observing = false

    func track(_ suite: String) {
      lock.lock()
      suites.append(suite)
      let register = !observing
      observing = true
      lock.unlock()
      if register { XCTestObservationCenter.shared.addTestObserver(self) }
    }

    func testCaseDidFinish(_ testCase: XCTestCase) { removeAll() }
    func testBundleDidFinish(_ testBundle: Bundle) { removeAll() }

    private func removeAll() {
      lock.lock()
      let finished = suites
      suites.removeAll()
      lock.unlock()
      finished.forEach(TemporaryDefaults.remove)
    }
  }
}
