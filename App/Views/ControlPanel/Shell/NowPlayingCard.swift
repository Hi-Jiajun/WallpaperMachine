import SwiftUI

/// The card at the bottom of the sidebar: what the target display is showing, and the previous, play
/// or pause, next and Recently used buttons.
///
/// Play and pause act on every display, so the status reports them even when the target display is
/// empty and the button works while any display has a wallpaper. Previous and next act on the target
/// display only. The artwork opens the wallpaper in the library; the equalizer moves only while it
/// plays and the window is on screen.
struct NowPlayingCard: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let shell = controller.shell
    let state = controller.nowPlaying
    VStack(spacing: 6) {
      HStack(spacing: 10) {
        // Nothing on the target display: no placeholder artwork, so the title keeps to one line
        // and the hint has the card's width, and the card stays about as tall as with a wallpaper.
        if state.item != nil { NowPlayingArtwork(state: state) }
        text(state)
        Spacer(minLength: 0)
      }
      .frame(minHeight: NowPlayingArtwork.size, alignment: .leading)
      HStack(spacing: 0) {
        NowPlayingControl(
          systemImage: "backward.fill", label: L("Previous wallpaper"),
          isEnabled: state.canGoPrevious && !shell.isPreviousBusy,
          identifier: "now-playing-previous"
        ) { shell.previousWallpaper() }
        NowPlayingControl(
          systemImage: state.showsPlay ? "play.fill" : "pause.fill", label: state.playbackLabel,
          isEnabled: state.canTogglePlayback && !shell.isPlaybackBusy, isProminent: true,
          identifier: "now-playing-toggle"
        ) { shell.togglePlayback() }
        NowPlayingControl(
          systemImage: "forward.fill", label: L("Next wallpaper"),
          isEnabled: state.canGoNext && !shell.isNextBusy, identifier: "now-playing-next"
        ) { shell.nextWallpaper() }
        history(shell)
      }
    }
    .padding(10)
    .background(card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
    }
    .help(state.help)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: state.accessibilityLabel))
    .accessibilityValue(Text(verbatim: state.status))
    .accessibilityIdentifier("now-playing")
  }

  /// The caption, the title, and under it the display and the equalizer, or what to do when nothing
  /// plays.
  private func text(_ state: NowPlayingState) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text("Now Playing")
        .font(.system(size: 10, weight: .semibold))
        .textCase(.uppercase)
        .tracking(0.4)
        .foregroundStyle(theme.surface.muted.color)
      Text(verbatim: state.title)
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(theme.surface.text.color)
        .lineLimit(state.item == nil ? 2 : 1)
        .truncationMode(.tail)
      if state.item != nil {
        HStack(spacing: 5) {
          Equalizer(isPlaying: state.isEqualizerRunning, barWidth: 2, height: 9)
            .foregroundStyle(theme.accent.accent.color)
            .opacity(state.isEqualizerRunning ? 1 : 0.45)
          Text(verbatim: displayName(state))
            .font(.system(size: 11))
            .foregroundStyle(theme.surface.muted.color)
            .lineLimit(1)
        }
      } else {
        Text(verbatim: state.detail)
          .font(.system(size: 11))
          .foregroundStyle(theme.surface.muted.color)
          .lineLimit(3)
      }
    }
  }

  /// The target display as the toolbar's menu button names it, which is what the line has room
  /// for; the card's help and VoiceOver label keep the full title.
  private func displayName(_ state: NowPlayingState) -> String {
    let displays = controller.targetDisplays
    let target = displays.first { $0.id == controller.targetDisplayID }
    return target?.shortLabel(among: displays) ?? state.displayTitle
  }

  /// Recently used: opens the target display's history in a popover above the card.
  private func history(_ shell: ShellModel) -> some View {
    NowPlayingControl(
      systemImage: "clock.arrow.circlepath", label: L("Recently used"),
      identifier: "now-playing-history"
    ) {
      let isOpen = shell.activePopover == .history
      shell.popover(.history).wrappedValue = !isOpen
    }
    // Upward, as the web panel opened it: the card sits at the bottom of the sidebar, a little in
    // from the window's left edge, so a popover to its side would hang out of the window and one
    // below would be pushed back up by the screen edge.
    .popover(isPresented: shell.popover(.history), arrowEdge: .top) {
      RecentlyUsedPopover()
    }
  }

  /// A lighter card over the sidebar in both appearances: near-white over the light material, a
  /// faint lift over the dark one.
  private var card: Color {
    colorScheme == .dark ? theme.surface.hover.color : Color.white.opacity(0.72)
  }
}
