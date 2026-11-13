import XCTest

final class GuidedWorkoutUITests: XCTestCase {
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<16 { if element.exists && element.isHittable { return }; app.swipeUp() }
    }
    private func changeSeconds(_ app: XCUIApplication, from old: String, to new: String) {
        let field = app.textFields["set-seconds"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + new)
        app.buttons["save-set-edit"].tap()
    }
    func testDayDetailsStartCountdownRestCorrectionAndSummarySave() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch(); app.tabBars.buttons["План"].tap()
        XCTAssertTrue(app.buttons["start-level"].waitForExistence(timeout: 15))
        app.buttons["start-level"].tap(); app.buttons["confirm-start-level"].tap()
        let details = app.buttons["Упражнения и результаты дня"]; reveal(details, app: app); details.tap()
        let start = app.buttons["day-start-workout"]; XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["1 подходов"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Отдых:")).count, 0)
        start.tap()
        XCTAssertTrue(app.staticTexts["exercise-countdown"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Начать упражнение"].exists)
        let rest = app.staticTexts["rest-screen"]
        XCTAssertTrue(rest.waitForExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts["rest-result"].label.contains("30 сек"))
        app.buttons["extend-rest-30"].tap()
        app.buttons["edit-rest-result"].tap(); changeSeconds(app, from: "30", to: "24")
        XCTAssertTrue(rest.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["rest-result"].label.contains("24 сек"))
        app.buttons["continue-after-rest"].tap()
        XCTAssertTrue(app.staticTexts["player-exercise-title"].label.contains("Мягкие повороты шеи"))
        app.buttons["workout-actions"].tap(); app.buttons["finish-early"].tap()
        let edit = app.buttons["edit-summary-set"].firstMatch; reveal(edit, app: app); edit.tap()
        changeSeconds(app, from: "24", to: "20")
        app.buttons["Сохранить результат"].tap()
        app.terminate(); app.launch(); app.tabBars.buttons["План"].tap()
        let close = app.buttons["close-level"]; reveal(close, app: app); close.tap(); app.buttons["Закрыть уровень"].tap()
        XCTAssertTrue(app.buttons["start-level"].waitForExistence(timeout: 10))
    }
}
