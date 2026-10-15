import Foundation
import Observation

/// What can hold the first-wallpaper support offer back. The offer is a courtesy: the first-run
/// guide, anything else that is modal, a wallpaper being switched and Steam or pixiv asking for a
/// sign-in all come first, and it resumes by itself when they are done.
struct SupportPromptGate: Equatable {
  /// The panel's window is on screen: visible, not minimised, not covered.
  var windowIsVisible = false
  var welcomeIsOpen = false
  /// A popover of the shell or a page is open.
  var popoverIsOpen = false
  var downloadDialogIsOpen = false
  /// A wallpaper switch is running or waiting.
  var switchIsInProgress = false
  var pixivIsSigningIn = false
  /// A download job is signing in or waits for a password or a Steam Guard answer.
  var downloadAwaitsSteam = false

  var allowsPresentation: Bool {
    windowIsVisible && !welcomeIsOpen && !popoverIsOpen && !downloadDialogIsOpen
      && !switchIsInProgress && !pixivIsSigningIn && !downloadAwaitsSteam
  }
}

/// The part of the download dialog's state the support offer reads, which `DownloadsModel` answers
/// with its own `isDialogOpen`. There is deliberately no default: a renamed property must break the
/// build, not leave the offer free to cover an open dialog.
@MainActor
protocol DownloadDialogState: AnyObject {
  var isDialogOpen: Bool { get }
}

extension DownloadsModel: DownloadDialogState {}

/// When the support prompt may be on screen and what its buttons do.
///
/// Whether there is an offer is the store's (`SupportPromptStore`, through
/// `PanelController.supportPromptPending`). Whether it may appear now is the gate's. Once the sheet
/// has been seen the offer is spent for good, so the presenter keeps that one presentation: when
/// the guide, a popover or a sign-in takes the window it closes the sheet without dismissing it and
/// brings the same sheet back afterwards. A deliberate choice, **Not now** or Escape ends it.
@MainActor
@Observable
final class SupportPromptPresenter {
  unowned let controller: PanelController

  /// The offer was on screen at least once: the store counts it as spent.
  private(set) var hasBeenShown = false
  /// The person answered or left; the offer never returns in this window.
  private(set) var isDismissed = false
  /// A link choice is being opened.
  private(set) var isChoosing = false
  /// Why the last link choice failed.
  private(set) var error: String?

  init(controller: PanelController) { self.controller = controller }

  /// What holds the offer back now; every input is read from observable state, so a view that asks
  /// is asked again when one changes.
  var gate: SupportPromptGate {
    let downloads: any DownloadDialogState = controller.downloads
    return SupportPromptGate(
      windowIsVisible: controller.presentation.isVisible,
      welcomeIsOpen: controller.shell.isWelcomeOpen,
      popoverIsOpen: controller.shell.isPopoverOpen,
      downloadDialogIsOpen: downloads.isDialogOpen,
      switchIsInProgress: controller.supportPromptDeferredBySwitch,
      pixivIsSigningIn: controller.pixivAccount.isSigningIn,
      downloadAwaitsSteam: controller.steamDownloadRows.contains {
        $0.isPending && ($0.isAuthenticating || $0.prompt != nil || $0.challenge != nil)
      })
  }

  var canPresent: Bool { gate.allowsPresentation }

  /// Whether the sheet should be up: an offer is waiting, or one that was already shown is
  /// interrupted, and nothing holds it back.
  var wantsPresentation: Bool {
    guard !isDismissed else { return false }
    return (hasBeenShown || controller.supportPromptPending) && canPresent
  }

  /// The sheet is on screen. The first time, the offer is spent. A sheet of a window nobody can see
  /// is not shown, so it spends nothing and counts as not yet seen.
  func sheetDidAppear() {
    guard !hasBeenShown, controller.presentation.isVisible else { return }
    hasBeenShown = true
    controller.supportPromptShown()
  }

  /// **Star on GitHub** and **Become a Supporter**. A link that cannot be opened keeps the offer
  /// open with the reason, so the other row, a retry and **Not now** all remain.
  func choose(_ choice: SupportPromptChoice) async {
    guard !isDismissed, !isChoosing else { return }
    if choice == .dismiss {
      dismiss()
      return
    }
    isChoosing = true
    error = nil
    defer { isChoosing = false }
    do {
      try await controller.supportPromptChoice(choice)
      isDismissed = true
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// **Not now**, the close button and Escape. Leaving is always available, so the sheet goes first
  /// and spending the offer follows, whatever that does.
  @discardableResult
  func dismiss() -> Task<Void, Never> {
    isDismissed = true
    return Task { [controller] in try? await controller.supportPromptChoice(.dismiss) }
  }
}
