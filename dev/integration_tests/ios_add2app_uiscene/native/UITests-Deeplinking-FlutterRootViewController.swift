// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import XCTest

final class xcode_uikit_swiftUITests: XCTestCase {

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testUniverslLink() throws {
    let app = XCUIApplication()
    app.launch() // Make sure the app is installed

    // Make sure the app is not running to test link works on launch.
    app.terminate()
    let urlString = URL(string: "https://ios.deeplinktest.site/second")
    XCUIDevice.shared.system.open(urlString!)

    let linkedPageTitle =  app.otherElements["Flutter Demo Second Page"].firstMatch
    XCTAssertTrue(linkedPageTitle.waitForExistence(timeout: 5))

    // Go back to first page and send app to background to test link works while app is running.
    let button = app.buttons["Return to home page"].firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    button.tap()
    let homePageTitle =  app.otherElements["Flutter Demo First Page"].firstMatch
    XCTAssertTrue(homePageTitle.waitForExistence(timeout: 5))
    XCUIDevice.shared.press(.home)

    XCUIDevice.shared.system.open(urlString!)
    XCTAssertTrue(linkedPageTitle.waitForExistence(timeout: 5))
  }

  @MainActor
  func testDeepLink() throws {
    let app = XCUIApplication()
    app.launch() // Make sure the app is installed

    // Make sure the app is not running to test link works on launch.
    app.terminate()
    let urlString = URL(string: "custom-scheme://ios.deeplinktest.site/second")
    XCUIDevice.shared.system.open(urlString!)

    let linkedPageTitle =  app.otherElements["Flutter Demo Second Page"].firstMatch
    XCTAssertTrue(linkedPageTitle.waitForExistence(timeout: 5))

    // Go back to first page and send app to background to test link works while app is running.
    let button = app.buttons["Return to home page"].firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    button.tap()
    let homePageTitle =  app.otherElements["Flutter Demo First Page"].firstMatch
    XCTAssertTrue(homePageTitle.waitForExistence(timeout: 5))
    XCUIDevice.shared.press(.home)

    XCUIDevice.shared.system.open(urlString!)
    XCTAssertTrue(linkedPageTitle.waitForExistence(timeout: 5))
  }
}
