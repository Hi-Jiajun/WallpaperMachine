import XCTest

@testable import WallpaperMachine

/// Why quality is lower than the user's settings, in the order and the words the Performance and
/// Playback sections use. Replaces the quality half of the old shell tests
/// (`testReducedQualityShowsItsProfileAndNamesItsCause`).
@MainActor
final class QualityReportTests: PanelTestCase {
  private struct Case {
    var batteryMode: BridgeBatteryMode = .keepRunning
    var lowPower: SystemConditionAction = .keepRunning
    var thermal: SystemConditionAction = .keepRunning
    var lowBattery: SystemConditionAction = .keepRunning
    var batteryPercent: Int?
    var onBattery = false
    var throttle: [BridgeQualityThrottleCause] = []
  }

  private func report(_ value: Case) -> QualityReport {
    let settings = BridgeSnapshotFixtures.settings(
      batteryMode: value.batteryMode, renderScale: 0.75, preferredRenderScale: 1,
      onBatteryPower: value.onBattery, qualityThrottle: value.throttle, renderScaleSupported: true)
    return QualityReport.make(
      settings: settings, lowPowerModeAction: value.lowPower, thermalAction: value.thermal,
      lowBatteryAction: value.lowBattery, batteryPercent: value.batteryPercent)
  }

  /// The shared profile's rows follow any of the four Reduced quality choices; a low-battery choice
  /// counts only on a Mac with a battery, where its menu is offered at all.
  func testTheProfileFollowsAnyOfTheFourReducedQualityChoices() {
    XCTAssertFalse(report(Case()).reducedQualityChosen, "No reduced choice, no profile to edit")
    XCTAssertTrue(report(Case(batteryMode: .reducedQuality)).reducedQualityChosen)
    XCTAssertTrue(report(Case(lowPower: .reduceQuality)).reducedQualityChosen)
    XCTAssertTrue(report(Case(thermal: .reduceQuality)).reducedQualityChosen)
    XCTAssertTrue(report(Case(lowBattery: .reduceQuality, batteryPercent: 50)).reducedQualityChosen)
    XCTAssertFalse(
      report(Case(lowBattery: .reduceQuality, batteryPercent: nil)).reducedQualityChosen,
      "A Mac without a battery never shows the low-battery choice, so it cannot ask for the profile")
    XCTAssertFalse(report(Case(batteryMode: .pause, lowBattery: .pause, batteryPercent: 50)).reducedQualityChosen)
  }

  /// Heat is named before Low Power Mode, a throttle before the battery, and nothing held reads as
  /// the generic sentence.
  func testTheCauseNamedIsTheMostSpecificOneInForce() {
    XCTAssertNil(report(Case(thermal: .reduceQuality)).cause, "Chosen but nothing holds: the generic reading")
    XCTAssertEqual(report(Case(thermal: .reduceQuality, throttle: [.heat])).cause, .heat)
    XCTAssertEqual(report(Case(lowPower: .reduceQuality, throttle: [.lowPowerMode])).cause, .lowPowerMode)
    XCTAssertEqual(
      report(Case(lowBattery: .reduceQuality, batteryPercent: 10, throttle: [.lowBattery])).cause,
      .lowBattery)
    XCTAssertEqual(report(Case(batteryMode: .reducedQuality, onBattery: true)).cause, .battery)
    XCTAssertNil(
      report(Case(batteryMode: .reducedQuality, onBattery: false)).cause,
      "The battery mode is in force only while on battery")

    let both = report(Case(lowPower: .reduceQuality, thermal: .reduceQuality, throttle: [.lowPowerMode, .heat]))
    XCTAssertEqual(both.causes, [.heat, .lowPowerMode], "The order here, not the engine's, is the order of naming")
    XCTAssertEqual(both.cause, .heat, "Heat is named before Low Power Mode")
    let throttleAndBattery = report(
      Case(batteryMode: .reducedQuality, onBattery: true, throttle: [.heat]))
    XCTAssertEqual(throttleAndBattery.causes, [.heat, .battery])
    XCTAssertEqual(throttleAndBattery.cause, .heat, "A throttle is named before the battery")
  }

  func testEffectiveNowNamesTheCauseAndFillsEveryPlaceholder() throws {
    try pinPanelLanguageToEnglish()
    let cases: [(String, Case, String)] = [
      ("heatChosen", Case(thermal: .reduceQuality), "75%. Your setting of 100% is not in effect right now."),
      ("heat", Case(thermal: .reduceQuality, throttle: [.heat]), "75% while the Mac is hot. Your setting is 100%."),
      (
        "lowPower", Case(lowPower: .reduceQuality, throttle: [.lowPowerMode]),
        "75% in Low Power Mode. Your setting is 100%."
      ),
      (
        "lowBattery", Case(lowBattery: .reduceQuality, batteryPercent: 10, throttle: [.lowBattery]),
        "75% while the battery is low. Your setting is 100%."
      ),
      (
        "battery", Case(batteryMode: .reducedQuality, onBattery: true),
        "75% on battery. Your setting is 100%."
      ),
    ]
    for (name, value, expected) in cases {
      let report = report(value)
      XCTAssertTrue(report.showsEffectiveScale, name)
      XCTAssertEqual(report.effectiveText, expected, name)
      XCTAssertFalse(report.statusText.isEmpty, "\(name) says nothing about the quality in use")
      XCTAssertFalse((report.effectiveText ?? "").contains("%@"), name)
    }
    XCTAssertEqual(report(Case(throttle: [.heat])).statusText, "The Mac is hot. Reduced quality is in use.")
    XCTAssertEqual(report(Case()).statusText, "Your usual quality settings are in use.")
  }

  /// Effective now appears only while a scale the engine uses differs from the saved one, and only
  /// where a wallpaper can honour a scale at all.
  func testEffectiveNowAppearsOnlyWhileTheScaleInForceDiffersFromTheSavedOne() {
    func scale(_ effective: Float, _ saved: Float, supported: Bool = true) -> QualityReport {
      let settings = BridgeSnapshotFixtures.settings(
        renderScale: effective, preferredRenderScale: saved, renderScaleSupported: supported)
      return QualityReport.make(
        settings: settings, lowPowerModeAction: .keepRunning, thermalAction: .keepRunning,
        lowBatteryAction: .keepRunning, batteryPercent: nil)
    }
    XCTAssertFalse(scale(1, 1).showsEffectiveScale)
    XCTAssertNil(scale(1, 1).effectiveText)
    XCTAssertTrue(scale(0.75, 1).showsEffectiveScale)
    XCTAssertFalse(scale(0.75, 1, supported: false).showsEffectiveScale, "Nothing running can honour a scale")
    XCTAssertNil(scale(0.75, 1, supported: false).effectiveText)
  }

  func testTheThermalNoteDiffersForReducedQualityAndNeverLeavesAPlaceholder() throws {
    try pinPanelLanguageToEnglish()
    for level in ThermalLevel.allCases {
      for action in SystemConditionAction.allCases {
        let note = level.note(for: action)
        XCTAssertFalse(note.contains("%@") || note.contains("{"), "\(level) \(action): \(note)")
        XCTAssertTrue(note.hasSuffix("Right now it is \(level.word)."), note)
      }
    }
    XCTAssertEqual(ThermalLevel.nominal.word, "normal")
    XCTAssertEqual(ThermalLevel.fair.word, "warm")
    XCTAssertEqual(ThermalLevel.serious.word, "hot")
    XCTAssertEqual(ThermalLevel.critical.word, "very hot")
    XCTAssertNotEqual(
      ThermalLevel.serious.note(for: .reduceQuality), ThermalLevel.serious.note(for: .pause),
      "Reduced quality also pauses at very hot, which the note says")
    XCTAssertEqual(ThermalLevel(.serious), .serious)
    XCTAssertEqual(ThermalLevel(.nominal), .nominal)
  }

  func testTheFocusNoteNamesAFilterInEffectAndIsSilentWithoutOne() throws {
    try pinPanelLanguageToEnglish()
    XCTAssertNil(FocusFilterEffect.note(forRawValue: "keepRunning"))
    XCTAssertEqual(FocusFilterEffect.note(forRawValue: "mute"), "A Focus filter is in effect now: Mute.")
    XCTAssertEqual(
      FocusFilterEffect.note(forRawValue: "playlist"),
      "A Focus filter is in effect now: Use saved playlist.")
    XCTAssertEqual(
      FocusFilterEffect.note(forRawValue: "future"), "A Focus filter is in effect now: future.",
      "A filter this build does not know is named as given")
  }
}
