import Foundation
import Observation

/// The panel's one-time prompts and when each may appear.
///
/// - `support` asks for support once a successfully downloaded wallpaper has been applied.
/// - `telemetry` asks once whether to send performance data, only someone who had finished the
///   welcome guide before it offered the switch; the guide asks everyone else.
///
/// At most one is pending at a time, the telemetry question first, and none appears on the
/// same day as another.
@MainActor
@Observable
final class SupportPromptStore {
    enum Prompt: String {
        case telemetry, support
    }

    private struct State: Codable {
        var downloadedWallpaperIDs: Set<String> = []
        var pending = false
        var presented = false
        var telemetryAsked = false
        var lastPromptAt: Date?

        init() {}

        // The first builds saved only the first three fields; the rest read as unset.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            downloadedWallpaperIDs = try container.decodeIfPresent(Set<String>.self, forKey: .downloadedWallpaperIDs) ?? []
            pending = try container.decodeIfPresent(Bool.self, forKey: .pending) ?? false
            presented = try container.decodeIfPresent(Bool.self, forKey: .presented) ?? false
            telemetryAsked = try container.decodeIfPresent(Bool.self, forKey: .telemetryAsked) ?? false
            lastPromptAt = try container.decodeIfPresent(Date.self, forKey: .lastPromptAt)
        }
    }

    private static let key = "WallpaperMachine.supportPrompt.state"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar
    private var state: State

    /// The support prompt is waiting to be shown.
    var isPending: Bool { state.pending && !state.presented }

    init(defaults: UserDefaults = ClientPreferences.defaults, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
        if let data = defaults.data(forKey: Self.key) {
            do {
                state = try JSONDecoder().decode(State.self, from: data)
            } catch {
                AppLog.warn("support prompt state could not be loaded: \(error.localizedDescription)")
                state = State()
            }
        } else {
            state = State()
        }
    }

    /// The prompt to show now, if any. `welcomeSeen` is whether the welcome guide had been
    /// finished; `telemetryOn` whether sending performance data is already on.
    func pendingPrompt(welcomeSeen: Bool, telemetryOn: Bool, now: Date = Date()) -> Prompt? {
        if let last = state.lastPromptAt, calendar.isDate(last, inSameDayAs: now) { return nil }
        if welcomeSeen, !telemetryOn, !state.telemetryAsked { return .telemetry }
        if isPending { return .support }
        return nil
    }

    func recordDownload(wallpaperID: String) {
        guard !wallpaperID.isEmpty, !state.pending, !state.presented,
              !state.downloadedWallpaperIDs.contains(wallpaperID) else { return }
        var next = state
        next.downloadedWallpaperIDs.insert(wallpaperID)
        persist(next)
    }

    func recordSuccessfulActivation(wallpaperID: String) {
        guard !wallpaperID.isEmpty, !state.pending, !state.presented,
              state.downloadedWallpaperIDs.contains(wallpaperID) else { return }
        var next = state
        next.downloadedWallpaperIDs.removeAll()
        next.pending = true
        persist(next)
    }

    func forgetDownload(wallpaperID: String) {
        guard state.downloadedWallpaperIDs.contains(wallpaperID) else { return }
        var next = state
        next.downloadedWallpaperIDs.remove(wallpaperID)
        persist(next)
    }

    /// The welcome guide showed the performance data switch, so the prompt is not needed.
    func recordTelemetryAsked() {
        guard !state.telemetryAsked else { return }
        var next = state
        next.telemetryAsked = true
        persist(next)
    }

    func markPresented(_ prompt: Prompt = .support, now: Date = Date()) {
        var next = state
        switch prompt {
        case .support:
            guard isPending else { return }
            next.pending = false
            next.presented = true
        case .telemetry:
            guard !state.telemetryAsked else { return }
            next.telemetryAsked = true
        }
        next.lastPromptAt = now
        persist(next)
    }

    private func persist(_ next: State) {
        do {
            let data = try JSONEncoder().encode(next)
            defaults.set(data, forKey: Self.key)
            state = next
        } catch {
            AppLog.warn("support prompt state could not be saved: \(error.localizedDescription)")
        }
    }
}
