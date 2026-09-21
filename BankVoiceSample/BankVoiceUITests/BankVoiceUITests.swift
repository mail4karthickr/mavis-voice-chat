import XCTest

@MainActor
final class BankVoiceUITests: XCTestCase {
    func testDirectBalanceShowsReplyAndMockJSON() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.karthick.bankvoice")
        app.launch()

        let textOnly = app.buttons["bank.textOnly"]
        XCTAssertTrue(textOnly.waitForExistence(timeout: 10), "The separate sample should offer text replies before downloading Marvis.")
        reveal(textOnly, in: app, swipeUp: true)
        textOnly.tap()

        app.buttons["bank.settings"].tap()
        let modePicker = app.descendants(matching: .any)["bank.modePicker"].firstMatch
        XCTAssertTrue(modePicker.waitForExistence(timeout: 5))
        modePicker.tap()
        let direct = app.buttons["Direct wording"]
        XCTAssertTrue(direct.waitForExistence(timeout: 5), "The wording picker should expose the direct comparison path.")
        direct.tap()
        app.buttons["bank.settingsDone"].tap()

        let balance = app.buttons["bank.scenario.balance"]
        XCTAssertTrue(balance.waitForExistence(timeout: 5))
        reveal(balance, in: app, swipeUp: false)
        XCTAssertTrue(balance.isEnabled)
        balance.tap()

        let answer = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "48,250 rupees and 75 paise", "51,250 rupees and 75 paise")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "The delayed balance API should produce the exact spoken amounts.")
        attachScreenshot(app, name: "Bank Voice — balance conversation")

        let timing = app.buttons["bank.latestTiming"]
        XCTAssertTrue(timing.waitForExistence(timeout: 5))
        reveal(timing, in: app, swipeUp: true)
        timing.tap()
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 5), "Tapping anywhere in the timing row should open diagnostics.")

        let endpoint = app.descendants(matching: .any)["bank.latestEndpoint"].firstMatch
        reveal(endpoint, in: app, swipeUp: true)
        XCTAssertTrue(accessibleText(endpoint).contains("/mock/v1/accounts/demo-savings/balance"))

        let json = app.descendants(matching: .any)["bank.responseJSON"].firstMatch
        reveal(json, in: app, swipeUp: true)
        XCTAssertTrue(json.exists, "Diagnostics should expose the actual mock JSON response.")
        let responseText = accessibleText(json)
        XCTAssertTrue(responseText.contains("\"availableBalance\""))
        XCTAssertTrue(responseText.contains("4825075"))
        XCTAssertTrue(responseText.contains("\"demo\" : true"))
        attachScreenshot(app, name: "Bank Voice — mock API diagnostics")
    }

    private func accessibleText(_ element: XCUIElement) -> String {
        [element.label, element.value as? String ?? ""].joined(separator: " ")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipeUp: Bool) {
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            if swipeUp { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.exists && element.isHittable, "Expected control was not reachable: \(element)")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
