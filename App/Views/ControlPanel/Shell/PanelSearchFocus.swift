import AppKit

/// Finds the search field a page puts in the window and gives it the keyboard, which is what
/// Command-F does.
///
/// Installed's, Steam Workshop's and pixiv's field is the detail column's `.searchable`
/// (`PageSearchField`), which AppKit draws as a search item of the toolbar; Settings keeps its field
/// in the sidebar. Both are `NSSearchField`s of the window, found here instead of through a focus
/// binding each page would have to share.
@MainActor
enum PanelSearchFocus {
  /// The search field of the window that is on screen: the toolbar's first, then the first
  /// visible one in the content (the Settings sidebar's).
  static func field(in window: NSWindow) -> NSSearchField? {
    if let item = toolbarItem(in: window) { return item.searchField }
    return window.contentView.flatMap(firstField)
  }

  /// Starts a search in the window. True when a field took the keyboard.
  @discardableResult
  static func focus(in window: NSWindow) -> Bool {
    if let item = toolbarItem(in: window) {
      item.beginSearchInteraction()
      return true
    }
    guard let field = window.contentView.flatMap(firstField) else { return false }
    return window.makeFirstResponder(field)
  }

  /// The window's toolbar search item, which the detail column's `.searchable` becomes.
  static func toolbarItem(in window: NSWindow) -> NSSearchToolbarItem? {
    window.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first
  }

  private static func firstField(in view: NSView) -> NSSearchField? {
    if view.isHidden { return nil }
    if let field = view as? NSSearchField { return field }
    for subview in view.subviews {
      if let found = firstField(in: subview) { return found }
    }
    return nil
  }
}
