import Foundation

/// A zip a user can attach to a bug report: recent logs, the lock-screen
/// extension log, the load journal, crash reports and the environment lines
/// they were asked for.
///
/// Synchronous and off the main actor. The caller decides where it runs.
/// Missing sources are notes in the report, not failures — a bug report with
/// no crash reports is still worth sending.
struct DiagnosticsBundle {
    struct Sources {
        var logsRoot: URL
        var extensionLog: URL
        var crashReports: URL
        /// The bridge's `load-journal.json` (see docs/features/crash-recovery.md).
        /// `nil` means the caller has no journal to offer, which is not noted.
        var loadJournal: URL? = nil
    }

    struct Limits {
        var sessions = 5
        var logBytes = 64 * 1024 * 1024
        var crashReports = 5
        var crashReportAge: TimeInterval = 14 * 24 * 60 * 60
    }

    struct Report: Equatable {
        var included: [String]
        var missing: [String]
    }

    var sources: Sources
    var limits = Limits()
    var redactor: DiagnosticsRedactor

    /// The file the bridge keeps beside `config.toml`.
    static let loadJournalFileName = "load-journal.json"

    static func sources(
        logsRoot: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        supportRoot: URL = ClientPaths.supportURL
    ) -> Sources {
        Sources(
            logsRoot: logsRoot,
            extensionLog: home.appending(path: LockScreenConfiguration.exchangeRelativePath).appending(path: "extension.log"),
            crashReports: home.appending(path: "Library/Logs/DiagnosticReports"),
            loadJournal: supportRoot.appending(path: loadJournalFileName))
    }

    /// Local time, POSIX locale, so the name sorts and does not pick up a
    /// 12-hour clock from the user's region.
    static func suggestedFileName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "WallpaperMachine-diagnostics-\(formatter.string(from: date)).zip"
    }

    func export(to destination: URL, environment: [String], at date: Date) throws -> Report {
        let stem = Self.stem(at: date)
        // The coordinated item has to be named the stem: that name is the
        // folder inside the zip. A unique parent keeps a second export in the
        // same second from sharing, or deleting, this staging directory.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-export-\(UUID().uuidString)", isDirectory: true)
        let staging = parent.appendingPathComponent(stem, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        var included: [String] = []
        var missing: [String] = []
        try collectLogs(into: staging, included: &included, missing: &missing)
        try collectExtensionLog(into: staging, included: &included, missing: &missing)
        try collectLoadJournal(into: staging, included: &included, missing: &missing)
        try collectCrashReports(into: staging, at: date, included: &included, missing: &missing)
        try write(
            redactor.redact(environment.joined(separator: "\n") + "\n"),
            to: staging.appendingPathComponent("environment.txt"))
        included.append("environment.txt")
        included.append("README.txt")
        included.sort()
        try write(readme(included: included, missing: missing, at: date), to: staging.appendingPathComponent("README.txt"))

        try zip(staging, to: destination)
        return Report(included: included, missing: missing.map { redactor.redact($0) })
    }

    private static func stem(at date: Date) -> String {
        let name = suggestedFileName(at: date)
        return name.hasSuffix(".zip") ? String(name.dropLast(4)) : name
    }

    private func collectLogs(into staging: URL, included: inout [String], missing: inout [String]) throws {
        let directories: [URL]
        do {
            directories = try FileManager.default.contentsOfDirectory(
                at: sources.logsRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [])
        } catch {
            missing.append("application logs were not readable")
            return
        }
        let sessions = directories.compactMap { url -> (url: URL, rank: SessionRank)? in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else { return nil }
            return (url, SessionRank(name: url.lastPathComponent))
        }.sorted { $0.rank > $1.rank }
        guard !sessions.isEmpty else {
            missing.append("no application log sessions")
            return
        }

        let chosen = sessions.prefix(max(limits.sessions, 0))
        for session in sessions.dropFirst(chosen.count) {
            missing.append("session \(session.rank.name) omitted: only the \(limits.sessions) newest sessions are included")
        }

        var budget = limits.logBytes
        for session in chosen {
            try collectSession(session.url, name: session.rank.name, budget: &budget, into: staging, included: &included, missing: &missing)
        }
    }

    private func collectSession(
        _ url: URL,
        name: String,
        budget: inout Int,
        into staging: URL,
        included: inout [String],
        missing: inout [String]
    ) throws {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [])) ?? []
        let logs = files.compactMap { file -> (url: URL, generation: Int)? in
            guard let generation = Self.logGeneration(file.lastPathComponent),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { return nil }
            return (file, generation)
        }.sorted { lhs, rhs in
            if lhs.generation != rhs.generation { return lhs.generation > rhs.generation }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
        for file in logs {
            let relative = "logs/\(name)/\(file.url.lastPathComponent)"
            if budget <= 0 {
                missing.append("\(relative) omitted: log size limit reached")
                continue
            }
            let slice: LogSlice
            do {
                slice = try Self.readLog(file.url, limit: budget)
            } catch {
                missing.append("\(relative) could not be read")
                continue
            }
            var text = redactor.redact(slice.text)
            if slice.omitted > 0 {
                text = "[truncated: first \(slice.omitted) bytes omitted]\n" + text
            }
            try write(text, to: staging.appending(path: relative))
            included.append(relative)
            budget = slice.omitted > 0 ? 0 : budget - slice.rawBytes
        }
    }

    private func collectExtensionLog(into staging: URL, included: inout [String], missing: inout [String]) throws {
        let relative = "lock-screen/extension.log"
        do {
            let data = try Data(contentsOf: sources.extensionLog)
            try write(redactor.redact(String(decoding: data, as: UTF8.self)), to: staging.appending(path: relative))
            included.append(relative)
        } catch {
            missing.append("\(relative) was not readable")
        }
    }

    /// Which wallpapers the app was opening when it died, and how often. Absent
    /// is normal: the file exists only once a scene has been opened, so it is a
    /// note, and the rest of the report is unaffected.
    private func collectLoadJournal(into staging: URL, included: inout [String], missing: inout [String]) throws {
        guard let source = sources.loadJournal else { return }
        let relative = Self.loadJournalFileName
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            let absent = (error as? CocoaError)?.code == .fileReadNoSuchFile
            missing.append("\(relative) was not \(absent ? "present" : "readable")")
            return
        }
        try write(redactor.redact(String(decoding: data, as: UTF8.self)), to: staging.appending(path: relative))
        included.append(relative)
    }

    private func collectCrashReports(
        into staging: URL,
        at date: Date,
        included: inout [String],
        missing: inout [String]
    ) throws {
        let cutoff = date.addingTimeInterval(-limits.crashReportAge)
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: sources.crashReports,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [])
        } catch {
            missing.append(crashReportWindowNote)
            return
        }
        let matches = files.compactMap { url -> (url: URL, modified: Date)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("WallpaperMachine"), url.pathExtension.lowercased() == "ips" else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff, modified <= date
            else { return nil }
            return (url, modified)
        }.sorted { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
        guard !matches.isEmpty else {
            missing.append(crashReportWindowNote)
            return
        }
        for report in matches.prefix(max(limits.crashReports, 0)) {
            let relative = "crash-reports/\(report.url.lastPathComponent)"
            do {
                let data = try Data(contentsOf: report.url)
                try write(redactor.redact(String(decoding: data, as: UTF8.self)), to: staging.appending(path: relative))
                included.append(relative)
            } catch {
                missing.append("\(relative) could not be read")
            }
        }
    }

    private var crashReportWindowNote: String {
        let days = Int(limits.crashReportAge / (24 * 60 * 60))
        return "no crash reports in the last \(days) days"
    }

    private func readme(included: [String], missing: [String], at date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let generated = formatter.string(from: date)
        let files = included.joined(separator: "\n")
        let absent = missing.isEmpty ? "(none)" : missing.joined(separator: "\n")
        return """
        Wallpaper Machine diagnostics
        Generated: \(generated)

        This archive is for a bug report. It holds the newest application log sessions that fit in the export limit, the lock-screen extension log, the load journal (which wallpapers the app was opening when it last quit unexpectedly), recent crash reports, and the environment lines supplied at export.

        Home folder paths were replaced with ~. The macOS user name was replaced with <user>. Steam account names were replaced with <account>.

        Included:
        \(files)

        Not included:
        \(absent)
        """
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Copy, don't move. The coordinator deletes its zip when the block
    /// returns, which would delete the destination if we had moved it there.
    private func zip(_ staging: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var placementError: Error?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordinationError) { temporaryZip in
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: temporaryZip, to: destination)
            } catch {
                placementError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let placementError { throw placementError }
    }

    /// `YYYYMMDD-HHMMSS` sorts chronologically. A same-second `-N` suffix sorts
    /// after the base name, and `-10` is newer than `-9`, which a plain string
    /// sort gets wrong.
    private struct SessionRank: Comparable {
        var recognized: Bool
        var stamp: String
        var generation: Int
        var name: String

        init(name: String) {
            self.name = name
            let parts = name.split(separator: "-", omittingEmptySubsequences: false)
            let dated = (parts.count == 2 || parts.count == 3)
                && Self.digits(parts[0], count: 8)
                && Self.digits(parts[1], count: 6)
                && (parts.count == 2 || Self.digits(parts[2], count: nil))
            if dated {
                recognized = true
                stamp = "\(parts[0])-\(parts[1])"
                generation = parts.count == 3 ? Int(parts[2]) ?? 0 : 0
            } else {
                recognized = false
                stamp = name
                generation = 0
            }
        }

        private static func digits(_ text: Substring, count: Int?) -> Bool {
            guard !text.isEmpty, count == nil || text.count == count else { return false }
            return text.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.recognized != rhs.recognized { return !lhs.recognized }
            if lhs.stamp != rhs.stamp { return lhs.stamp < rhs.stamp }
            if lhs.generation != rhs.generation { return lhs.generation < rhs.generation }
            return lhs.name < rhs.name
        }
    }

    private struct LogSlice {
        var text: String
        var rawBytes: Int
        var omitted: Int
    }

    /// The tail is what a bug report needs. A cut that lands mid-line advances
    /// to the next newline so the included text starts on a line boundary; the
    /// omission count includes that partial line.
    private static func readLog(_ url: URL, limit: Int) throws -> LogSlice {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        guard let size = Int(exactly: end) else { throw CocoaError(.fileReadTooLarge) }
        if size <= limit {
            try handle.seek(toOffset: 0)
            let data = try handle.readToEnd() ?? Data()
            return LogSlice(text: String(decoding: data, as: UTF8.self), rawBytes: size, omitted: 0)
        }
        let start = UInt64(size - limit)
        var omitted = size - limit
        var midLine = false
        if start > 0 {
            try handle.seek(toOffset: start - 1)
            let previous = try handle.read(upToCount: 1) ?? Data()
            midLine = previous.first != 0x0A
        } else {
            try handle.seek(toOffset: 0)
        }
        var body = try handle.readToEnd() ?? Data()
        if midLine, let newline = body.firstIndex(of: 0x0A) {
            let next = body.index(newline, offsetBy: 1)
            omitted += body.distance(from: body.startIndex, to: next)
            body = body.subdata(in: next..<body.endIndex)
        }
        return LogSlice(text: String(decoding: body, as: UTF8.self), rawBytes: size, omitted: omitted)
    }

    private static func logGeneration(_ name: String) -> Int? {
        guard name.hasSuffix(".log") else { return nil }
        let stem = name.dropLast(4)
        guard !stem.isEmpty, stem.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(stem)
    }
}
