import Foundation
import Testing
@testable import ModelDeckMacCore

// Issue #771 — the "This week" graph. Placeholder accounts only. The dates
// mirror the mockup Tim picked from: a week that started Oct 15, 5:00 PM
// Pacific and resets Oct 22, 5:00 PM, read at 3:09 PM on the last day.

private func date(_ iso: String) -> Date {
    DeckDateParsing.date(from: iso)!
}

/// The daemon's own spelling (`toISOString()`), milliseconds included.
private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private let pacific: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}()

private let reset = date("2026-10-23T00:00:00Z")      // Oct 22, 5:00 PM PDT
private let weekStart = date("2026-10-16T00:00:00Z")  // Oct 15, 5:00 PM PDT
private let now = date("2026-10-22T22:09:00Z")        // Oct 22, 3:09 PM PDT
private let hour: TimeInterval = 3600
private let day: TimeInterval = 86_400

private func account(_ id: String, provider: String) -> DeckAccount {
    DeckAccount(id: id, provider: provider, label: "Deck \(id)", identity: "\(id)@example.com", enabled: true, isDefault: false)
}

private func snapshot(
    _ id: String,
    scope: String,
    remaining: Double,
    resetsAt: Date?,
    observedAt: Date = now
) -> UsageSnapshot {
    UsageSnapshot(
        accountId: id,
        scope: scope,
        remainingPercent: remaining,
        resetsAt: resetsAt.map(iso),
        observedAt: iso(observedAt)
    )
}

private func row(_ id: String, provider: String, _ snapshots: [UsageSnapshot], at time: Date = now) -> DeckAccountRow {
    DeckBuilder.rows(state: DeckState(accounts: [account(id, provider: provider)], usage: snapshots), now: time)[0]
}

/// A Claude card's all-models weekly, read at `observedAt`.
private func weekly(remaining: Double, resetsAt: Date? = reset, observedAt: Date = now, at time: Date = now) -> DeckWindow {
    let card = row("c1", provider: "claude", [
        snapshot("c1", scope: "weekly", remaining: remaining, resetsAt: resetsAt, observedAt: observedAt),
    ], at: time)
    return WeeklyUsageGraph.window(for: card)!
}

/// The daemon's hourly rows, newest first as `bucketUsageHistory` sorts them.
private func buckets(_ readings: [(Date, Double?)]) -> [UsageHistoryBucket] {
    readings
        .map { UsageHistoryBucket(bucketStart: iso($0.0), lastUsedPercent: $0.1) }
        .reversed()
}

private func hourly(from start: Date, to end: Date, used: (Date) -> Double) -> [(Date, Double?)] {
    stride(from: start.timeIntervalSince1970, through: end.timeIntervalSince1970, by: hour).map {
        let time = Date(timeIntervalSince1970: $0)
        return (time, used(time))
    }
}

@Suite("Issue #771 — which window the graph draws, and its period")
struct Issue771WeeklyGraphPeriodTests {
    @Test func claudeCardsGraphTheirAllModelsWeekly() {
        let card = row("c1", provider: "claude", [
            snapshot("c1", scope: "5-hour", remaining: 80, resetsAt: now.addingTimeInterval(2 * hour)),
            snapshot("c1", scope: "weekly", remaining: 40, resetsAt: reset),
            snapshot("c1", scope: "Fable weekly", remaining: 70, resetsAt: reset),
        ])
        #expect(WeeklyUsageGraph.window(for: card)?.scope == "weekly")
    }

    @Test func codexCardsGraphTheirAccountWeekly() {
        let card = row("x1", provider: "codex", [
            snapshot("x1", scope: "5-hour", remaining: 90, resetsAt: now.addingTimeInterval(hour)),
            snapshot("x1", scope: "weekly", remaining: 55, resetsAt: reset),
        ])
        #expect(WeeklyUsageGraph.window(for: card)?.scope == "weekly")
    }

    @Test func cardsWithoutAnAllModelsWeeklyHaveNoGraph() {
        let fiveHourOnly = row("c2", provider: "claude", [
            snapshot("c2", scope: "5-hour", remaining: 80, resetsAt: now.addingTimeInterval(hour)),
            snapshot("c2", scope: "Fable weekly", remaining: 70, resetsAt: reset),
        ])
        let grok = row("g1", provider: "grok", [
            snapshot("g1", scope: "monthly", remaining: 60, resetsAt: reset),
        ])
        #expect(WeeklyUsageGraph.window(for: fiveHourOnly) == nil)
        #expect(WeeklyUsageGraph.window(for: grok) == nil)
    }

    @Test func periodRunsFromAWeekBeforeTheResetToTheReset() {
        let period = WeeklyUsageGraph.period(for: weekly(remaining: 40), now: now)
        #expect(period == WeeklyUsageGraph.Period(start: weekStart, end: reset))
    }

    @Test func codexWeeklyPeriodIsSevenDaysToo() {
        let card = row("x1", provider: "codex", [
            UsageSnapshot(
                accountId: "x1", scope: "weekly", remainingPercent: 55,
                resetsAt: iso(reset), observedAt: iso(now),
                detail: UsageSnapshotDetail(windowDurationMins: 10_080)
            ),
        ])
        let window = WeeklyUsageGraph.window(for: card)!
        #expect(WeeklyUsageGraph.period(for: window, now: now)?.start == weekStart)
    }

    @Test func aWindowThatJustRolledStartsItsPeriodAtTheRoll() {
        let rolledAt = now.addingTimeInterval(-hour)
        let window = weekly(remaining: 100, resetsAt: rolledAt.addingTimeInterval(7 * day))
        #expect(WeeklyUsageGraph.period(for: window, now: now)?.start == rolledAt)
    }

    @Test func aWeekThatHasNotStartedHasNoPeriod() {
        // Unanchored: untouched since the last reset, so the provider's
        // reset time is a placeholder a week after the probe.
        let placeholder = weekly(remaining: 100, resetsAt: now.addingTimeInterval(7 * day))
        let noReset = weekly(remaining: 100, resetsAt: nil)
        #expect(WeeklyUsageGraph.period(for: placeholder, now: now) == nil)
        #expect(WeeklyUsageGraph.period(for: noReset, now: now) == nil)
    }

    // The realistic form (PR #773 review): the provider was last read two
    // hours ago, and an untouched window reported its reset as a placeholder
    // a week after that read. By the clock that "week" has begun, but nobody
    // has used it, so there is still nothing to draw.
    @Test func anUntouchedWeekReadHoursAgoHasNoPeriod() {
        let readAt = now.addingTimeInterval(-2 * hour)
        let placeholder = weekly(remaining: 100, resetsAt: readAt.addingTimeInterval(7 * day), observedAt: readAt)
        #expect(WeeklyUsageGraph.period(for: placeholder, now: now) == nil)
    }

    // PR #773 review: a reading with no reset has no week to draw it
    // against, so the card offers no graph rather than "No readings this
    // week yet" beside its "47% left".
    @Test func aReadingWithNoResetOffersNoGraph() {
        let card = row("c1", provider: "claude", [snapshot("c1", scope: "weekly", remaining: 47, resetsAt: nil)])
        #expect(WeeklyUsageGraph.window(for: card) == nil)
    }

    // An untouched week reports no reset either, but that one keeps its
    // graph and its line: the week simply hasn't started.
    @Test func anUntouchedWeekStillSaysItHasNotStarted() {
        let untouched = weekly(remaining: 100, resetsAt: nil)
        #expect(WeeklyUsageGraph.content(window: untouched, load: nil, now: now) == .message("No readings this week yet"))
    }

    @Test func aWeekThatEndedSinceItsLastReadingHasNoPeriod() {
        // Idle rollforward: the stored reset passed after the last reading,
        // so the stored period is last week's, not this one.
        let later = reset.addingTimeInterval(2 * hour)
        let closed = weekly(remaining: 40, observedAt: now, at: later)
        #expect(WeeklyUsageGraph.period(for: closed, now: later) == nil)
    }
}

@Suite("Issue #771 — readings become points, and gaps stay gaps")
struct Issue771WeeklyGraphPointsTests {
    private let period = WeeklyUsageGraph.Period(start: weekStart, end: reset)

    @Test func rowsBecomeOldestFirstPercentLeft() {
        let rows = buckets([
            (weekStart.addingTimeInterval(hour), 2),
            (weekStart.addingTimeInterval(2 * hour), nil),
            (weekStart.addingTimeInterval(3 * hour), 5),
        ])
        let points = WeeklyUsageGraph.points(history: rows, latest: nil, in: period)
        #expect(points == [
            WeeklyUsageGraph.Point(date: weekStart.addingTimeInterval(hour), remainingPercent: 98),
            WeeklyUsageGraph.Point(date: weekStart.addingTimeInterval(3 * hour), remainingPercent: 95),
        ])
    }

    @Test func theHourThatHoldsTheResetIsDrawnFromTheStart() {
        // The week started at 5:23 PM, so its first readings land in the
        // bucket that starts at 5:00 PM — before the period does.
        let start = weekStart.addingTimeInterval(23 * 60)
        let shifted = WeeklyUsageGraph.Period(start: start, end: reset.addingTimeInterval(23 * 60))
        let points = WeeklyUsageGraph.points(history: buckets([(weekStart, 1)]), latest: nil, in: shifted)
        #expect(points.map(\.date) == [start])
    }

    @Test func readingsOutsideThePeriodAreDropped() {
        let rows = buckets([
            (weekStart.addingTimeInterval(-3 * hour), 90),
            (weekStart.addingTimeInterval(hour), 1),
            (reset.addingTimeInterval(hour), 3),
        ])
        let points = WeeklyUsageGraph.points(history: rows, latest: nil, in: period)
        #expect(points.map(\.remainingPercent) == [99])
    }

    @Test func theCardsOwnReadingEndsTheLine() {
        let rows = buckets([(now.addingTimeInterval(-2 * hour), 50)])
        let latest = WeeklyUsageGraph.Point(date: now, remainingPercent: 48)
        let points = WeeklyUsageGraph.points(history: rows, latest: latest, in: period)
        #expect(points.last == latest)
        #expect(points.count == 2)
    }

    @Test func aCardReadingOutsideThePeriodIsNotAdded() {
        let stale = WeeklyUsageGraph.Point(date: weekStart.addingTimeInterval(-day), remainingPercent: 10)
        #expect(WeeklyUsageGraph.points(history: [], latest: stale, in: period).isEmpty)
    }

    @Test func steadyHourlyReadingsAreOneLine() {
        let points = (0..<48).map {
            WeeklyUsageGraph.Point(date: weekStart.addingTimeInterval(Double($0) * hour), remainingPercent: 100 - Double($0))
        }
        #expect(WeeklyUsageGraph.segments(points).count == 1)
    }

    // TRIPWIRE #771 (issue comment): Click AI's week had no readings from
    // about Oct 18, 2 PM to Oct 21, 7 PM. The prototype drew that as one
    // sloped line, which read as steady use. It must be two lines.
    @Test func clickAIsThreeQuietDaysAreAGapNotASlope() {
        let quietFrom = date("2026-10-18T21:00:00Z")  // Oct 18, 2:00 PM PDT
        let quietTo = date("2026-10-22T02:00:00Z")    // Oct 21, 7:00 PM PDT
        let readings = hourly(from: weekStart.addingTimeInterval(hour), to: quietFrom) { _ in 30 }
            + hourly(from: quietTo, to: now) { _ in 85 }
        let points = WeeklyUsageGraph.points(history: buckets(readings), latest: nil, in: period)
        let segments = WeeklyUsageGraph.segments(points)
        #expect(segments.count == 2)
        #expect(segments.first?.last?.date == quietFrom)
        #expect(segments.last?.first?.date == quietTo)
    }

    @Test func sixHoursApartIsStillOneLineAndMoreIsAGap() {
        let first = WeeklyUsageGraph.Point(date: weekStart, remainingPercent: 100)
        let sixLater = WeeklyUsageGraph.Point(date: weekStart.addingTimeInterval(6 * hour), remainingPercent: 90)
        let longer = WeeklyUsageGraph.Point(date: sixLater.date.addingTimeInterval(6 * hour + 60), remainingPercent: 80)
        #expect(WeeklyUsageGraph.segments([first, sixLater]).count == 1)
        #expect(WeeklyUsageGraph.segments([first, sixLater, longer]) == [[first, sixLater], [longer]])
        #expect(WeeklyUsageGraph.segments([]).isEmpty)
    }
}

@Suite("Issue #771 — the pace sentence agrees with the chart")
struct Issue771WeeklyGraphPaceTests {
    private let period = WeeklyUsageGraph.Period(start: weekStart, end: reset)
    private let midweek = weekStart.addingTimeInterval(3.5 * day)

    @Test func evenPaceRunsFromFullAtTheStartToEmptyAtTheReset() {
        #expect(WeeklyUsageGraph.evenPaceRemaining(at: weekStart, in: period) == 100)
        #expect(WeeklyUsageGraph.evenPaceRemaining(at: midweek, in: period) == 50)
        #expect(WeeklyUsageGraph.evenPaceRemaining(at: reset, in: period) == 0)
    }

    @Test func moreLeftThanEvenPaceIsSlower() {
        let pace = WeeklyUsageGraph.pace(of: .init(date: midweek, remainingPercent: 70), in: period)
        #expect(pace == .slower)
        #expect(pace.sentence == "Using it slower than an even pace")
    }

    @Test func lessLeftThanEvenPaceIsFaster() {
        let pace = WeeklyUsageGraph.pace(of: .init(date: midweek, remainingPercent: 30), in: period)
        #expect(pace == .faster)
        #expect(pace.sentence == "Using it faster than an even pace")
    }

    @Test func withinFivePointsIsOnPace() {
        #expect(WeeklyUsageGraph.pace(of: .init(date: midweek, remainingPercent: 54), in: period) == .onPace)
        #expect(WeeklyUsageGraph.pace(of: .init(date: midweek, remainingPercent: 46), in: period) == .onPace)
        #expect(WeeklyUsageGraph.pace(of: .init(date: midweek, remainingPercent: 55), in: period) == .slower)
        #expect(WeeklyUsageGraph.pace(of: .init(date: midweek, remainingPercent: 45), in: period) == .faster)
        #expect(WeeklyUsageGraph.Pace.onPace.sentence == "Right about on an even pace")
    }

    // The sentence judges the latest reading where the chart draws it, not
    // against where an even pace would be now: a reading from two days ago
    // that sat on the dashed line is on pace, whatever today's line says.
    @Test func anOldReadingIsJudgedAtItsOwnTime() {
        let twoDaysIn = weekStart.addingTimeInterval(2 * day)
        let onTheLine = WeeklyUsageGraph.evenPaceRemaining(at: twoDaysIn, in: period)
        let pace = WeeklyUsageGraph.pace(of: .init(date: twoDaysIn, remainingPercent: onTheLine), in: period)
        #expect(pace == .onPace)
    }

    @Test func slowerMeansTheDotSitsAboveTheDashedLine() throws {
        let rows = buckets(hourly(from: weekStart.addingTimeInterval(hour), to: now.addingTimeInterval(-hour)) {
            $0.timeIntervalSince(weekStart) / (7 * day) * 60
        })
        let chart = try #require(WeeklyUsageGraph.chart(window: weekly(remaining: 40), history: rows, now: now, calendar: pacific))
        #expect(chart.pace == .slower)
        let size = CGSize(width: 266, height: 70)
        let dot = chart.location(of: chart.latest, in: size)
        let line = chart.location(
            of: .init(date: chart.latest.date, remainingPercent: WeeklyUsageGraph.evenPaceRemaining(at: chart.latest.date, in: chart.period)),
            in: size
        )
        #expect(dot.y < line.y)
    }

    @Test func fasterMeansTheDotSitsBelowTheDashedLine() throws {
        // Midweek with 20% left, where an even pace would leave 50%.
        let window = weekly(remaining: 20, observedAt: midweek, at: midweek)
        let chart = try #require(WeeklyUsageGraph.chart(window: window, history: [], now: midweek, calendar: pacific))
        #expect(chart.pace == .faster)
        let size = CGSize(width: 266, height: 70)
        let dot = chart.location(of: chart.latest, in: size)
        let line = chart.location(
            of: .init(date: chart.latest.date, remainingPercent: WeeklyUsageGraph.evenPaceRemaining(at: chart.latest.date, in: chart.period)),
            in: size
        )
        #expect(dot.y > line.y)
    }

    @Test func theDashedLineRunsCornerToCorner() {
        let chart = WeeklyUsageGraph.Chart(
            period: period, segments: [], latest: .init(date: now, remainingPercent: 0),
            pace: .faster, startText: "", resetText: ""
        )
        let size = CGSize(width: 266, height: 70)
        #expect(chart.location(of: .init(date: weekStart, remainingPercent: 100), in: size) == .zero)
        #expect(chart.location(of: .init(date: reset, remainingPercent: 0), in: size) == CGPoint(x: 266, y: 70))
    }
}

@Suite("Issue #771 — what the popover shows")
struct Issue771WeeklyGraphContentTests {
    @Test func aFullWeekBecomesAChartWithItsLabels() throws {
        let rows = buckets(hourly(from: weekStart.addingTimeInterval(hour), to: now.addingTimeInterval(-hour)) { _ in 30 })
        let content = WeeklyUsageGraph.content(window: weekly(remaining: 69), load: .loaded(rows), now: now, calendar: pacific)
        guard case .chart(let chart) = content else {
            Issue.record("expected a chart, got \(content)")
            return
        }
        #expect(chart.period == WeeklyUsageGraph.Period(start: weekStart, end: reset))
        #expect(chart.latest == WeeklyUsageGraph.Point(date: now, remainingPercent: 69))
        #expect(chart.startText == "Started Oct 15, 5:00 PM")
        // The card's own reset phrase, from the same helper.
        #expect(chart.resetText == "Resets in 1 hr 51 min")
        #expect(chart.pace == .slower)
    }

    @Test func noReadingsThisWeekSaysSoInsteadOfAnEmptyChart() {
        // An old daemon without observedAt, and nothing stored this week.
        let card = row("c1", provider: "claude", [
            UsageSnapshot(accountId: "c1", scope: "weekly", remainingPercent: 60, resetsAt: iso(reset)),
        ])
        let window = WeeklyUsageGraph.window(for: card)!
        let content = WeeklyUsageGraph.content(window: window, load: .loaded([]), now: now, calendar: pacific)
        #expect(content == .message("No readings this week yet"))
    }

    @Test func aWeekThatHasNotStartedSaysNoReadingsWithoutAsking() {
        let fresh = weekly(remaining: 100, resetsAt: now.addingTimeInterval(7 * day))
        #expect(WeeklyUsageGraph.request(accountID: "c1", window: fresh, now: now) == nil)
        #expect(WeeklyUsageGraph.content(window: fresh, load: nil, now: now) == .message(WeeklyUsageGraph.noReadingsText))
    }

    @Test func whileTheReadIsRunningItSaysLoading() {
        #expect(WeeklyUsageGraph.content(window: weekly(remaining: 40), load: nil, now: now) == .loading)
        #expect(WeeklyUsageGraph.content(window: weekly(remaining: 40), load: .loading, now: now) == .loading)
    }

    @Test func aFailedReadSaysSo() {
        let content = WeeklyUsageGraph.content(window: weekly(remaining: 40), load: .failed, now: now)
        #expect(content == .message("Couldn't load this week's readings"))
    }

    @Test func theRequestCoversThisWindowsPeriod() {
        let request = WeeklyUsageGraph.request(accountID: "c1", window: weekly(remaining: 40), now: now)
        #expect(request == WeeklyUsageGraphModel.Request(
            accountID: "c1",
            scope: "weekly",
            period: WeeklyUsageGraph.Period(start: weekStart, end: reset)
        ))
    }
}

/// Records every read; answers from a queue (an error, or rows). Like
/// URLSession, it gives up when the task asking is cancelled.
private actor HistoryStub: UsageHistoryProviding {
    struct Call: Equatable {
        var accountID: String
        var scope: String
        var since: Date
        var until: Date
    }

    private(set) var calls: [Call] = []
    private var answers: [Result<[UsageHistoryBucket], Error>]

    init(_ answers: [Result<[UsageHistoryBucket], Error>]) {
        self.answers = answers
    }

    func usageHistory(accountID: String, scope: String, since: Date, until: Date) async throws -> [UsageHistoryBucket] {
        calls.append(Call(accountID: accountID, scope: scope, since: since, until: until))
        try Task.checkCancellation()
        guard !answers.isEmpty else { throw URLError(.cannotConnectToHost) }
        return try answers.removeFirst().get()
    }
}

/// Reads are numbered from 1. The `held` read waits until released, so a test
/// can look at the model mid-read; the `failing` reads throw; every other
/// read answers at once (a second read during the held one shows up as a
/// second call, not a hang).
private actor HeldHistory: UsageHistoryProviding {
    private(set) var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private let rows: [UsageHistoryBucket]
    private let held: Int
    private let failing: Set<Int>

    init(_ rows: [UsageHistoryBucket], held: Int = 1, failing: Set<Int> = []) {
        self.rows = rows
        self.held = held
        self.failing = failing
    }

    func usageHistory(accountID: String, scope: String, since: Date, until: Date) async throws -> [UsageHistoryBucket] {
        calls += 1
        let call = calls
        if call == held, !isReleased {
            await withCheckedContinuation { gate = $0 }
        }
        if failing.contains(call) { throw URLError(.timedOut) }
        return rows
    }

    func release() {
        isReleased = true
        gate?.resume()
        gate = nil
    }
}

@MainActor
private final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@Suite("Issue #771 — read on open, cached for a few minutes, never polled")
@MainActor
struct Issue771WeeklyGraphModelTests {
    private let request = WeeklyUsageGraphModel.Request(
        accountID: "c1",
        scope: "weekly",
        period: WeeklyUsageGraph.Period(start: weekStart, end: reset)
    )
    private let rows = [UsageHistoryBucket(bucketStart: "2026-10-22T21:00:00.000Z", lastUsedPercent: 31)]

    @Test func asksForThisWeekSoFar() async {
        let stub = HistoryStub([.success(rows)])
        let model = WeeklyUsageGraphModel(provider: stub, now: { now })
        await model.open(request)
        #expect(await stub.calls == [.init(accountID: "c1", scope: "weekly", since: weekStart, until: now)])
        #expect(model.load(for: request) == .loaded(rows))
    }

    // Pinned in minutes, not via the constant, so the lifetime itself is held.
    @Test func aReadIsReusedForFiveMinutesThenReadAgain() async {
        let clock = Clock(now)
        let stub = HistoryStub([.success(rows), .success([])])
        let model = WeeklyUsageGraphModel(provider: stub, now: { clock.now })
        await model.open(request)
        clock.now = now.addingTimeInterval(4 * 60 + 59)
        await model.open(request)
        #expect(await stub.calls.count == 1)
        clock.now = now.addingTimeInterval(5 * 60 + 1)
        await model.open(request)
        #expect(await stub.calls.count == 2)
        #expect(model.load(for: request) == .loaded([]))
    }

    // TRIPWIRE (PR #773 review): providers recompute resetsAt on every poll,
    // so it drifts by fractions of a second (median ~344 ms in the daemon's
    // data; 441 distinct values in 495 Claude weekly snapshots). A drift is
    // the same week: the same key, no second read, and an open popover keeps
    // its chart instead of dropping to a spinner and reading again.
    @Test func aResetThatOnlyDriftsKeepsItsKeyAndItsChart() async throws {
        let clock = Clock(now)
        let stub = HistoryStub([.success(rows)])
        let model = WeeklyUsageGraphModel(provider: stub, now: { clock.now })
        let first = try #require(WeeklyUsageGraph.request(accountID: "c1", window: weekly(remaining: 40), now: now))
        await model.open(first)

        let later = now.addingTimeInterval(60)
        clock.now = later
        let drifted = weekly(remaining: 39, resetsAt: reset.addingTimeInterval(0.344), observedAt: later, at: later)
        let second = try #require(WeeklyUsageGraph.request(accountID: "c1", window: drifted, now: later))
        #expect(model.key(for: second) == model.key(for: first))
        guard case .chart = WeeklyUsageGraph.content(window: drifted, load: model.load(for: second), now: later) else {
            Issue.record("a drifted reset replaced the chart")
            return
        }
        await model.open(second)
        #expect(await stub.calls.count == 1)
    }

    @Test func aFailedRefreshAfterADriftKeepsTheLastGoodRead() async throws {
        let clock = Clock(now)
        let stub = HistoryStub([.success(rows), .failure(URLError(.timedOut))])
        let model = WeeklyUsageGraphModel(provider: stub, now: { clock.now })
        let first = try #require(WeeklyUsageGraph.request(accountID: "c1", window: weekly(remaining: 40), now: now))
        await model.open(first)

        let later = now.addingTimeInterval(5 * 60 + 1)
        clock.now = later
        let drifted = weekly(remaining: 39, resetsAt: reset.addingTimeInterval(-0.7), observedAt: later, at: later)
        let second = try #require(WeeklyUsageGraph.request(accountID: "c1", window: drifted, now: later))
        await model.open(second)
        #expect(await stub.calls.count == 2)
        #expect(model.load(for: second) == .loaded(rows))
    }

    // The daemon's own line between drift and a real reset
    // (RESET_MARKER_TOLERANCE_MS, src/usage-estimate.mjs).
    @Test func aResetThatMovesMoreThanFiveMinutesIsANewWeek() async throws {
        let stub = HistoryStub([.success(rows), .success([])])
        let model = WeeklyUsageGraphModel(provider: stub, now: { now })
        let first = try #require(WeeklyUsageGraph.request(accountID: "c1", window: weekly(remaining: 40), now: now))
        await model.open(first)
        let moved = try #require(WeeklyUsageGraph.request(
            accountID: "c1",
            window: weekly(remaining: 40, resetsAt: reset.addingTimeInterval(5 * 60 + 1)),
            now: now
        ))
        #expect(model.key(for: moved) != model.key(for: first))
        await model.open(moved)
        #expect(await stub.calls.count == 2)
        #expect(model.load(for: moved) == .loaded([]))
    }

    // PR #773 fix review: a retry after a failed read shows the spinner while
    // it reads, not "Couldn't load" for up to the 60 s read timeout.
    @Test func aRetryAfterAFailureShowsLoadingWhileItReads() async {
        let stub = HeldHistory(rows, held: 2, failing: [1])
        let model = WeeklyUsageGraphModel(provider: stub, now: { now })
        await model.open(request)
        #expect(model.load(for: request) == .failed)
        let retry = Task { await model.open(request) }
        while await stub.calls < 2 { await Task.yield() }
        #expect(model.load(for: request) == .loading)
        await stub.release()
        await retry.value
        #expect(model.load(for: request) == .loaded(rows))
    }

    // A refresh that has good rows keeps showing them while it reads.
    @Test func aRefreshKeepsTheChartWhileItReads() async {
        let clock = Clock(now)
        let stub = HeldHistory(rows, held: 2)
        let model = WeeklyUsageGraphModel(provider: stub, now: { clock.now })
        await model.open(request)
        clock.now = now.addingTimeInterval(5 * 60 + 1)
        let refresh = Task { await model.open(request) }
        while await stub.calls < 2 { await Task.yield() }
        #expect(model.load(for: request) == .loaded(rows))
        await stub.release()
        await refresh.value
    }

    @Test func aQuickReopenDuringAReadMakesOneCall() async {
        let stub = HeldHistory(rows)
        let model = WeeklyUsageGraphModel(provider: stub, now: { now })
        let first = Task { await model.open(request) }
        while await stub.calls == 0 { await Task.yield() }
        await model.open(request)
        #expect(await stub.calls == 1)
        #expect(model.load(for: request) == .loading)
        await stub.release()
        await first.value
        #expect(model.load(for: request) == .loaded(rows))
    }

    @Test func aFailedReadShowsAndTheNextOpenTriesAgain() async {
        let stub = HistoryStub([.failure(URLError(.timedOut)), .success(rows)])
        let model = WeeklyUsageGraphModel(provider: stub, now: { now })
        await model.open(request)
        #expect(model.load(for: request) == .failed)
        await model.open(request)
        #expect(model.load(for: request) == .loaded(rows))
        #expect(await stub.calls.count == 2)
    }

    @Test func aFailedRefreshKeepsTheLastGoodRead() async {
        let clock = Clock(now)
        let stub = HistoryStub([.success(rows), .failure(URLError(.timedOut))])
        let model = WeeklyUsageGraphModel(provider: stub, now: { clock.now })
        await model.open(request)
        clock.now = now.addingTimeInterval(WeeklyUsageGraphModel.cacheLifetime + 1)
        await model.open(request)
        #expect(model.load(for: request) == .loaded(rows))
    }

    @Test func aNewWeekIsReadOnItsOwnAndTheOldOneLetGo() async {
        let clock = Clock(now)
        let stub = HistoryStub([.success(rows), .success([])])
        let model = WeeklyUsageGraphModel(provider: stub, now: { clock.now })
        await model.open(request)
        clock.now = reset.addingTimeInterval(hour)
        var nextWeek = request
        nextWeek.period = WeeklyUsageGraph.Period(start: reset, end: reset.addingTimeInterval(7 * day))
        await model.open(nextWeek)
        #expect(await stub.calls.count == 2)
        #expect(model.load(for: nextWeek) == .loaded([]))
        #expect(model.load(for: request) == nil)
    }

    // Closing the popover cancels its view task. The read must finish anyway:
    // a reopen that arrives while it runs waits on it rather than reading
    // twice, and a cancelled read that cleared the slot would strand that
    // reopen on a spinner.
    @Test func closingThePopoverMidReadStillKeepsTheRead() async {
        let stub = HistoryStub([.success(rows)])
        let model = WeeklyUsageGraphModel(provider: stub, now: { now })
        let opening = Task { await model.open(request) }
        opening.cancel()
        await opening.value
        #expect(model.load(for: request) == .loaded(rows))
        #expect(await stub.calls.count == 1)
    }

    @Test func withoutADaemonTheReadFails() async {
        let model = WeeklyUsageGraphModel(provider: nil, now: { now })
        await model.open(request)
        #expect(model.load(for: request) == .failed)
    }
}

@Suite("Issue #771 — the deck wiring")
@MainActor
struct Issue771WeeklyGraphDeckTests {
    @Test func anOpenGraphSurvivesARefreshWhileItsCardHasAWeekly() {
        let claude = row("c1", provider: "claude", [snapshot("c1", scope: "weekly", remaining: 40, resetsAt: reset)])
        let grok = row("g1", provider: "grok", [snapshot("g1", scope: "monthly", remaining: 60, resetsAt: reset)])
        let live = DeckPopoverModel.liveWarningIDs(rows: [claude, grok], staleness: { _ in nil }, cadenceNoticeVisible: false)
        #expect(live.contains(DeckWarningID(topic: .weeklyGraph, elementID: "c1")))
        #expect(!live.contains(DeckWarningID(topic: .weeklyGraph, elementID: "g1")))

        let model = DeckPopoverModel(defaults: ScratchDefaults.make("issue-771-graph"))
        model.usageAnalyticsDashboardURL = UsageAnalytics.dashboardURL(base: DaemonConfiguration().baseURL)
        let graph = DeckWarningID(topic: .weeklyGraph, elementID: "c1")
        model.toggleWarning(graph)
        model.reconcileWarnings(rows: [claude, grok], staleness: { _ in nil }, cadenceNoticeVisible: false)
        #expect(model.isWarningPresented(graph))
        model.reconcileWarnings(rows: [grok], staleness: { _ in nil }, cadenceNoticeVisible: false)
        #expect(!model.isWarningPresented(graph))

        // Turning analytics off takes the graph with it on the next refresh.
        model.toggleWarning(graph)
        model.usageAnalyticsDashboardURL = nil
        model.reconcileWarnings(rows: [claude, grok], staleness: { _ in nil }, cadenceNoticeVisible: false)
        #expect(!model.isWarningPresented(graph))
    }

    private func deck(analytics: Bool) -> DeckPopoverModel {
        let model = DeckPopoverModel(defaults: ScratchDefaults.make("issue-771-offer"))
        model.usageAnalyticsDashboardURL = analytics
            ? UsageAnalytics.dashboardURL(base: DaemonConfiguration().baseURL)
            : nil
        return model
    }

    private let claude = row("c1", provider: "claude", [
        snapshot("c1", scope: "5-hour", remaining: 30, resetsAt: now.addingTimeInterval(2 * hour)),
        snapshot("c1", scope: "weekly", remaining: 40, resetsAt: reset),
    ])

    // PR #773 review: with "Enable the usage analytics dashboard" off, the
    // daemon answers every /api/usage/* route 404 (src/server.mjs), so a
    // graph could only ever say it couldn't load. No offer then.
    @Test func withAnalyticsOffNoCardOffersAGraph() {
        #expect(deck(analytics: false).weeklyGraphOffer(for: claude, isExpanded: false) == nil)
        #expect(deck(analytics: false).weeklyGraphOffer(for: claude, isExpanded: true) == nil)
    }

    @Test func aWeeklyReadingWithNoResetOffersNothing() {
        let noReset = row("c2", provider: "claude", [snapshot("c2", scope: "weekly", remaining: 47, resetsAt: nil)])
        #expect(deck(analytics: true).weeklyGraphOffer(for: noReset, isExpanded: false) == nil)
    }

    // The 5-hour figure leads this card (it is the lower one), yet the
    // headline is still the way into the weekly graph: by design (Tim sees
    // it in the screenshots).
    @Test func collapsedTheHeadlineOpensTheWeeklyGraph() throws {
        let offer = try #require(deck(analytics: true).weeklyGraphOffer(for: claude, isExpanded: false))
        #expect(offer.window.scope == "weekly")
        #expect(offer.trigger == .headline)
        #expect(claude.worstWindow?.scope == "5-hour")
    }

    @Test func expandedOnlyTheWeeklyRowOpensIt() throws {
        let offer = try #require(deck(analytics: true).weeklyGraphOffer(for: claude, isExpanded: true))
        #expect(offer.window.scope == "weekly")
        #expect(offer.trigger == .row(scope: "weekly"))
        #expect(offer.trigger != .row(scope: "5-hour"))
    }

    @Test func aGrokCardOffersNothing() {
        let grok = row("g1", provider: "grok", [snapshot("g1", scope: "weekly", remaining: 60, resetsAt: reset)])
        #expect(deck(analytics: true).weeklyGraphOffer(for: grok, isExpanded: false) == nil)
    }

    @Test func theDaemonReadIsOneHourlyGETWithNoToken() async throws {
        let body = #"""
        {"accountId":"acct-1","scope":"Fable+1 weekly","since":"2026-10-16T00:00:00.000Z","until":"2026-10-22T22:09:00.000Z","bucket":"hour",
         "rows":[{"bucketStart":"2026-10-22T21:00:00.000Z","lastUsedPercent":31,"minUsedPercent":30,"maxUsedPercent":31,"resetsAtValues":["2026-10-23T00:00:00.000Z"]},
                 {"bucketStart":"2026-10-22T20:00:00.000Z","lastUsedPercent":null,"minUsedPercent":null,"maxUsedPercent":null,"resetsAtValues":[]}],
         "truncated":false}
        """#
        let transport = StubTransport(stubs: [.init(status: 200, body: body)])
        let client = DaemonClient(configuration: DaemonConfiguration(), transport: transport)
        let rows = try await client.usageHistory(accountID: "acct-1", scope: "Fable+1 weekly", since: weekStart, until: now)
        #expect(rows == [
            UsageHistoryBucket(bucketStart: "2026-10-22T21:00:00.000Z", lastUsedPercent: 31),
            UsageHistoryBucket(bucketStart: "2026-10-22T20:00:00.000Z", lastUsedPercent: nil),
        ])
        #expect(transport.requests.count == 1)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/usage/history")
        #expect(request.value(forHTTPHeaderField: "x-modeldeck-token") == nil)
        // A literal "+" would reach the daemon's URLSearchParams as a space.
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedQuery?.contains("scope=Fable%2B1%20weekly") == true)
        let items = try #require(components.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(values["accountId"] == "acct-1")
        #expect(values["since"] == "2026-10-16T00:00:00Z")
        #expect(values["until"] == "2026-10-22T22:09:00Z")
        #expect(values["bucket"] == "hour")
    }
}
