//
//  PolyDromUITests.swift
//  PolyDromUITests
//
//  Created by zikasak on 07/07/2026.
//

import XCTest

final class PolyDromUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testSettingsWindowOpensWithKeyboardShortcut() throws {
        let app = XCUIApplication()
        app.launch()

        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(app.textFields["serverAddressField"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["serverUsernameField"].exists)
        XCTAssertTrue(app.secureTextFields["serverPasswordField"].exists)
        XCTAssertTrue(app.buttons["saveAndConnectButton"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
