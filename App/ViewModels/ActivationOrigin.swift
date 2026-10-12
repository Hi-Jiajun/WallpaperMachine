/// Who asked for a wallpaper to be loaded on a display.
///
/// Only the user's own request is a choice. Everything else (a playlist's timer, an
/// automatic rule, a restored layout, an update reloading files) is the app acting on its
/// own, so it gives way to a choice the user is waiting on and is never counted as one.
enum ActivationOrigin: String, Sendable {
    /// The panel, the menu bar, a hotkey, a Shortcuts action or a link.
    case user
    case playlist
    case automation
    /// Applying a saved display layout. The layout is one user command that reports the
    /// choices it made itself, so its individual activations are not choices.
    case layout
    case updateReload

    /// Whether the person chose this. A user choice is never replaced by an automatic
    /// change, and only it reports a manual choice and counts toward the support prompt.
    var isUserChoice: Bool { self == .user }
}
