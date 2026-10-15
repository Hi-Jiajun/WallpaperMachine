import SwiftUI

/// The first-run guide as a full-window overlay, and where the support prompt is presented as a
/// sheet. The root mounts it over the split view and, while `ShellModel.isWelcomeOpen`, disables
/// what is behind it and hides that from VoiceOver.
///
/// It is always mounted, and idle while the guide is closed: it reads the guide's flag and nothing
/// else until the guide opens, and the support sheet only when an offer exists.
struct WelcomeOverlayHost: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let shell = controller.shell
    let model = controller.welcome
    let presenter = controller.supportPrompt
    let isOpen = shell.isWelcomeOpen
    // Read here, in the body, so the host is drawn again when the offer or what holds it moves.
    let wantsSupportPrompt = presenter.wantsPresentation
    ZStack {
      if isOpen {
        WelcomeGuide()
          .environment(model)
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .allowsHitTesting(isOpen)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isOpen)
    .onChange(of: isOpen, initial: true) { _, isOpen in
      if isOpen { model.open() } else { model.close() }
    }
    // A closing window takes the held password with it.
    .onDisappear { model.close() }
    // The Start page's Import wallpapers waits for the window to show Installed. The page change
    // reaches the root's `onChange` in this update or an earlier one, where it closes the popovers
    // of the page that was left; a task started from this `onChange` runs after all of them, so the
    // Import popover it opens stays open. (`.task(id:)` would start before them.)
    .onChange(of: model.importPopoverIsWaiting) { _, isWaiting in
      if isWaiting { Task { @MainActor in model.openWaitingImportPopover() } }
    }
    .sheet(
      isPresented: Binding(
        get: { wantsSupportPrompt },
        // The system closing it (Escape) is the person leaving; the presenter taking the window
        // for the guide, a popover or a sign-in is not, and never comes through here.
        set: { shown in if !shown && !presenter.isDismissed { presenter.dismiss() } })
    ) {
      SupportPromptSheet(presenter: presenter)
    }
  }
}

/// The first-wallpaper offer: star the project or become a supporter, once. Both are links the
/// person opens by choosing; nothing is starred or paid by opening one. **Not now**, the close
/// button and Escape all just leave.
struct SupportPromptSheet: View {
  let presenter: SupportPromptPresenter

  @Environment(\.panelTheme) private var theme

  var body: some View {
    WelcomeColumn(spacing: 18) {
      HStack(alignment: .top, spacing: 12) {
        WelcomeColumn(spacing: 6) {
          // The prompt's words can be selected and copied; the labels of its buttons cannot, so
          // a click anywhere on a choice makes the choice.
          Text("Feeling good?")
            .font(.system(size: 19, weight: .bold))
            .tracking(-0.2)
            .accessibilityAddTraits(.isHeader)
            .textSelection(.enabled)
          Text(
            "Your first downloaded wallpaper is up and running. Enjoying WallpaperMachine? You can help it grow."
          )
          .font(.system(size: 13))
          .lineSpacing(2)
          .foregroundStyle(theme.surface.muted.color)
          .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Button {
          presenter.dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(theme.surface.muted.color)
            .frame(width: 22, height: 22)
            .background(theme.surface.hover.color, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L("Dismiss support prompt"))
        .accessibilityLabel(L("Dismiss support prompt"))
      }
      WelcomeColumn(spacing: 8) {
        WelcomeActionRow(
          symbol: "star", color: .orange, title: Text("Star on GitHub"),
          note: Text("Help others discover WallpaperMachine."), trailingSymbol: "arrow.up.right"
        ) { choose(.star) }
        WelcomeActionRow(
          symbol: "heart", color: theme.surface.heart.color, title: Text("Become a Supporter"),
          note: Text("Support development with a one-time contribution."),
          trailingSymbol: "arrow.up.right"
        ) { choose(.supporter) }
      }
      .disabled(presenter.isChoosing)
      if let error = presenter.error { WelcomeNotice(style: .error, message: error) }
      HStack {
        Spacer(minLength: 0)
        Button("Not now") { presenter.dismiss() }
          .buttonStyle(.welcomeCapsule)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(24)
    .frame(width: 440)
    .foregroundStyle(theme.surface.text.color)
    .background(theme.surface.background.color)
    .onAppear { presenter.sheetDidAppear() }
  }

  private func choose(_ choice: SupportPromptChoice) {
    Task { await presenter.choose(choice) }
  }
}
