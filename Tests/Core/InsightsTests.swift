import XCTest
@testable import SportFitCore

final class InsightsTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func date(_ day: String) -> Date { SportDate.from(day)! }
    private func program() throws -> TrainingProgram { try JSONDecoder().decode(TrainingProgram.self, from: Data(contentsOf: root.appendingPathComponent("SportFit/Resources/Data/program_12w_with_sets.v2.json"))) }
    private func workout(run: ProgramRun? = nil, day: Int = 0, complete: Bool = true, reps: Int = 4, weight: Double = 3) throws -> WorkoutResult {
        let catalog = try JSONDecoder().decode(ExerciseCatalog.self, from: Data(contentsOf: root.appendingPathComponent("SportFit/Resources/Data/exercises.v1.json")))
        var movement = WorkoutMovement(sourceId: "press_floor", exercise: try XCTUnwrap(catalog.exercises.first { $0.id == "press_floor" }))
        movement.sets = [ActualSet(reps: reps, weightKg: weight, seconds: nil, completedAt: date("2026-11-10"))]
        return WorkoutResult(id: UUID(), date: "2026-11-10", programId: "test", title: "test", startedAt: date("2026-11-10"),
                             finishedAt: date("2026-11-10").addingTimeInterval(60), durationSeconds: 45, feeling: nil,
                             finishedEarly: !complete, movements: [movement], runId: run?.id, runDayIndex: run == nil ? nil : day)
    }
    func testRollingPeriodsIncludeWholeFirstDayAndExcludeFuture() {
        let now = date("2026-11-12").addingTimeInterval(12 * 3600)
        XCTAssertTrue(AnalyticsPeriod.week.contains(date("2026-11-06"), now: now))
        XCTAssertFalse(AnalyticsPeriod.week.contains(date("2026-11-05").addingTimeInterval(86399), now: now))
        XCTAssertFalse(AnalyticsPeriod.all.contains(now.addingTimeInterval(1), now: now))
    }
    func testWeightTrendUsesObservedDaysRatherThanSampleFrequencyOrZeros() {
        let points = [MetricPoint(date: date("2026-11-01"), value: 80, source: "A"),
                      MetricPoint(date: date("2026-11-01").addingTimeInterval(60), value: 82, source: "A"),
                      MetricPoint(date: date("2026-11-03"), value: 79, source: "A"),
                      MetricPoint(date: date("2026-11-11"), value: 70, source: "A")]
        let trend = InsightMath.trend(points)
        XCTAssertEqual(trend.count, 1)
        XCTAssertEqual(trend[0].value, 80)
        XCTAssertEqual(trend[0].date, date("2026-11-03"))
    }
    func testSourcesNeverBlendAndSingleMeasurementDoesNotShowChangeEvidence() {
        let points = [MetricPoint(date: date("2026-11-01"), value: 80, source: "A"), MetricPoint(date: date("2026-11-02"), value: 60, source: "B")]
        XCTAssertTrue(InsightMath.trend(points).isEmpty)
        XCTAssertEqual(InsightMath.changes(points, metric: "weight").map(\.count), [1, 1])
    }
    func testDailyTotalsUseLatestEntryRatherThanSummingCorrections() {
        let a = ActivityEntry(date: date("2026-11-01"), metric: .steps, value: 400, recordedAt: date("2026-11-01"))
        let b = ActivityEntry(date: date("2026-11-01"), metric: .steps, value: 600, recordedAt: date("2026-11-02"))
        XCTAssertEqual(InsightMath.activity([b, a], metric: .steps).first?.value, 600)
        XCTAssertTrue(InsightMath.activity([a], metric: .sleep).isEmpty)
    }
    func testPulseDailyAverageAndMissingSleepRemainDistinct() {
        let d = date("2026-11-01")
        let entries = [ActivityEntry(date: d, metric: .pulse, value: 60), ActivityEntry(date: d.addingTimeInterval(60), metric: .pulse, value: 80)]
        XCTAssertEqual(InsightMath.activity(entries, metric: .pulse).first?.value, 70)
        XCTAssertTrue(InsightMath.activity(entries, metric: .sleep).isEmpty)
        XCTAssertFalse(ActivityMetric.sleep.valid(25))
        XCTAssertFalse(ActivityMetric.steps.valid(1.5))
    }
    func testOverlappingXMLStepsDoNotProduceFalseDailyTotals() {
        let d = date("2026-11-01")
        let records = [HealthRecord.imported(field: .steps, value: 100, start: d, end: d.addingTimeInterval(100), source: "watch"),
                       HealthRecord.imported(field: .steps, value: 200, start: d.addingTimeInterval(50), end: d.addingTimeInterval(150), source: "watch")]
        XCTAssertTrue(InsightMath.activity([], metric: .steps, xml: records).isEmpty)
    }
    func testRetriesCountRealWorkButNotTwiceAsCompletedProgramDays() throws {
        let run = ProgramRun(title: "test", program: try program())
        let a = try workout(run: run, complete: false), b = try workout(run: run)
        let summary = TrainingSummary.make([a, b, b])
        XCTAssertEqual(summary.attempts, 2)
        XCTAssertEqual(summary.completeSessions, 1)
        XCTAssertEqual(summary.partialSessions, 0)
        XCTAssertEqual(summary.sets, 2)
        XCTAssertEqual(summary.reps, 8)
        XCTAssertEqual(summary.externalVolumeKg, 24)
        XCTAssertEqual(summary.durationSeconds, 90)
    }
    func testBodyweightDoesNotBecomeInventedExternalLoad() throws {
        let summary = TrainingSummary.make([try workout(weight: 0)])
        XCTAssertEqual(summary.externalVolumeKg, 0)
        XCTAssertEqual(summary.reps, 4)
    }
    func testLevelReportCountsActualOutcomesAndRemainingWithoutCalendarMisses() throws {
        var run = ProgramRun(title: "test", program: try program())
        try run.closeDay(history: [], allowIncomplete: true)
        try run.closeDay(history: [], allowIncomplete: false)
        let plan = RunPlanSummary(run: run, history: [])
        XCTAssertEqual(plan.planned, 48)
        XCTAssertEqual(plan.skipped, 1)
        XCTAssertEqual(plan.remaining, 47)
        XCTAssertEqual(plan.completed, 0)
    }
    func testGoalEvaluationUsesExplicitDirectionAndUnknownIsNotFailed() {
        let goal = QuarterGoal(scope: "test", metric: .weight, direction: .atMost, target: 70, baseline: 80)
        let evaluation = GoalEvaluation(goal: goal, current: 75)
        XCTAssertEqual(evaluation.achieved, false)
        XCTAssertEqual(evaluation.progressPercent, 50)
        XCTAssertEqual(GoalEvaluation(goal: goal, current: 69).achieved, true)
        XCTAssertNil(GoalEvaluation(goal: goal, current: nil).achieved)
    }
    func testReportPrivacyRemovesNameNotesAndMedicalValuesWhenRequested() throws {
        var journal = JournalData()
        journal.notes = [DayNote(reason: "private reason", text: "private text")]
        journal.activity = [ActivityEntry(date: date("2026-11-10"), metric: .pulse, value: 65)]
        let measurements = [BodyMeasurement(date: date("2026-11-10"), weightKg: 75, waistCm: 90, bodyFatPercent: 20)]
        let report = QuarterReport.make(title: "test", scope: "test", start: date("2026-11-01"), end: date("2026-11-30"), run: nil,
            history: [try workout()], measurements: measurements, xml: [], journal: journal, name: "PRIVATE NAME", privacy: .training, now: date("2026-11-12"))
        let json = String(decoding: try report.json(), as: UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE NAME")); XCTAssertFalse(json.contains("private reason")); XCTAssertFalse(json.contains("private text"))
        XCTAssertTrue(report.body.isEmpty); XCTAssertTrue(report.activity.isEmpty)
        XCTAssertEqual(report.training.attempts, 1)
    }
    func testReportSnapshotDoesNotChangeWithLaterMeasurements() throws {
        var entries = [BodyMeasurement(date: date("2026-11-10"), weightKg: 75, waistCm: nil, bodyFatPercent: nil)]
        let report = QuarterReport.make(title: "test", scope: "test", start: date("2026-11-01"), end: date("2026-11-30"), run: nil,
            history: [], measurements: entries, xml: [], journal: JournalData(), name: "name", privacy: .metrics, now: date("2026-11-12"))
        entries[0].weightKg = 90
        XCTAssertEqual(report.body.first?.first.value, 75)
        XCTAssertNil(report.profileName)
        XCTAssertTrue(String(decoding: try report.json(), as: UTF8.self).contains("2026-11-10T"))
    }
    func testReminderDefaultsDoNotScheduleOrRequestAnything() {
        XCTAssertTrue(ReminderPlan.make(settings: ReminderPreferences(), run: nil, draft: nil, latestMeasurement: nil, history: []).isEmpty)
    }
    func testReminderHorizonIsBoundedAndNeverInventsCompletionDate() throws {
        var settings = ReminderPreferences(); settings.enabled = true; settings.measurement = true; settings.weekly = true
        let run = ProgramRun(title: "test", program: try program())
        let requests = ReminderPlan.make(settings: settings, run: run, draft: nil, latestMeasurement: nil, history: [], now: date("2026-11-12"))
        XCTAssertLessThanOrEqual(requests.count, 48)
        XCTAssertEqual(Set(requests.map(\.id)).count, requests.count)
        XCTAssertFalse(requests.contains { $0.id.contains("complete") })
        XCTAssertTrue(requests.allSatisfy { $0.date > date("2026-11-12") && $0.date < date("2026-11-26") })
    }
    func testReminderInvalidTimeAndDisabledCategoriesProduceNoRequests() throws {
        var settings = ReminderPreferences(); settings.enabled = true; settings.hour = 99
        XCTAssertThrowsError(try settings.validate())
        XCTAssertTrue(ReminderPlan.make(settings: settings, run: nil, draft: nil, latestMeasurement: nil, history: []).isEmpty)
    }
    func testGoalAlreadyAchievedDoesNotShowContradictoryProgress() {
        let goal = QuarterGoal(scope: "test", metric: .weight, direction: .atMost, target: 70, baseline: 60)
        XCTAssertEqual(GoalEvaluation(goal: goal, current: 65).progressPercent, 100)
        XCTAssertEqual(GoalEvaluation(goal: goal, current: 75).achieved, false)
        XCTAssertNil(GoalEvaluation(goal: goal, current: 75).progressPercent)
    }
    func testBodyGoalNeverUsesAnotherMeasurementSource() {
        var imported = BodyMeasurement(date: date("2026-11-10"), weightKg: 65, waistCm: nil, bodyFatPercent: nil)
        imported.source = "different-source"
        var journal = JournalData(); journal.goals = [QuarterGoal(scope: "test", metric: .weight, direction: .atMost, target: 70, source: "manual")]
        let report = QuarterReport.make(title: "PRIVATE TITLE", scope: "test", start: date("2026-11-01"), end: date("2026-11-30"), run: nil,
            history: [], measurements: [imported], xml: [], journal: journal, name: "private", privacy: .metrics, now: date("2026-11-12"))
        XCTAssertNil(report.goals.first?.current); XCTAssertNil(report.goals.first?.achieved)
        XCTAssertEqual(report.title, "Отчёт SportFit")
    }
    func testWeekKeysUseISOWeeksAcrossNewYear() {
        XCTAssertEqual(InsightMath.weekKey(date("2026-12-31")), InsightMath.weekKey(date("2027-01-01")))
        XCTAssertNotEqual(InsightMath.weekKey(date("2027-01-01")), InsightMath.weekKey(date("2027-01-04")))
    }
}
