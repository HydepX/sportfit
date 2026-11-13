import XCTest

final class SequentialPlanUITests: XCTestCase {
    func testHealthScreenOffersOfflineImportWithoutAutomaticPermissionPrompt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Профиль"].tap()
        let health = app.buttons["open-health"]
        reveal(health, app: app)
        health.tap()
        let status = app.staticTexts["health-build-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("без HealthKit"))
        XCTAssertFalse(app.buttons["Подключить вес, шаги и пульс"].exists)
        XCTAssertFalse(app.staticTexts["Проверка на iPhone"].exists)
        XCTAssertFalse(app.staticTexts["Прямое чтение Apple Health"].exists)
        let importer = app.buttons["import-health-xml"]
        reveal(importer, app: app)
        XCTAssertTrue(importer.isHittable)
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication, up: Bool = true) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            if up { app.swipeUp() } else { app.swipeDown() }
        }
    }
    func testStartPauseRelaunchCloseDaysAndArchiveLevel() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["План"].tap()
        XCTAssertTrue(app.buttons["start-level"].waitForExistence(timeout: 15))
        app.buttons["start-level"].tap()
        app.buttons["confirm-start-level"].tap()
        XCTAssertTrue(app.staticTexts["current-program-day"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["current-program-day"].label, "Сейчас · День 1")
        app.buttons["start-workout"].tap()
        let begin = app.buttons["Начать упражнение"]
        XCTAssertTrue(begin.waitForExistence(timeout: 10))
        reveal(begin, app: app)
        begin.tap()
        let pause = app.buttons["Пауза"]
        reveal(pause, app: app)
        pause.tap()
        app.terminate()
        app.launch()
        app.tabBars.buttons["План"].tap()
        let resume = app.buttons["Продолжить тренировку"]
        reveal(resume, app: app)
        resume.tap()
        XCTAssertTrue(app.staticTexts["Тренировка приостановлена"].waitForExistence(timeout: 10))
        app.buttons["workout-actions"].tap()
        // The action must stay available across clock ticks, not just during opening.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.buttons["finish-early"].waitForExistence(timeout: 5))
        app.buttons["finish-early"].tap()
        let save = app.buttons["Сохранить результат"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        reveal(save, app: app)
        save.tap()
        let closeDay = app.buttons["close-program-day"]
        XCTAssertTrue(closeDay.waitForExistence(timeout: 10))
        reveal(closeDay, app: app)
        closeDay.tap()
        app.buttons["Закрыть день и перейти дальше"].tap()
        XCTAssertEqual(app.staticTexts["current-program-day"].label, "Сейчас · День 2")
        reveal(app.buttons["close-rest-day"], app: app)
        app.buttons["close-rest-day"].tap()
        XCTAssertEqual(app.staticTexts["current-program-day"].label, "Сейчас · День 3")
        reveal(app.buttons["extra-rest"], app: app)
        app.buttons["extra-rest"].tap()
        app.buttons["Сегодня отдыхаю"].tap()
        XCTAssertEqual(app.staticTexts["current-program-day"].label, "Сейчас · День 3")
        let closeLevel = app.buttons["close-level"]
        reveal(closeLevel, app: app)
        closeLevel.tap()
        app.buttons["Закрыть уровень"].tap()
        let newLevel = app.buttons["start-level"]
        XCTAssertTrue(newLevel.waitForExistence(timeout: 10))
        newLevel.tap()
        app.buttons["confirm-start-level"].tap()
        XCTAssertTrue(app.staticTexts["current-program-day"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["current-program-day"].label, "Сейчас · День 1")
    }
}
