import XCTest

@testable import WallpaperMachine

@MainActor
final class ControlPanelRemediationTests: ControlPanelTestCase {
  func testReadyDoesNotResetTheCrashBudgetButAStableRunDoes() {
    var budget = WebPanelRecoveryBudget()
    for moment in [0.0, 10, 20] {
      budget.ready(at: moment)
      XCTAssertTrue(budget.permitRestart(at: moment + 1))
    }
    budget.ready(at: 30)
    XCTAssertFalse(budget.permitRestart(at: 31))
    budget.ready(at: 40)
    budget.ready(at: 99)
    XCTAssertTrue(budget.permitRestart(at: 101), "Repeated ready messages do not move the stable-run start")
    budget.reset()
    XCTAssertTrue(budget.permitRestart(at: 102))
  }

  func testFavoritesUseInjectedDefaultsAcrossReopenAndRemoval() async throws {
    let fixture = makeStore()
    let panel = try PanelFixture(store: fixture.store, bridge: fixture.bridge, displayTitles: .renderer)
    let other = try TemporaryDefaults.make(for: self).defaults
    do {
      panel.store.librarySnapshot.wallpapers = [.init(id: "first", title: "First", kind: .webpage,
        supported: true, active: false, selected: false, previewPath: nil)]
      try await panel.controller.perform("favorite", body: ["id": "first"])
      XCTAssertEqual(panel.controller.favoriteIDs, ["first"])
      XCTAssertNil(other.data(forKey: WebPanelController.favoriteKey))
      let reopened = WebPanelController(store: panel.store, navigation: panel.navigation,
        workshop: panel.workshop, defaults: panel.defaults, appLanguage: .english())
      defer { reopened.stop() }
      XCTAssertEqual(reopened.favoriteIDs, ["first"])
      try reopened.forgetFavorites(["first"])
      XCTAssertEqual(try JSONDecoder().decode([String].self,
        from: XCTUnwrap(panel.defaults.data(forKey: WebPanelController.favoriteKey))), [])
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }

  func testPlacementQueueKeepsEveryWallpaperIdentityAndCoalescesItsLatestValues() async throws {
    try await withPanel { panel in
      let result = try await panel.js("""
        const {createPlacement} = await import('./placement.js');
        let finish;
        const sent = [];
        const placement = createPlacement({
          send: async (action, args) => {
            sent.push(args);
            if (sent.length === 1) await new Promise(resolve => { finish = resolve; });
          }, render() {}, busy() { return false; }
        });
        const snapshot = (id, displayID = 'primary') => ({imagePlacement: {wallpaperID:id, displayID, x:0.5, y:0.5, zoom:1}});
        const input = (id, value) => ({dataset:{change:'placement', placement:'x', id}, value:String(value)});
        placement.sync(snapshot('a'));
        const a = placement.handleChange(input('a', 25));
        placement.sync(snapshot('b'));
        const b1 = placement.handleChange(input('b', 60));
        const b2 = placement.handleChange(input('b', 80));
        placement.sync(snapshot('b', 'secondary'));
        const c = placement.handleChange(input('b', 35));
        finish();
        await Promise.all([a,b1,b2,c]);
        return sent.map(v => `${v.id}:${v.displayID}:${v.x}`).join(',');
        """) as? String
      XCTAssertEqual(result, "a:primary:0.25,b:primary:0.8,b:secondary:0.35")
    }
  }
}
