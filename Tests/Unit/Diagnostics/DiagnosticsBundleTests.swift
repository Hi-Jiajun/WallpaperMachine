import XCTest

@testable import WallpaperMachine

final class DiagnosticsBundleTests: XCTestCase {
    private var root: URL!
    private let exportedAt = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "diagnostics-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testNewestSessionsKeepNumericSuffixOrder() throws {
        let logs = try makeLogs([
            "20260927-150000": ["0.log": "oldest"],
            "20260927-150200": ["0.log": "base"],
            "20260927-150200-1": ["0.log": "one"],
            "20260927-150200-9": ["0.log": "nine"],
            "20260927-150200-10": ["0.log": "ten"],
        ])
        let bundle = makeBundle(logs: logs, limits: limits(sessions: 2))
        let exported = try export(bundle)
        XCTAssertEqual(Set(logSessions(in: exported.report)), ["20260927-150200-10", "20260927-150200-9"])
        XCTAssertTrue(exported.report.missing.contains { $0.contains("20260927-150200-1") && $0.contains("omitted") })
        XCTAssertTrue(exported.report.missing.contains { $0.contains("20260927-150000") && $0.contains("omitted") })
        XCTAssertFalse(exported.report.included.contains { $0.contains("20260927-150200/") })
    }

    func testByteBudgetKeepsNewestTailAndNotesTheRest() throws {
        let logs = try makeLogs([
            "20260927-100000": ["0.log": "old\n"],
            "20260927-120000": ["0.log": "older-file\n", "1.log": "AAAA\nBBBB\nCCCC\n"],
        ])
        var limits = DiagnosticsBundle.Limits()
        limits.sessions = 5
        limits.logBytes = 8
        let bundle = makeBundle(logs: logs, limits: limits)
        let exported = try export(bundle)
        let newest = try text(exported, "logs/20260927-120000/1.log")
        XCTAssertEqual(newest, "[truncated: first 10 bytes omitted]\nCCCC\n")
        XCTAssertFalse(exported.report.included.contains("logs/20260927-120000/0.log"))
        XCTAssertFalse(exported.report.included.contains("logs/20260927-100000/0.log"))
        XCTAssertTrue(exported.report.missing.contains("logs/20260927-120000/0.log omitted: log size limit reached"))
        XCTAssertTrue(exported.report.missing.contains("logs/20260927-100000/0.log omitted: log size limit reached"))
    }

    func testTailThatStartsOnALineBoundaryKeepsThatLine() throws {
        let logs = try makeLogs(["20260927-120000": ["0.log": "AAAA\nBBBB\n"]])
        var limits = DiagnosticsBundle.Limits()
        limits.logBytes = 5
        let exported = try export(makeBundle(logs: logs, limits: limits))
        XCTAssertEqual(try text(exported, "logs/20260927-120000/0.log"), "[truncated: first 5 bytes omitted]\nBBBB\n")
    }

    func testCrashReportsAreFilteredByPrefixAgeAndCount() throws {
        let crashes = root.appendingPathComponent("crashes", isDirectory: true)
        try FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
        let age: TimeInterval = 14 * 24 * 60 * 60
        try writeCrash("WallpaperMachine-new.ips", at: exportedAt.addingTimeInterval(-3600), body: "path /Users/alice/Library", in: crashes)
        try writeCrash("WallpaperMachineExtension-older.ips", at: exportedAt.addingTimeInterval(-7200), body: "extension", in: crashes)
        try writeCrash("OtherApp-new.ips", at: exportedAt.addingTimeInterval(-60), body: "other", in: crashes)
        try writeCrash("WallpaperMachine-old.ips", at: exportedAt.addingTimeInterval(-(age + 60)), body: "stale", in: crashes)
        try writeCrash("WallpaperMachine-future.ips", at: exportedAt.addingTimeInterval(3600), body: "future", in: crashes)
        try writeCrash("WallpaperMachine.txt", at: exportedAt.addingTimeInterval(-60), body: "not ips", in: crashes)

        var limits = DiagnosticsBundle.Limits()
        limits.crashReports = 1
        limits.crashReportAge = age
        let logs = try makeLogs(["20260927-120000": ["0.log": "ok\n"]])
        let exported = try export(makeBundle(logs: logs, crashes: crashes, limits: limits))
        let includedCrashes = exported.report.included.filter { $0.hasPrefix("crash-reports/") }
        XCTAssertEqual(includedCrashes, ["crash-reports/WallpaperMachine-new.ips"])
        XCTAssertEqual(try text(exported, "crash-reports/WallpaperMachine-new.ips"), "path ~/Library")
        XCTAssertFalse(exported.report.missing.contains("no crash reports in the last 14 days"))
    }

    func testNoRecentCrashReportsAreNoted() throws {
        let logs = try makeLogs(["20260927-120000": ["0.log": "ok\n"]])
        let crashes = root.appendingPathComponent("empty-crashes", isDirectory: true)
        try FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
        try writeCrash("WallpaperMachine-old.ips", at: exportedAt.addingTimeInterval(-(15 * 24 * 60 * 60)), body: "stale", in: crashes)
        let exported = try export(makeBundle(logs: logs, crashes: crashes))
        XCTAssertTrue(exported.report.missing.contains("no crash reports in the last 14 days"))
        XCTAssertFalse(exported.report.included.contains { $0.hasPrefix("crash-reports/") })
    }

    func testMissingExtensionLogIsNotedAndZipContainsTheRest() throws {
        let logs = try makeLogs(["20260927-120000": ["0.log": "hello /Users/alice\n"]])
        let destination = root.appendingPathComponent("out.zip")
        try Data("previous".utf8).write(to: destination)
        let bundle = makeBundle(logs: logs, extensionLog: root.appendingPathComponent("missing-extension.log"))
        let report = try bundle.export(
            to: destination,
            environment: ["HOME=/Users/alice", "USER=alice"],
            at: exportedAt)
        XCTAssertTrue(report.missing.contains("lock-screen/extension.log was not readable"))
        XCTAssertFalse(report.included.contains("lock-screen/extension.log"))
        XCTAssertFalse(
            report.missing.contains { $0.hasPrefix("load-journal.json") },
            "a caller with no journal source gets no note about one")
        XCTAssertEqual(report.included, report.included.sorted())
        XCTAssertTrue(report.included.contains("logs/20260927-120000/0.log"))
        XCTAssertTrue(report.included.contains("environment.txt"))
        XCTAssertTrue(report.included.contains("README.txt"))

        let extracted = try unzip(destination)
        XCTAssertEqual(try Data(contentsOf: extracted.appending(path: "logs/20260927-120000/0.log")), Data("hello ~\n".utf8))
        XCTAssertEqual(try Data(contentsOf: extracted.appending(path: "environment.txt")), Data("HOME=~\nUSER=<user>\n".utf8))
        let readme = try String(contentsOf: extracted.appendingPathComponent("README.txt"), encoding: .utf8)
        let generated = ISO8601DateFormatter().string(from: exportedAt)
        XCTAssertTrue(readme.contains(generated))
        XCTAssertTrue(readme.contains("logs/20260927-120000/0.log"))
        XCTAssertTrue(readme.contains("lock-screen/extension.log was not readable"))
        XCTAssertNotEqual(try Data(contentsOf: destination), Data("previous".utf8))
    }

    func testLoadJournalIsIncludedAndRedacted() throws {
        let logs = try makeLogs(["20260927-120000": ["0.log": "ok\n"]])
        let journal = root.appendingPathComponent("load-journal.json")
        let body = """
            {"version":1,"build":"1.3.2 (45)","session":"9f3a6c0d2b81e475",\
            "strikes":{"3177024520":{"count":1,"last_at":1791800000,"display":7}},\
            "in_flight":[],"note":"/Users/alice/Library/Application Support/WallpaperMachine"}
            """
        try Data(body.utf8).write(to: journal)

        let exported = try export(makeBundle(logs: logs, loadJournal: journal))
        XCTAssertTrue(exported.report.included.contains("load-journal.json"))
        XCTAssertFalse(exported.report.missing.contains { $0.hasPrefix("load-journal.json") })

        let written = try text(exported, "load-journal.json")
        XCTAssertTrue(written.contains("~/Library/Application Support/WallpaperMachine"))
        XCTAssertFalse(written.contains("alice"))
        let parsed = try JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any]
        let strikes = parsed?["strikes"] as? [String: [String: Any]]
        XCTAssertEqual(strikes?["3177024520"]?["count"] as? Int, 1, "the strike history survives redaction")
        XCTAssertTrue(try text(exported, "README.txt").contains("load-journal.json"))
    }

    func testMissingLoadJournalIsNotedAndTheRestIsStillExported() throws {
        let logs = try makeLogs(["20260927-120000": ["0.log": "ok\n"]])
        let journal = root.appendingPathComponent("never-written/load-journal.json")

        let exported = try export(makeBundle(logs: logs, loadJournal: journal))
        XCTAssertEqual(exported.report.missing.filter { $0.hasPrefix("load-journal.json") }, ["load-journal.json was not present"])
        XCTAssertFalse(exported.report.included.contains("load-journal.json"))
        XCTAssertTrue(exported.report.included.contains("logs/20260927-120000/0.log"))
        XCTAssertTrue(exported.report.included.contains("environment.txt"))
        XCTAssertTrue(try text(exported, "README.txt").contains("load-journal.json was not present"))
    }

    func testUnreadableLoadJournalIsNotedDifferentlyFromAnAbsentOne() throws {
        let logs = try makeLogs(["20260927-120000": ["0.log": "ok\n"]])
        let journal = root.appendingPathComponent("load-journal.json", isDirectory: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)

        let exported = try export(makeBundle(logs: logs, loadJournal: journal))
        XCTAssertEqual(exported.report.missing.filter { $0.hasPrefix("load-journal.json") }, ["load-journal.json was not readable"])
        XCTAssertFalse(exported.report.included.contains("load-journal.json"))
        XCTAssertTrue(exported.report.included.contains("logs/20260927-120000/0.log"))
    }

    func testSuggestedFileNameUsesLocalPOSIXTime() {
        let name = DiagnosticsBundle.suggestedFileName(at: exportedAt)
        XCTAssertTrue(name.hasPrefix("WallpaperMachine-diagnostics-"))
        XCTAssertTrue(name.hasSuffix(".zip"))
        let stamp = name.dropFirst("WallpaperMachine-diagnostics-".count).dropLast(".zip".count)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        XCTAssertEqual(String(stamp), formatter.string(from: exportedAt))
    }

    /// Reading the extension's own container would make macOS ask for access to
    /// another app's data; its log lives in the shared exchange directory instead.
    func testSourcesUseTheLockScreenExchangeAndDiagnosticReports() {
        let home = root.appendingPathComponent("home")
        let logs = root.appendingPathComponent("logs")
        let support = root.appendingPathComponent("support")
        let sources = DiagnosticsBundle.sources(logsRoot: logs, home: home, supportRoot: support)
        XCTAssertEqual(sources.logsRoot.standardizedFileURL, logs.standardizedFileURL)
        XCTAssertEqual(
            sources.extensionLog.standardizedFileURL,
            home.appending(path: "Library/Application Support/WallpaperMachine/LockScreenExchange/extension.log").standardizedFileURL)
        XCTAssertEqual(
            sources.crashReports.standardizedFileURL,
            home.appending(path: "Library/Logs/DiagnosticReports").standardizedFileURL)
        XCTAssertEqual(sources.loadJournal?.standardizedFileURL, support.appending(path: "load-journal.json").standardizedFileURL)
    }

    private struct Exported {
        var report: DiagnosticsBundle.Report
        var root: URL
    }

    private func limits(sessions: Int) -> DiagnosticsBundle.Limits {
        var limits = DiagnosticsBundle.Limits()
        limits.sessions = sessions
        return limits
    }

    private func makeBundle(
        logs: URL,
        extensionLog: URL? = nil,
        crashes: URL? = nil,
        loadJournal: URL? = nil,
        limits: DiagnosticsBundle.Limits = DiagnosticsBundle.Limits()
    ) -> DiagnosticsBundle {
        DiagnosticsBundle(
            sources: DiagnosticsBundle.Sources(
                logsRoot: logs,
                extensionLog: extensionLog ?? root.appendingPathComponent("absent-extension.log"),
                crashReports: crashes ?? root.appendingPathComponent("absent-crashes"),
                loadJournal: loadJournal),
            limits: limits,
            redactor: DiagnosticsRedactor(homeDirectory: "/Users/alice", userNames: ["alice"], secrets: ["steamalice"]))
    }

    private func makeLogs(_ sessions: [String: [String: String]]) throws -> URL {
        let logs = root.appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        for (session, files) in sessions {
            let directory = logs.appendingPathComponent(session, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, body) in files {
                try Data(body.utf8).write(to: directory.appendingPathComponent(name))
            }
        }
        return logs
    }

    private func writeCrash(_ name: String, at date: Date, body: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func export(_ bundle: DiagnosticsBundle) throws -> Exported {
        let destination = root.appendingPathComponent("export-\(UUID().uuidString).zip")
        let report = try bundle.export(to: destination, environment: ["USER=alice"], at: exportedAt)
        return Exported(report: report, root: try unzip(destination))
    }

    private func text(_ exported: Exported, _ path: String) throws -> String {
        try String(contentsOf: exported.root.appending(path: path), encoding: .utf8)
    }

    private func logSessions(in report: DiagnosticsBundle.Report) -> [String] {
        report.included.compactMap { path in
            let parts = path.split(separator: "/")
            guard parts.count == 3, parts[0] == "logs" else { return nil }
            return String(parts[1])
        }
    }

    private func unzip(_ zip: URL) throws -> URL {
        let destination = root.appendingPathComponent("unzip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, destination.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let stem = DiagnosticsBundle.suggestedFileName(at: exportedAt).replacingOccurrences(of: ".zip", with: "")
        return destination.appendingPathComponent(stem, isDirectory: true)
    }
}
