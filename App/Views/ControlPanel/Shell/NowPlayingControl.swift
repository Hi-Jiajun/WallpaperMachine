import SwiftUI

/// One icon button of the Now Playing card: previous, play or pause, next, Recently used.
///
/// Its label is both the tooltip and what VoiceOver reads, so a button never says one thing and does
/// another; the play button's label changes with what pressing it does.
struct NowPlayingControl: View {
  let systemImage: String
  let label: String
  var isEnabled = true
  /// The play or pause button is the card's main action and draws a little larger.
  var isProminent = false
  let identifier: String
  let action: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: isProminent ? 15 : 12.5, weight: .semibold))
        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
    }
    .buttonStyle(NowPlayingControlStyle())
    .disabled(!isEnabled)
    .help(label)
    .accessibilityLabel(Text(verbatim: label))
    .accessibilityIdentifier(identifier)
  }
}

/// The look of a Now Playing button: a quiet rounded hit area that fills on hover and press, and
/// fades while the button is unavailable.
struct NowPlayingControlStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    NowPlayingControlBody(configuration: configuration)
  }
}

private struct NowPlayingControlBody: View {
  let configuration: ButtonStyleConfiguration

  @Environment(\.panelTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    configuration.label
      .foregroundStyle(theme.surface.text.color)
      .frame(maxWidth: .infinity, minHeight: 28)
      .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .opacity(isEnabled ? 1 : 0.32)
      .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      .onHover { isHovering = $0 }
  }

  private var fill: Color {
    guard isEnabled else { return .clear }
    if configuration.isPressed { return theme.surface.pressed.color }
    return isHovering ? theme.surface.selected.color : .clear
  }
}

/// The 44-point artwork of the card, a button that shows the wallpaper in the library. The card
/// leaves it out while the target display shows nothing.
struct NowPlayingArtwork: View {
  /// The artwork's side, which is also the least height of the card's top row.
  static let size: CGFloat = 44

  let state: NowPlayingState
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    if let item = state.item {
      Button {
        controller.shell.showInstalled(item.id)
      } label: {
        artwork(item.still)
      }
      .buttonStyle(NowPlayingArtworkStyle())
      .disabled(controller.isBusy(PanelActionCoordinator.key("showInstalled", id: item.id)))
      .help(state.showInLibraryLabel ?? "")
      .accessibilityLabel(Text(verbatim: state.showInLibraryLabel ?? ""))
      .accessibilityIdentifier("now-playing-artwork")
    }
  }

  /// The cover over a quiet well with a picture glyph, which shows until the cover has loaded or
  /// when it cannot be.
  private func artwork(_ source: PanelImageSource?) -> some View {
    ZStack {
      theme.surface.mediaWell.color
      Image(systemName: "photo")
        .font(.system(size: 15))
        .foregroundStyle(theme.surface.faint.color)
      PanelImage(source: source, pointSize: Self.size, contentMode: .fill)
    }
    .frame(width: Self.size, height: Self.size)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
    }
  }
}

/// Presses the artwork down a little; hovering darkens it slightly, so it reads as a button.
private struct NowPlayingArtworkStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    NowPlayingArtworkBody(configuration: configuration)
  }
}

private struct NowPlayingArtworkBody: View {
  let configuration: ButtonStyleConfiguration

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    configuration.label
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(.black.opacity(configuration.isPressed ? 0.22 : isHovering && isEnabled ? 0.1 : 0))
      }
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .onHover { isHovering = $0 }
  }
}
