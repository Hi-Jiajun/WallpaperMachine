import XCTest
@testable import WallpaperMachine

final class AutomationCommandTests: XCTestCase {
    private func command(_ link: String) -> AutomationCommand? {
        URL(string: link).flatMap(AutomationCommand.init(url:))
    }

    func testLinksNameTheCommandAndItsDetails() {
        XCTAssertEqual(command("wallpapermachine://play"), .play)
        XCTAssertEqual(command("wallpapermachine://pause"), .pause)
        XCTAssertEqual(command("WallpaperMachine://TOGGLE"), .togglePlayback, "scheme and command ignore case")
        XCTAssertEqual(command("wallpapermachine://next"), .next(display: nil))
        XCTAssertEqual(command("wallpapermachine://next?display=primary"), .next(display: "primary"))
        XCTAssertEqual(command("wallpapermachine://previous"), .previous(display: nil))
        XCTAssertEqual(command("wallpapermachine://previous?display=identity%3A%7B%7D"), .previous(display: "identity:{}"))
        XCTAssertEqual(command("wallpapermachine://apply?id=3632513108"), .apply(wallpaperID: "3632513108", display: nil))
        XCTAssertEqual(
            command("wallpapermachine://apply?id=image-Sunset%20.png&display=identity%3A%7B%7D"),
            .apply(wallpaperID: "image-Sunset .png", display: "identity:{}"))
        XCTAssertEqual(command("wallpapermachine://apply?id=3632513108&display=all"), .applyEverywhere(wallpaperID: "3632513108"))
        XCTAssertEqual(command("wallpapermachine://apply?display=ALL&id=image-Sunset%20.png"),
                       .applyEverywhere(wallpaperID: "image-Sunset .png"), "the value ignores case like the command does")
        XCTAssertEqual(command("wallpapermachine://open"), .open(page: nil))
        XCTAssertEqual(command("wallpapermachine://open?page=Settings"), .open(page: .settings))
        XCTAssertEqual(command("wallpapermachine://playlist?id=plan%20one&display=secondary"), .applyPlaylist(planID: "plan one", display: "secondary"))
        XCTAssertEqual(command("wallpapermachine://playlist?id=p"), .applyPlaylist(planID: "p", display: nil))
        XCTAssertEqual(command("wallpapermachine://preset?id=preset%20one"), .applyPreset(presetID: "preset one"))
        XCTAssertEqual(command("wallpapermachine://layout?id=desk"), .applyDisplayLayout(layoutID: "desk"))
    }

    /// `all` means every display only on an apply link; the other commands still take a display's
    /// own selector and report an unknown one when they run.
    func testAllIsNotADisplayForAnyOtherCommand() {
        XCTAssertEqual(command("wallpapermachine://next?display=all"), .next(display: "all"))
        XCTAssertEqual(command("wallpapermachine://previous?display=all"), .previous(display: "all"))
        XCTAssertEqual(command("wallpapermachine://playlist?id=p&display=all"), .applyPlaylist(planID: "p", display: "all"))
        XCTAssertEqual(command("wallpapermachine://apply?id=1&display=primary"), .apply(wallpaperID: "1", display: "primary"))
    }

    func testAnythingElseIsRefusedRatherThanGuessed() {
        for link in [
            "https://play", "wallpapermachine://", "wallpapermachine://delete?id=1", "wallpapermachine://apply",
            "wallpapermachine://apply?id=", "wallpapermachine://apply?id=1&id=2", "wallpapermachine://play?now=1",
            "wallpapermachine://next?display=a&volume=1", "wallpapermachine://open?page=elsewhere",
            "wallpapermachine://play/extra",
            "wallpapermachine://previous?id=a", "wallpapermachine://previous?display=a&display=b",
            "wallpapermachine://playlist", "wallpapermachine://playlist?id=a&id=b",
            "wallpapermachine://preset?id=", "wallpapermachine://preset?id=p&display=primary",
            "wallpapermachine://layout?id=", "wallpapermachine://layout?id=a&id=b", "wallpapermachine://layout?id=a&display=primary",
            "wallpapermachine://apply?display=all", "wallpapermachine://apply?id=1&display=all&x=1",
            "wallpapermachine://apply?id=1&display=all&display=primary", "wallpapermachine://apply?id=&display=all",
        ] {
            XCTAssertNil(command(link), link)
        }
    }
}
