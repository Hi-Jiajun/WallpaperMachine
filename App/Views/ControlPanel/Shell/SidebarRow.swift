import Foundation

/// A row of the library sidebar, and the rule for which one is lit.
///
/// All wallpapers, Favorites and each collection are views of one page, Installed, so three kinds of
/// row open the same `SidebarSelection`: what tells them apart is the `LibraryScope` the library
/// browser shows, which survives a visit to Steam Workshop, pixiv or Settings and comes back as it
/// was.
enum SidebarRow: Hashable {
  case workshop, pixiv, allWallpapers, favorites
  case collection(String)

  /// The page the row opens.
  var selection: SidebarSelection {
    switch self {
    case .workshop: .workshop
    case .pixiv: .pixiv
    case .allWallpapers, .favorites, .collection: .wallpaper
    }
  }

  /// The part of the library the row shows; nil for a row that opens another page.
  var scope: LibraryScope? {
    switch self {
    case .workshop, .pixiv: nil
    case .allWallpapers: .all
    case .favorites: .favorites
    case .collection(let id): .collection(id)
    }
  }

  /// The row lit for the page on show. A library row is lit only while Installed is the page, and a
  /// collection that no longer exists lights All wallpapers, the view the grid has fallen back to.
  /// Nothing is lit on Settings: another sidebar is on show there.
  static func highlighted(
    selection: SidebarSelection, scope: LibraryScope, collectionIDs: some Collection<String>
  ) -> SidebarRow? {
    switch selection {
    case .settings: nil
    case .workshop: .workshop
    case .pixiv: .pixiv
    case .wallpaper:
      switch scope {
      case .all: .allWallpapers
      case .favorites: .favorites
      case .collection(let id): collectionIDs.contains(id) ? .collection(id) : .allWallpapers
      }
    }
  }
}
