import SwiftUI

/// The sidebar column: the library navigation, or, while Settings is open, the list of Settings
/// sections with its search field in its place.
struct PanelSidebar: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    if controller.shell.selection == .settings {
      SettingsSidebar()
    } else {
      LibrarySidebar()
    }
  }
}

/// Steam Workshop and pixiv under Browse, the library views, the collections, and at the bottom the
/// Now Playing card and the Settings row.
///
/// Every row is a page or a view of the library, and one is lit: the page on show, and for Installed
/// the view the library shows. The arrow keys move the highlight, which opens the page as a click
/// does; Return and Space need nothing more.
private struct LibrarySidebar: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let shell = controller.shell
    let counts = controller.sidebarCounts
    VStack(spacing: 0) {
      List(selection: selection(shell)) {
        Section("Browse") {
          Label("Steam Workshop", systemImage: "storefront")
            .tag(SidebarRow.workshop)
            .accessibilityIdentifier("sidebar-workshop")
          // A proper noun: never translated.
          Label {
            Text(verbatim: "pixiv")
          } icon: {
            Image(systemName: "paintpalette")
          }
          .tag(SidebarRow.pixiv)
          .accessibilityIdentifier("sidebar-pixiv")
        }
        // Nothing is chosen while the guide covers the window: `.disabled` does not stop a list's
        // arrow keys on macOS, so a list that kept the keyboard would change the page behind it.
        .selectionDisabled(shell.isWelcomeOpen)
        Section("Library") {
          Label {
            HStack(spacing: 6) {
              Text("All wallpapers")
              if counts.updateTooltip != nil { UpdateDot() }
            }
          } icon: {
            Image(systemName: "square.grid.2x2")
          }
          .badge(Text(counts.all, format: .number))
          .modifier(UpdateNote(text: counts.updateTooltip, count: counts.all))
          .tag(SidebarRow.allWallpapers)
          .accessibilityIdentifier("sidebar-all")
          Label("Favorites", systemImage: "heart")
            .badge(Text(counts.favorites, format: .number))
            .tag(SidebarRow.favorites)
            .accessibilityIdentifier("sidebar-favorites")
        }
        .selectionDisabled(shell.isWelcomeOpen)
        CollectionsSidebarSection(collections: counts.collections)
          .selectionDisabled(shell.isWelcomeOpen)
      }
      .listStyle(.sidebar)
      .accessibilityLabel(Text(verbatim: L("Main navigation")))
      VStack(spacing: 8) {
        NowPlayingCard()
        SettingsRowButton()
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 10)
    }
    // A collection deleted from elsewhere takes the name field that was renaming it along.
    .onChange(of: counts.collections.map(\.id)) { shell.collectionEditor.reconcile() }
  }

  /// The sidebar lights the row of the page on show; choosing a row opens it.
  private func selection(_ shell: ShellModel) -> Binding<SidebarRow?> {
    Binding(
      get: { shell.highlightedRow },
      set: { row in
        if let row { shell.show(row) }
      })
  }
}

/// The accent dot beside All wallpapers while Workshop wallpapers have an update. The row carries
/// the count, as its tooltip and its accessibility value.
private struct UpdateDot: View {
  var body: some View {
    Circle()
      .fill(.tint)
      .frame(width: 6, height: 6)
      .accessibilityHidden(true)
  }
}

/// While updates wait, the whole All wallpapers row says how many, as its tooltip and to VoiceOver,
/// not only the dot beside its name. Without updates the row keeps its own value (the count).
private struct UpdateNote: ViewModifier {
  let text: String?
  /// The row's count, which its badge shows.
  let count: Int

  func body(content: Content) -> some View {
    if let text {
      // The badge's count stays first in what VoiceOver reads, as it was before updates waited.
      let count = count.formatted(.number.locale(PanelLocale.shared.locale))
      content
        .help(text)
        .accessibilityValue(Text(verbatim: "\(count), \(text)"))
    } else {
      content
    }
  }
}

/// The Settings row under the Now Playing card. It is not a list row, so it draws its own hover.
private struct SettingsRowButton: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    Button {
      controller.shell.open(.settings)
    } label: {
      Label("Settings", systemImage: "gearshape")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
        .background(
          isHovering ? theme.surface.hover.color : .clear,
          in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .accessibilityIdentifier("sidebar-settings")
  }
}
