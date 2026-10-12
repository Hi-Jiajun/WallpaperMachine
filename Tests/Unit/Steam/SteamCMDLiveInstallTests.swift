import Darwin
import XCTest
@testable import WallpaperMachine

/// Opt-in, no-login install against Valve's CDN. All runtime and approval files stay temporary.
@MainActor
final class SteamCMDLiveInstallTests: XCTestCase {
    func testLiveNativePackageInstall() async throws {
        guard ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set WALLPAPER_MACHINE_NETWORK_TESTS=1 to install Valve's live runtime in temporary storage")
        }
        executionTimeAllowance = 660
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("SteamCMDLiveInstall-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try TemporaryDefaults.make(for: self).defaults
        defer { try? fm.removeItem(at: root) }
        let service = SteamCMDRuntimeService(approvalDirectory: root.appendingPathComponent("Approvals"))
        let downloader = WorkshopDownloader(sessionDirectory: root.appendingPathComponent("Session"), runtimeProvider: service)
        let runner = RecordingNativeRunner()
        let store = SteamCMDSetupStore(downloader: downloader, supportDirectory: root, defaults: defaults,
                                       runtimeProvider: service, processRunner: runner)
        store.install()
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        var previous: SteamCMDSetupState?
        while store.isBusy, ContinuousClock.now < deadline {
            if store.state != previous {
                if case .downloading = store.state {} else { print("Live SteamCMD: \(store.state)") }
                previous = store.state
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        await store.shutdown()
        await downloader.shutdown()
        XCTAssertEqual(store.state, .ready, "Live install must pass real signature, Gatekeeper and native smoke checks")
        let executable = try XCTUnwrap(store.selectedRuntime?.executableURL)
        // resolve refuses executables with no arm64 slice.
        XCTAssertEqual(try service.resolve(executable: executable).executableURL, executable)
        let smokePassed = await runner.smokePassed
        XCTAssertTrue(smokePassed, "Native Steam API initialization must succeed")
        XCTAssertTrue(fm.fileExists(atPath: executable.deletingLastPathComponent().appendingPathComponent("package/steam_cmd_osx.manifest").path))
    }
}

private actor RecordingNativeRunner: SteamCMDProcessRunning {
    private(set) var smokePassed = false
    func run(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String],
             onOutput: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        let output = NativeOutput()
        let status = try await SteamCMDProcessRunner().run(executable: executable, arguments: arguments,
            workingDirectory: workingDirectory, environment: environment, onOutput: {
                output.append($0)
                onOutput($0)
            })
        if executable.lastPathComponent == "steamcmd", arguments == ["-inhibitbootstrap", "+quit"] {
            smokePassed = status == 0 && output.text.contains("Loading Steam API...OK")
        }
        return status
    }
}

private final class NativeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) { lock.withLock { data.append(bytes.prefix(max(0, 65536 - data.count))) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
