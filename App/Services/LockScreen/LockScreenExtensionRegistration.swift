import Foundation

/// Reconciles this user's registrations only when native presentation is activated.
/// Other app bundles stay on disk and can register themselves again when launched.
actor LockScreenExtensionRegistration {
  static let extensionPath = "Contents/Extensions/WallpaperMachineExtension.appex"
  private static let appIdentifier = "app.wallpapermachine"
  private static let pluginKit = URL(fileURLWithPath: "/usr/bin/pluginkit")
  private static let launchServices = URL(fileURLWithPath:
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")

  private let app: URL
  private let command: @Sendable (URL, [String]) async throws -> String
  private let processes: LockScreenExtensionProcesses

  /// `processes` defaults to inert: unit tests run inside the real app, where a live default
  /// would end the developer's installed extension. The app passes `.live`.
  init(
    currentAppURL: URL = Bundle.main.bundleURL,
    command: @escaping @Sendable (URL, [String]) async throws -> String = {
      try await LockScreenExtensionRegistration.runCommand($0, $1)
    },
    processes: LockScreenExtensionProcesses = .inert
  ) {
    app = currentAppURL.resolvingSymlinksInPath().standardizedFileURL
    self.command = command
    self.processes = processes
  }

  /// Registers this app's extension, then ends helpers that cannot serve it. Ending them is
  /// only safe once the registry names the intended copy, and never follows a failure.
  func prepare() async throws {
    let intended = try await reconcile()
    try Task.checkCancellation()
    await processes.terminateStale(expected: intended)
  }

  private func reconcile() async throws -> URL {
    do {
      try Task.checkCancellation()
      let intended = app.appendingPathComponent(Self.extensionPath)
      guard app.pathExtension == "app",
        Bundle(url: app)?.bundleIdentifier == Self.appIdentifier,
        Bundle(url: intended)?.bundleIdentifier == LockScreenConfiguration.extensionIdentifier,
        let executable = Bundle(url: intended)?.executableURL,
        FileManager.default.isExecutableFile(atPath: executable.path),
        intended.resolvingSymlinksInPath().path == intended.path
      else { throw Failure.invalidBundle }

      let registered = try await registrations()
      let others = registered.filter { !LockScreenExtensionDiagnostics.isSameBundle($0, intended) }
      if others.isEmpty, registered.contains(where: {
        LockScreenExtensionDiagnostics.isSameBundle($0, intended)
      }) { return intended }

      // Validate every target before making any change. A stale record for a removed app is
      // removable, but a path now occupied by an unrelated bundle must never be unregistered.
      let parents = try others.map { try Self.containingApp(for: $0) }
      AppLog.info("Native extension registration: selecting \(app.path), replacing \(others.count) other registration(s)")
      // Keep a valid intended registration even if a later command fails or is cancelled.
      try await run(Self.launchServices, ["-f", app.path])
      try await run(Self.pluginKit, ["-a", intended.path])
      for (other, parent) in zip(others, parents) {
        if FileManager.default.fileExists(atPath: parent.path) {
          // Removing only the appex lets its stale containing-app record rediscover it.
          try await run(Self.launchServices, ["-u", parent.path])
        }
        do {
          try await run(Self.pluginKit, ["-r", other.path])
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          // Unregistering the containing app can already have removed its extension.
          // Accept that only after observing its absence, never just from an exit code.
          let remaining = try await registrations()
          if remaining.contains(where: { LockScreenExtensionDiagnostics.isSameBundle($0, other) }) {
            throw error
          }
        }
      }
      // LaunchServices and pkd can finish propagating a change after the command exits.
      for attempt in 0..<5 {
        let remaining = try await registrations()
        if !remaining.isEmpty, remaining.allSatisfy({
          LockScreenExtensionDiagnostics.isSameBundle($0, intended)
        }) { return intended }
        if attempt < 4 { try await Task.sleep(for: .milliseconds(200)) }
      }
      throw Failure.conflictingRegistrations
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      AppLog.error("Native extension registration failed: \(error)")
      throw LockScreenWallpaperFailure(message: String(localized: "macOS could not register this app’s wallpaper renderer. Close other running copies of WallpaperMachine, then retry. If this persists, reinstall the app."))
    }
  }

  private func registrations() async throws -> [URL] {
    try Task.checkCancellation()
    return try Self.parseRegistrations(await command(Self.pluginKit, [
      "-m", "-A", "-D", "-v", "-i", LockScreenConfiguration.extensionIdentifier,
    ]))
  }

  private func run(_ executable: URL, _ arguments: [String]) async throws {
    try Task.checkCancellation()
    _ = try await command(executable, arguments)
  }

  /// The single-verbose format uses tabs before the path; spaces and Unicode in it are intact.
  /// Reject unfamiliar/truncated output instead of treating a partial inventory as success.
  static func parseRegistrations(_ output: String) throws -> [URL] {
    let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    if lines == ["(no matches)"] { return [] }
    var result: [URL] = []
    var reportedCount: Int?
    for line in lines {
      if line.hasPrefix("("), line.hasSuffix(" plug-ins)") || line.hasSuffix(" plug-in)") {
        guard reportedCount == nil else { throw Failure.invalidDiscovery }
        reportedCount = line.dropFirst().split(separator: " ").first.flatMap { Int($0) }
        continue
      }
      let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
      let identity = fields.first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "+-=!? ")) ?? ""
      guard reportedCount == nil, fields.count == 4,
        identity.hasPrefix(LockScreenConfiguration.extensionIdentifier + "("), identity.hasSuffix(")"),
        UUID(uuidString: String(fields[1])) != nil,
        fields[3].hasPrefix("/"), !fields[3].contains("\t"), !fields[3].contains("\r")
      else { throw Failure.invalidDiscovery }
      result.append(URL(fileURLWithPath: String(fields[3])).standardizedFileURL)
    }
    guard !result.isEmpty, reportedCount == result.count else { throw Failure.invalidDiscovery }
    return Array(Set(result)).sorted { $0.path < $1.path }
  }

  private static func containingApp(for extensionURL: URL) throws -> URL {
    let parent = extensionURL.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    guard parent.pathExtension == "app",
      parent.appendingPathComponent(extensionPath).path == extensionURL.path,
      extensionURL.resolvingSymlinksInPath().path
        == parent.resolvingSymlinksInPath().appendingPathComponent(extensionPath).path
    else { throw Failure.invalidBundle }
    for (url, identifier) in [(parent, appIdentifier), (extensionURL, LockScreenConfiguration.extensionIdentifier)] {
      if FileManager.default.fileExists(atPath: url.path), Bundle(url: url)?.bundleIdentifier != identifier {
        throw Failure.invalidBundle
      }
    }
    return parent
  }

  private enum Failure: Error {
    case invalidBundle, invalidDiscovery, conflictingRegistrations, timedOut, outputTooLarge
    case commandFailed(String, Int32, String)
  }

  /// Reuse the cancellable, reaping process runner; these local commands have a much shorter
  /// deadline than downloads. Argument arrays preserve paths without shell interpretation.
  private static func runCommand(_ executable: URL, _ arguments: [String]) async throws -> String {
    let output = Output()
    return try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        let status = try await SteamCMDProcessRunner().run(
          executable: executable, arguments: arguments,
          workingDirectory: URL(fileURLWithPath: "/"),
          environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"],
          onOutput: { output.append($0) })
        let text = try output.text()
        guard status == 0 else { throw Failure.commandFailed(executable.lastPathComponent, status, text) }
        return text
      }
      group.addTask {
        try await Task.sleep(for: .seconds(10))
        throw Failure.timedOut
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
  }

  private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var overflow = false

    func append(_ chunk: Data) {
      lock.withLock {
        if data.count + chunk.count > 1_048_576 { overflow = true }
        else { data.append(chunk) }
      }
    }

    func text() throws -> String {
      try lock.withLock {
        guard !overflow, let text = String(data: data, encoding: .utf8) else { throw Failure.outputTooLarge }
        return text
      }
    }
  }
}
