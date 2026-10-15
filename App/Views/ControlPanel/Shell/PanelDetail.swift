import SwiftUI

/// The detail column: the page on show, with its title, toolbar, banners and inspector. Library
/// pages (Installed, Steam Workshop, pixiv) have an inspector column beside them; Settings is a
/// page of its own.
struct PanelDetail: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let shell = controller.shell
    let selection = shell.selection
    // The counts are only read where the subtitle shows them, and not while the library loads, when
    // they would say there is nothing.
    let counts = selection == .wallpaper && !controller.isLibraryLoading ? controller.sidebarCounts : nil
    let title = PanelTitle.make(
      selection: selection, scope: controller.library.scope, counts: counts,
      settingsSection: controller.settings.selectedSection, searchQuery: controller.settings.query,
      workshopSubtitle: selection == .workshop ? controller.workshopTitleSubtitle : nil)
    page(for: selection)
      // One search field for the pages that have one, kept in place across them (PageSearchField).
      .modifier(PageSearchField(selection: selection))
      .safeAreaInset(edge: .top, spacing: 0) { PanelBanners() }
      .background { theme.surface.background.color.ignoresSafeArea() }
      // The inspector stays attached on every page and is only closed on Settings, so moving
      // between Settings and the library never adds or removes the split view's own toolbar items.
      //
      // The page has no minimum width of its own: the inspector asks for 260 points at least, and a
      // page minimum on top of that makes the split view wider than the 760-point window.
      .inspector(isPresented: inspectorBinding(shell, selection)) {
        inspector(for: selection).inspectorColumnWidth(min: 260, ideal: 300, max: 420)
      }
      // Under the first-run guide the bare title bar names nothing: the guide is what is on show.
      .navigationTitle(shell.isWelcomeOpen ? "" : title.title)
      .navigationSubtitle(shell.isWelcomeOpen ? "" : title.subtitle ?? "")
      .toolbar { PanelToolbarContent(controller: controller) }
  }

  /// Open or closed by the person's choice, or by the window's width while they have not chosen, on
  /// the pages that have an inspector; closed on the pages that have none, and the choice is kept for
  /// when they come back.
  private func inspectorBinding(_ shell: ShellModel, _ selection: SidebarSelection) -> Binding<Bool>
  {
    Binding(
      get: { shell.hasInspector && shell.isInspectorShown },
      set: { if shell.hasInspector { shell.isInspectorShown = $0 } })
  }

  @ViewBuilder
  private func page(for selection: SidebarSelection) -> some View {
    switch selection {
    case .settings: SettingsDetail()
    case .workshop: WorkshopBrowserPage()
    case .pixiv: PixivBrowserPage()
    case .wallpaper: InstalledPage()
    }
  }

  @ViewBuilder
  private func inspector(for selection: SidebarSelection) -> some View {
    switch selection {
    case .settings: EmptyView()
    case .workshop: WorkshopInspector()
    case .pixiv: PixivInspector()
    case .wallpaper: InstalledInspector()
    }
  }
}
