import AppKit
import SwiftUI

/// The toolbar search field of the pages that have one (Installed, Steam Workshop and pixiv), owned
/// by the detail column rather than by each page.
///
/// Each page used to add its own `.searchable`. Going from one such page straight to the other then
/// swapped one toolbar search item for another, and SwiftUI's toolbar bridge inserted the new item at
/// an index `NSToolbar` refuses, which raised an exception and ended the app. One field that stays
/// in place and only changes its text, prompt and Return action avoids the swap. Settings searches
/// in its sidebar. The Workshop's field is there only while the list on show is one Steam searches
/// (an author's or a collection's wallpapers are not).
struct PageSearchField: ViewModifier {
  let selection: SidebarSelection

  @Environment(PanelController.self) private var controller

  func body(content: Content) -> some View {
    if let field = field {
      content
        .searchable(text: field.text, placement: .toolbar, prompt: field.prompt)
        .onSubmit(of: .search) { field.submit() }
        .background { SearchFieldName(name: field.name) }
    } else {
      content
    }
  }

  private struct Field {
    var text: Binding<String>
    var prompt: Text
    /// What VoiceOver calls the field, which says more than the short prompt drawn in it.
    var name: String
    var submit: () -> Void
  }

  private var field: Field? {
    switch selection {
    case .wallpaper:
      let model = controller.library
      return Field(
        text: Binding(get: { model.filter.text }, set: { model.setText($0) }),
        prompt: Text("Search wallpapers"), name: L("Search installed wallpapers"), submit: {})
    case .pixiv:
      let model = controller.pixivBrowser
      return Field(
        text: Binding(get: { model.draft.text }, set: { model.setText($0) }),
        prompt: Text(L("Search pixiv tags")), name: L("Search pixiv by tag"),
        submit: { model.submit() })
    case .workshop:
      // Every edit goes through the model, which tells a pasted link (searched at once) from typing
      // (searched after a pause) and a bare item id (searched on Return). Only the store's source is
      // read here, so the field is not redrawn for every change of the list.
      let source = controller.workshop.source
      guard source.isSearchable else { return nil }
      let model = controller.workshopBrowser
      return Field(
        text: Binding(get: { model.text }, set: { model.edit(text: $0) }),
        prompt: WorkshopSearchTrigger.invitesLink(for: source)
          ? Text("Search Workshop or paste a link") : Text("Search Workshop"),
        name: L("Search Steam Workshop"), submit: { model.search() })
    case .settings:
      return nil
    }
  }
}

/// Gives the toolbar's search field its accessibility name, which `.searchable` has no parameter
/// for: without one VoiceOver reads the prompt drawn in the field.
///
/// SwiftUI adds the search item to the window's toolbar after this view is in the window, and may
/// add it again when the toolbar is rebuilt, so the name is set whenever a search item is added as
/// well as when it changes.
private struct SearchFieldName: NSViewRepresentable {
  let name: String

  func makeNSView(context: Context) -> NamingView { NamingView() }

  func updateNSView(_ view: NamingView, context: Context) { view.name = name }

  final class NamingView: NSView {
    var name = "" {
      didSet { if name != oldValue { apply() } }
    }
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
      guard window != nil else { return }
      observer = NotificationCenter.default.addObserver(
        forName: NSToolbar.willAddItemNotification, object: nil, queue: .main
      ) { [weak self] note in
        guard note.userInfo?["item"] is NSSearchToolbarItem else { return }
        // The item is configured after it is announced: name it once it is in place.
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply() } }
      }
      apply()
    }

    func apply() {
      guard let window, let item = PanelSearchFocus.toolbarItem(in: window) else { return }
      item.searchField.setAccessibilityLabel(name)
    }
  }
}
