import XCTest

final class InsightsFlowUITests: XCTestCase {
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<14 { if element.exists && element.isHittable { return }; app.swipeUp() }
    }
    private func insights(_ app: XCUIApplication) {
        app.tabBars.buttons["Прогресс"].tap()
        let link = app.buttons["open-insights"]; reveal(link, app: app); link.tap()
    }
    func testManualActivityCanBeSavedAndSurvivesRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch(); insights(app)
        app.buttons["activity-insights"].tap()
        let add = app.buttons["add-activity"]; XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap()
        let field = app.textFields["activity-value"]; XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("1234")
        let save = app.buttons["save-activity"]; reveal(save, app: app); save.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["activity-empty"].exists)
        app.terminate(); app.launch(); insights(app); app.buttons["activity-insights"].tap()
        XCTAssertTrue(app.buttons["add-activity"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["activity-empty"].exists)
    }
    func testReportCanBeSavedAndOffersJSONAndPDF() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch(); insights(app); app.buttons["quarter-reports"].tap(); app.buttons["calendar-report"].tap()
        let save = app.buttons["save-report"]; reveal(save, app: app); XCTAssertTrue(save.isHittable); save.tap()
        let json = app.buttons["export-report-json"]; reveal(json, app: app); XCTAssertTrue(json.isHittable)
        let pdf = app.buttons["export-report-pdf"]; reveal(pdf, app: app); XCTAssertTrue(pdf.isHittable)
        app.terminate(); app.launch(); insights(app); app.buttons["quarter-reports"].tap()
        let snapshot = app.staticTexts["Отчёт SportFit"]; reveal(snapshot, app: app); XCTAssertTrue(snapshot.exists)
    }
    func testStorageCreatesLocalBackupAndRemindersStartDisabled() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch(); app.tabBars.buttons["Профиль"].tap()
        let storage = app.buttons["open-storage"]; reveal(storage, app: app); storage.tap()
        let create = app.buttons["create-local-backup"]; reveal(create, app: app); create.tap()
        let message = app.staticTexts["storage-message"]; reveal(message, app: app)
        XCTAssertTrue(message.label.contains("Локальная копия создана"))
        app.terminate(); app.launch(); app.tabBars.buttons["Профиль"].tap()
        let reminders = app.buttons["open-reminders"]; reveal(reminders, app: app); reminders.tap()
        let enabled = app.switches["enable-reminders"]; XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
}
