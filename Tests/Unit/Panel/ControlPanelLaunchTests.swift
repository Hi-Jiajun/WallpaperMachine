import Foundation
import XCTest

@testable import WallpaperMachine

final class ControlPanelLaunchTests: XCTestCase {
    func testLoginLaunchKeepsThePanelClosedOnceSetUp() {
        XCTAssertFalse(ControlPanelLaunch.opensPanel(
            launchEvent: Self.openApplication(launchedAs: keyAELaunchedAsLogInItem),
            welcomeSeen: true, startupFailed: false))
    }

    func testOtherLaunchesOpenThePanel() {
        let launches: [(String, NSAppleEventDescriptor?)] = [
            ("Finder or Dock", Self.openApplication(launchedAs: nil)),
            ("service item", Self.openApplication(launchedAs: keyAELaunchedAsServiceItem)),
            ("opened documents", NSAppleEventDescriptor(
                eventClass: kCoreEventClass, eventID: AEEventID(kAEOpenDocuments),
                targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID))),
            ("no launch event", nil),
        ]
        for (name, event) in launches {
            XCTAssertTrue(ControlPanelLaunch.opensPanel(launchEvent: event, welcomeSeen: true, startupFailed: false), name)
        }
    }

    func testLoginLaunchStillOpensThePanelWhenTheUserHasSomethingToDo() {
        let login = Self.openApplication(launchedAs: keyAELaunchedAsLogInItem)
        XCTAssertTrue(ControlPanelLaunch.opensPanel(launchEvent: login, welcomeSeen: false, startupFailed: false),
                      "The welcome guide is unfinished")
        XCTAssertTrue(ControlPanelLaunch.opensPanel(launchEvent: login, welcomeSeen: true, startupFailed: true),
                      "The renderer failed to start")
    }

    private static func openApplication(launchedAs property: OSType?) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: kCoreEventClass, eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        if let property {
            event.setParam(NSAppleEventDescriptor(enumCode: property), forKeyword: keyAEPropData)
        }
        return event
    }
}
