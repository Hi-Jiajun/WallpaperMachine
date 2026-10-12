import XCTest

@testable import WallpaperMachine

final class LockScreenExtensionRegistrationTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Caches/extension-registration-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: root)
  }

  private func makeApp(_ name: String, identifier: String = "app.wallpapermachine") throws -> URL {
    let app = root.appendingPathComponent(name + ".app")
    let ext = app.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    for (bundle, id, executable) in [
      (app, identifier, "WallpaperMachine"),
      (ext, LockScreenConfiguration.extensionIdentifier, "WallpaperMachineExtension"),
    ] {
      let contents = bundle.appendingPathComponent("Contents")
      let binary = contents.appendingPathComponent("MacOS/" + executable)
      try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
      try PropertyListSerialization.data(fromPropertyList: [
        "CFBundleIdentifier": id, "CFBundleExecutable": executable,
        "CFBundlePackageType": bundle.pathExtension == "app" ? "APPL" : "XPC!",
      ], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
      try Data().write(to: binary)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }
    return app
  }

  private func registration(
    _ app: URL, registry: Registry, processes: LockScreenExtensionProcesses = .inert,
    timeline: Timeline? = nil
  ) -> LockScreenExtensionRegistration {
    LockScreenExtensionRegistration(
      currentAppURL: app,
      command: { tool, arguments in
        timeline?.add("registry")
        return try await registry.run(tool, arguments)
      },
      processes: processes)
  }

  /// The table's processes, with every signal noted on the timeline next to registry commands.
  private func recording(_ table: FakeExtensionProcessTable, on timeline: Timeline) -> LockScreenExtensionProcesses {
    var processes = table.processes
    let signal = processes.signal
    processes.signal = { process, number in
      timeline.add("signal")
      return signal(process, number)
    }
    return processes
  }

  func testSoleCurrentRegistrationIsIdempotentWithoutMutations() async throws {
    let app = try makeApp("Current")
    let ext = app.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let registry = Registry(paths: [ext])
    let service = registration(app, registry: registry)
    try await service.prepare()
    try await service.prepare()
    let state = await registry.state()
    XCTAssertEqual(state.paths, [ext])
    XCTAssertTrue(state.commands.allSatisfy { $0.arguments.first == "-m" })
  }

  func testOtherCopiesAreUnregisteredButTheirBundlesStayIntact() async throws {
    let app = try makeApp("Release/WallpaperMachine")
    let old = try makeApp("work tree/调试 (copy)/WallpaperMachine")
    let gone = root.appendingPathComponent("Removed.app/" + LockScreenExtensionRegistration.extensionPath)
    let intended = app.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let duplicate = old.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let registry = Registry(paths: [duplicate, gone, intended])
    try await registration(app, registry: registry).prepare()
    let state = await registry.state()
    XCTAssertEqual(state.paths, [intended])
    let mutations = state.commands.filter { $0.arguments.first != "-m" }
    XCTAssertEqual(mutations.prefix(2).map(\.arguments), [["-f", app.path], ["-a", intended.path]])
    XCTAssertEqual(Set(mutations.filter { $0.arguments.first == "-r" }.map { $0.arguments[1] }),
      Set([duplicate.path, gone.path]))
    XCTAssertEqual(mutations.filter { $0.arguments.first == "-u" }.map(\.arguments), [["-u", old.path]])
    XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("Contents/Info.plist").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: duplicate.appendingPathComponent("Contents/MacOS/WallpaperMachineExtension").path))
    XCTAssertEqual(state.commands.last?.arguments.first, "-m", "Re-query the registry before claiming success")
  }

  func testUnregisteredCurrentAppIsAdded() async throws {
    let app = try makeApp("Current")
    let registry = Registry(paths: [])
    try await registration(app, registry: registry).prepare()
    let state = await registry.state()
    XCTAssertEqual(state.paths, [app.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)])
    XCTAssertFalse(state.commands.contains { ["-r", "-u"].contains($0.arguments[0]) })
  }

  func testParentUnregistrationMayAlreadyRemoveTheExtension() async throws {
    let current = try makeApp("Current")
    let other = try makeApp("Other")
    let registry = Registry(paths: [other.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)],
      failureFlag: "-r", removeWithParent: true)
    try await registration(current, registry: registry).prepare()
    let state = await registry.state()
    XCTAssertEqual(state.paths, [current.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)])
    XCTAssertEqual(state.commands.last?.arguments.first, "-m")
  }

  func testInvalidCurrentBundleCannotUnregisterWorkingCopies() async throws {
    let current = try makeApp("Current", identifier: "unrelated.app")
    let other = try makeApp("Other")
    let registry = Registry(paths: [other.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)])
    do {
      try await registration(current, registry: registry).prepare()
      XCTFail("An invalid current bundle must fail")
    } catch { XCTAssertTrue(error is LockScreenWallpaperFailure) }
    let state = await registry.state()
    XCTAssertTrue(state.commands.isEmpty)
  }

  func testAnUnrelatedBundleAtAStalePathIsNeverUnregistered() async throws {
    let current = try makeApp("Current")
    let other = try makeApp("Other", identifier: "unrelated.app")
    let registry = Registry(paths: [other.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)])
    do {
      try await registration(current, registry: registry).prepare()
      XCTFail("A stale path occupied by another app must fail safely")
    } catch { XCTAssertTrue(error is LockScreenWallpaperFailure) }
    let state = await registry.state()
    XCTAssertTrue(state.commands.allSatisfy { $0.arguments.first == "-m" })
  }

  func testSymlinkAliasOfCurrentBundleIsNotRemoved() async throws {
    let app = try makeApp("Current")
    let alias = root.appendingPathComponent("Alias.app")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
    let registry = Registry(paths: [alias.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)])
    try await registration(app, registry: registry).prepare()
    let state = await registry.state()
    XCTAssertTrue(state.commands.allSatisfy { $0.arguments.first == "-m" })
  }

  func testSuccessfulCommandsDoNotHideAnUnresolvedConflict() async throws {
    let current = try makeApp("Current")
    let other = try makeApp("Other")
    let registry = Registry(paths: [other.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)], ignoreRemoval: true)
    do {
      try await registration(current, registry: registry).prepare()
      XCTFail("The registration must actually converge")
    } catch { XCTAssertTrue(error is LockScreenWallpaperFailure) }
    let state = await registry.state()
    XCTAssertEqual(state.paths.count, 2)
    XCTAssertEqual(state.commands.filter { $0.arguments.first == "-r" }.count, 1, "Do not loop on mutations")
  }

  func testFailureRegisteringCurrentCopyLeavesOthersRegistered() async throws {
    let current = try makeApp("Current")
    let other = try makeApp("Other")
    let ext = other.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let registry = Registry(paths: [ext], failureFlag: "-a")
    do {
      try await registration(current, registry: registry).prepare()
      XCTFail("Registration failure must reach the caller")
    } catch { XCTAssertTrue(error is LockScreenWallpaperFailure) }
    let state = await registry.state()
    XCTAssertEqual(state.paths, [ext])
    XCTAssertFalse(state.commands.contains { ["-r", "-u"].contains($0.arguments[0]) })
  }

  func testCancellationDoesNotRemoveOtherCopiesOrBecomeAUserError() async throws {
    let current = try makeApp("Current")
    let registry = Registry(paths: [], failureFlag: "-a", cancel: true)
    do {
      try await registration(current, registry: registry).prepare()
      XCTFail("Cancellation must propagate")
    } catch { XCTAssertTrue(error is CancellationError) }
    let state = await registry.state()
    XCTAssertFalse(state.commands.contains { ["-r", "-u"].contains($0.arguments[0]) })
  }

  func testPrepareEndsStaleProcessesOnlyAfterTheRegistryConverges() async throws {
    let app = try makeApp("Current")
    let old = try makeApp("Old")
    let intended = app.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let oldExtension = old.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)

    // Once through the idempotent early return and once through a real reconciliation.
    for registered in [[intended], [oldExtension]] {
      let timeline = Timeline()
      let table = FakeExtensionProcessTable([
        FakeExtensionProcessTable.process(1, bundle: oldExtension.path),
        FakeExtensionProcessTable.process(2, bundle: intended.path),
      ])
      let registry = Registry(paths: registered)
      try await registration(app, registry: registry, processes: recording(table, on: timeline), timeline: timeline)
        .prepare()

      // Only the process of the other copy goes: the intended copy's own helper is untouched,
      // which also shows the intended extension, not the app, was the copy kept.
      XCTAssertEqual(table.signals, [.init(pid: 1, number: SIGTERM)])
      let events = timeline.events
      XCTAssertGreaterThan(
        try XCTUnwrap(events.firstIndex(of: "signal")), try XCTUnwrap(events.lastIndex(of: "registry")),
        "A process may only be ended after the registry was confirmed to name the intended copy")
      let state = await registry.state()
      XCTAssertEqual(state.paths, [intended])
    }
  }

  func testPrepareEndsTheHelperOfAnUpdatedAppThatNoLongerHasFiles() async throws {
    // The in-app updater replaces the app and deletes the old copy, so its helper keeps
    // running with no path. It goes because it runs another build than the registered one.
    let app = try makeApp("Current")
    let intended = app.resolvingSymlinksInPath().standardizedFileURL
      .appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let old = UUID()
    let current = UUID()
    let table = FakeExtensionProcessTable([
      FakeExtensionProcessTable.deletedProcess(1, image: old),
      FakeExtensionProcessTable.deletedProcess(2, image: current),
    ])
    table.setImages([current], for: LockScreenExtensionProcesses.executable(in: intended))
    try await registration(app, registry: Registry(paths: [intended]), processes: table.processes).prepare()
    XCTAssertEqual(table.signals, [.init(pid: 1, number: SIGTERM)])
  }

  func testFailedRegistrationNeverTerminatesAnything() async throws {
    let current = try makeApp("Current")
    let invalid = try makeApp("Invalid", identifier: "unrelated.app")
    let other = try makeApp("Other")
    let otherExtension = other.appendingPathComponent(LockScreenExtensionRegistration.extensionPath)
    let cases: [(String, URL, Registry)] = [
      ("invalid current bundle", invalid, Registry(paths: [otherExtension])),
      ("unresolved conflict", current, Registry(paths: [otherExtension], ignoreRemoval: true)),
      ("cancellation", current, Registry(paths: [], failureFlag: "-a", cancel: true)),
      ("command failure", current, Registry(paths: [], failureFlag: "-a")),
    ]
    for (name, app, registry) in cases {
      let table = FakeExtensionProcessTable([
        FakeExtensionProcessTable.process(1, bundle: otherExtension.path)
      ])
      do {
        try await registration(app, registry: registry, processes: table.processes).prepare()
        XCTFail("\(name) must fail")
      } catch {}
      XCTAssertTrue(table.signals.isEmpty, name)
      XCTAssertEqual(table.lists, 0, "\(name): the process table must not even be read")
    }
  }

  func testDiscoveryParsesVersionsFlagsSpacesAndUnicodeWithoutDroppingCopies() throws {
    let paths = ["/Applications/WallpaperMachine.app", "/a b/调试 (new).app"].map {
      URL(fileURLWithPath: $0 + "/" + LockScreenExtensionRegistration.extensionPath)
    }
    let output = Registry.output(paths).replacingOccurrences(of: "     app.", with: "=    app.")
      .replacingOccurrences(of: "(1.2.5)", with: "(99.2.5)")
    XCTAssertEqual(Set(try LockScreenExtensionRegistration.parseRegistrations(output)), Set(paths))
    XCTAssertEqual(try LockScreenExtensionRegistration.parseRegistrations("  (no matches)\n"), [])
    XCTAssertEqual(try LockScreenExtensionRegistration.parseRegistrations(Registry.output([paths[0]])), [paths[0]])
  }

  func testEmptyTruncatedAndForeignDiscoveryOutputIsRejected() throws {
    let output = Registry.output([URL(fileURLWithPath: "/Applications/A.app/" + LockScreenExtensionRegistration.extensionPath)])
    for invalid in ["", "pkd unavailable", output.replacingOccurrences(of: " (1 plug-in)\n", with: ""),
      output.replacingOccurrences(of: "(1 plug-in)", with: "(2 plug-ins)"),
      output.replacingOccurrences(of: LockScreenConfiguration.extensionIdentifier, with: "unrelated.extension")] {
      XCTAssertThrowsError(try LockScreenExtensionRegistration.parseRegistrations(invalid))
    }
  }

  private final class Timeline: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] { lock.withLock { recorded } }
    func add(_ event: String) { lock.withLock { recorded.append(event) } }
  }

  private actor Registry {
    struct Command { var tool: String; var arguments: [String] }
    private var paths: [URL]
    private var commands: [Command] = []
    private let ignoreRemoval: Bool
    private let failureFlag: String?
    private let cancel: Bool
    private let removeWithParent: Bool

    init(paths: [URL], ignoreRemoval: Bool = false, failureFlag: String? = nil,
      cancel: Bool = false, removeWithParent: Bool = false) {
      self.paths = paths
      self.ignoreRemoval = ignoreRemoval
      self.failureFlag = failureFlag
      self.cancel = cancel
      self.removeWithParent = removeWithParent
    }

    func state() -> (paths: [URL], commands: [Command]) { (paths, commands) }

    func run(_ tool: URL, _ arguments: [String]) throws -> String {
      commands.append(Command(tool: tool.lastPathComponent, arguments: arguments))
      if arguments.first == failureFlag {
        if cancel { throw CancellationError() }
        throw NSError(domain: "registration-command", code: 1)
      }
      switch (tool.lastPathComponent, arguments[0]) {
      case ("pluginkit", "-m"): return Self.output(paths)
      case ("pluginkit", "-a"):
        let url = URL(fileURLWithPath: arguments[1])
        if !paths.contains(url) { paths.append(url) }
      case ("pluginkit", "-r"):
        if !ignoreRemoval { paths.removeAll { $0.path == arguments[1] } }
      case ("lsregister", "-u"):
        if removeWithParent { paths.removeAll { $0.path.hasPrefix(arguments[1] + "/") } }
      case ("lsregister", "-f"): break
      default: XCTFail("Unexpected mutation: \(tool.path) \(arguments)")
      }
      return ""
    }

    nonisolated static func output(_ paths: [URL]) -> String {
      if paths.isEmpty { return "  (no matches)\n" }
      return paths.map {
        "     \(LockScreenConfiguration.extensionIdentifier)(1.2.5)\t855441FD-9FFC-4FAA-A50F-5F5B50701AFD\t2026-10-05 06:06:07 +0000\t\($0.path)\n"
      }.joined() + " (\(paths.count) plug-in\(paths.count == 1 ? "" : "s"))\n"
    }
  }
}
