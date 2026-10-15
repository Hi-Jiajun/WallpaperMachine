import XCTest

@testable import WallpaperMachine

/// Which row of the library sidebar is lit, and what choosing one opens.
final class SidebarRowTests: XCTestCase {
  private let collections = ["night", "chill"]

  private func lit(_ selection: SidebarSelection, _ scope: LibraryScope = .all) -> SidebarRow? {
    SidebarRow.highlighted(selection: selection, scope: scope, collectionIDs: collections)
  }

  func testTheLitRowIsThePageOnShowAndForInstalledTheLibraryView() {
    XCTAssertEqual(lit(.workshop), .workshop)
    XCTAssertEqual(lit(.pixiv), .pixiv)
    XCTAssertEqual(lit(.wallpaper), .allWallpapers)
    XCTAssertEqual(lit(.wallpaper, .favorites), .favorites)
    XCTAssertEqual(lit(.wallpaper, .collection("chill")), .collection("chill"))
  }

  func testTheLibraryViewIsNotLitWhileAnotherPageIsOnShowAndItsMemoryDoesNotMoveTheHighlight() {
    XCTAssertEqual(lit(.workshop, .favorites), .workshop, "the view is remembered, not shown")
    XCTAssertEqual(lit(.pixiv, .collection("night")), .pixiv)
    XCTAssertNil(lit(.settings, .favorites), "Settings has a sidebar of its own")
  }

  func testACollectionThatIsGoneLightsAllWallpapersWhichIsWhatTheGridShows() {
    XCTAssertEqual(lit(.wallpaper, .collection("deleted")), .allWallpapers)
  }

  func testEveryRowOpensItsPageAndLibraryRowsSetTheViewTheGridShows() {
    XCTAssertEqual(SidebarRow.workshop.selection, .workshop)
    XCTAssertEqual(SidebarRow.pixiv.selection, .pixiv)
    for row in [SidebarRow.allWallpapers, .favorites, .collection("night")] {
      XCTAssertEqual(row.selection, .wallpaper, "\(row) is a view of Installed")
    }
    XCTAssertNil(SidebarRow.workshop.scope, "browsing leaves the library view alone")
    XCTAssertNil(SidebarRow.pixiv.scope)
    XCTAssertEqual(SidebarRow.allWallpapers.scope, .all)
    XCTAssertEqual(SidebarRow.favorites.scope, .favorites)
    XCTAssertEqual(SidebarRow.collection("night").scope, .collection("night"))
  }
}
