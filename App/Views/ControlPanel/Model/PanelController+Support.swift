import Foundation

/// What the user chooses in the first-wallpaper support prompt.
enum SupportPromptChoice: Sendable {
  /// Not now: the offer is spent and nothing opens.
  case dismiss
  /// Star the repository on GitHub.
  case star
  /// The supporter pricing page, in Chinese for a Chinese interface.
  case supporter
}

/// The first-wallpaper support offer: when it is pending and what its buttons do.
///
/// Whether the offer may appear is the store's (`SupportPromptStore`: a wallpaper downloaded through
/// Discover or pixiv and then applied by the user for the first time). Whether it is on screen is the
/// panel's: a hidden or minimised panel must not report it, because showing it spends it.
extension PanelController {
  /// The offer is waiting and the panel can show it. The presenter adds its own deferrals (the welcome
  /// guide, a download dialog or popover, a switch in flight, a sign-in) before it presents.
  var supportPromptPending: Bool {
    store.supportPrompt?.isPending == true && presentation.isVisible
  }

  /// A wallpaper switch is running or queued, which holds the offer back until it settles.
  var supportPromptDeferredBySwitch: Bool {
    isStoreBusy || !store.waitingActivationIDs.isEmpty
  }

  /// `supportPromptShown`: the offer is now on screen, so it is spent and never returns, even after a
  /// restart. Does nothing while the panel is not visible, which keeps a hidden panel from consuming it.
  func supportPromptShown() {
    guard presentation.isVisible else { return }
    store.supportPrompt?.markPresented()
  }

  /// `supportPromptChoice`. Star opens the repository, Become a Supporter the pricing page (the Chinese
  /// one for a Chinese interface), through the `openSupportURL` seam and not the external-link allowlist.
  /// Not now spends the offer and opens nothing.
  ///
  /// A link that cannot be opened throws and leaves the offer available for another try or Escape, so
  /// call this directly from the prompt (not through `launch`) to keep the error in the dialog.
  func supportPromptChoice(_ choice: SupportPromptChoice) async throws {
    let url: URL
    switch choice {
    case .dismiss:
      store.supportPrompt?.markPresented()
      return
    case .star:
      url = AppUpdateConfiguration.repositoryURL
    case .supporter:
      let path = appLanguage.effective.tag.hasPrefix("zh") ? "zh/pricing/" : "pricing/"
      url = URL(string: "https://www.wallpapermachine.app/\(path)")!
    }
    guard openSupportURL(url) else {
      throw WallpaperActionError(message: L("The link could not be opened. Please try again."))
    }
    store.supportPrompt?.markPresented()
  }
}
