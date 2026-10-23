import Foundation

// Issue #771 — the "This week" graph. Tim, 2026-10-22, after the phone deck
// prototype: "I really love that graph … I would really love for it to be
// built into the desktop app as well." For a card's all-models weekly: the
// % left across the current reset period, a dashed even-pace line from 100%
// at the period's start to 0% at its reset, a dot at the latest reading, and
// one plain sentence saying which side of that line the dot sits on.
//
// Tim picked the placement from the 2026-10-22 mockups: a popover beside the
// card, so the deck never changes size. The readings are the daemon's
// existing `GET /api/usage/history`, read when the popover opens and kept a
// few minutes; nothing polls in the background.
//
// What the chart claims is decided here, pure, so the sentence, the gaps and
// the period are unit tests rather than screenshots.

/// One stored hour of a window's readings: `GET /api/usage/history` with
/// `bucket=hour` (src/db.mjs `bucketUsageHistory`). Only the fields the graph
/// reads, both optional, so an odd row is skipped rather than failing the read.
public struct UsageHistoryBucket: Codable, Equatable, Sendable {
    /// Start of the hour, ISO 8601.
    public var bucketStart: String?
    /// The hour's newest reading, as % used.
    public var lastUsedPercent: Double?

    public init(bucketStart: String? = nil, lastUsedPercent: Double? = nil) {
        self.bucketStart = bucketStart
        self.lastUsedPercent = lastUsedPercent
    }
}

/// The daemon read behind the graph. `DaemonClient` conforms; tests stub it.
public protocol UsageHistoryProviding: Sendable {
    func usageHistory(
        accountID: String,
        scope: String,
        since: Date,
        until: Date
    ) async throws -> [UsageHistoryBucket]
}

public enum WeeklyUsageGraph {
    /// Readings further apart than this draw as a gap, never as a straight
    /// line across it: Click AI's week had about three days with no readings,
    /// and the prototype's sloped segment over them read as steady use.
    public static let maxGap: TimeInterval = 6 * 3600

    /// Points of % left either side of the even-pace line that still count
    /// as on pace (the prototype's band).
    public static let onPaceBand: Double = 5

    public static let noReadingsText = "No readings this week yet"
    public static let loadFailedText = "Couldn't load this week's readings"

    /// The window's current reset period.
    public struct Period: Hashable, Sendable {
        public var start: Date
        public var end: Date

        public init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }
    }

    /// One reading, as % left.
    public struct Point: Equatable, Sendable {
        public var date: Date
        public var remainingPercent: Double

        public init(date: Date, remainingPercent: Double) {
            self.date = date
            self.remainingPercent = remainingPercent
        }
    }

    /// Which side of the even-pace line the latest reading sits on.
    public enum Pace: Equatable, Sendable {
        case slower
        case onPace
        case faster

        /// The prototype's wording, which Tim saw and liked.
        public var sentence: String {
            switch self {
            case .slower: return "Using it slower than an even pace"
            case .onPace: return "Right about on an even pace"
            case .faster: return "Using it faster than an even pace"
            }
        }
    }

    /// Everything the chart draws.
    public struct Chart: Equatable, Sendable {
        public var period: Period
        /// Runs of readings with no gap longer than `maxGap` inside them.
        public var segments: [[Point]]
        /// The newest reading: the dot, and what the sentence judges.
        public var latest: Point
        public var pace: Pace
        /// "Started Oct 15, 5:00 PM".
        public var startText: String
        /// The card's own reset phrase, e.g. "Resets in 1 hr 51 min".
        public var resetText: String

        public init(
            period: Period,
            segments: [[Point]],
            latest: Point,
            pace: Pace,
            startText: String,
            resetText: String
        ) {
            self.period = period
            self.segments = segments
            self.latest = latest
            self.pace = pace
            self.startText = startText
            self.resetText = resetText
        }

        /// Where a reading sits in a plot of `size`: the period's start at the
        /// left edge and its reset at the right, 100% left at the top and 0%
        /// at the bottom. The even-pace line is the diagonal from
        /// (start, 100%) to (reset, 0%).
        public func location(of point: Point, in size: CGSize) -> CGPoint {
            let span = period.end.timeIntervalSince(period.start)
            let x = span > 0 ? point.date.timeIntervalSince(period.start) / span : 0
            let y = 1 - point.remainingPercent / 100
            return CGPoint(
                x: min(max(x, 0), 1) * size.width,
                y: min(max(y, 0), 1) * size.height
            )
        }

        /// What VoiceOver reads for the plot; the sentence follows as text.
        public var accessibilityLabel: String {
            let left = Int(latest.remainingPercent.rounded())
            let even = Int(WeeklyUsageGraph.evenPaceRemaining(at: latest.date, in: period).rounded())
            return "This week: \(left)% left at the latest reading, where an even pace would leave \(even)%."
        }
    }

    /// What the popover shows.
    public enum Content: Equatable, Sendable {
        case loading
        case message(String)
        case chart(Chart)
    }

    /// How a card offers its graph (`DeckPopoverModel.weeklyGraphOffer`):
    /// the window drawn, and which of the card's numbers opens it. Only Core
    /// makes one (the initializer is internal), so a card can't skip the gate.
    public struct Offer: Equatable, Sendable {
        /// The number that opens the graph.
        public enum Trigger: Hashable, Sendable {
            /// The collapsed card's headline "% left".
            case headline
            /// An expanded card's row for this window (the headline is
            /// hidden once a card expands).
            case row(scope: String)
        }

        public var window: DeckWindow
        public var trigger: Trigger
    }

    /// The window the graph draws: a Claude or Codex card's all-models
    /// weekly. A reading with no reset has no week to draw it against, so it
    /// offers no graph; an untouched week (no reset reported either) still
    /// does, and says its week hasn't started. Internal on purpose: cards ask
    /// `DeckPopoverModel.weeklyGraphOffer`, which also applies the analytics
    /// gate.
    static func window(for row: DeckAccountRow) -> DeckWindow? {
        guard row.provider == .claude || row.provider == .codex,
              let weekly = row.windows.first(where: {
                  MenuBarPinResolver.PinWindow.generalWeekly.matches(scope: $0.scope)
              })
        else { return nil }
        if case .unanchored = weekly.anchor { return weekly }
        return weekly.resetsAt == nil ? nil : weekly
    }

    /// The window's current reset period: its length back from `resetsAt`, up
    /// to `resetsAt`. Nil when there is no current period to draw — a week
    /// that hasn't started (no use since the last reset, so the provider's
    /// reset time is only a placeholder) or one that ended since the window's
    /// last reading.
    public static func period(for window: DeckWindow, now: Date) -> Period? {
        if case .unanchored = window.anchor { return nil }
        guard window.idleRollforward == nil,
              let end = window.resetsAt, end > now,
              let length = WindowPresentation.windowDuration(scope: window.scope, detailMinutes: nil)
        else { return nil }
        let start = end.addingTimeInterval(-length)
        guard start < now else { return nil }
        return Period(start: start, end: end)
    }

    /// What the popover asks the daemon for; nil when there is no period.
    public static func request(
        accountID: String,
        window: DeckWindow,
        now: Date
    ) -> WeeklyUsageGraphModel.Request? {
        period(for: window, now: now).map {
            WeeklyUsageGraphModel.Request(accountID: accountID, scope: window.scope, period: $0)
        }
    }

    /// Where an even pace would leave the window at `date`: 100% at the
    /// period's start, falling in a straight line to 0% at its reset.
    public static func evenPaceRemaining(at date: Date, in period: Period) -> Double {
        let span = period.end.timeIntervalSince(period.start)
        guard span > 0 else { return 0 }
        return 100 * min(max(period.end.timeIntervalSince(date) / span, 0), 1)
    }

    /// Which side of the even-pace line a reading sits on, judged at the
    /// reading's own time — where the chart draws its dot — so the sentence
    /// and the picture always agree.
    public static func pace(of point: Point, in period: Period) -> Pace {
        let ahead = point.remainingPercent - evenPaceRemaining(at: point.date, in: period)
        if ahead >= onPaceBand { return .slower }
        if ahead <= -onPaceBand { return .faster }
        return .onPace
    }

    /// The period's readings, oldest first, as % left. The hour holding the
    /// period's start begins before it, so it is drawn from the start. The
    /// card's own reading (`latest`) ends the line when it is the newest.
    public static func points(
        history: [UsageHistoryBucket],
        latest: Point?,
        in period: Period
    ) -> [Point] {
        var points = history
            .compactMap { bucket -> Point? in
                guard let date = DeckDateParsing.date(from: bucket.bucketStart),
                      let used = bucket.lastUsedPercent,
                      date >= period.start.addingTimeInterval(-3600),
                      date <= period.end
                else { return nil }
                return Point(date: max(date, period.start), remainingPercent: min(max(100 - used, 0), 100))
            }
            .sorted { $0.date < $1.date }
        if let latest, latest.date >= period.start, latest.date <= period.end,
           latest.date >= points.last?.date ?? period.start {
            points.append(latest)
        }
        return points
    }

    /// Splits readings wherever two neighbors are more than `maxGap` apart,
    /// so a stretch with no readings draws as a gap.
    public static func segments(_ points: [Point]) -> [[Point]] {
        var segments: [[Point]] = []
        for point in points {
            if let previous = segments.last?.last,
               point.date.timeIntervalSince(previous.date) <= maxGap {
                segments[segments.count - 1].append(point)
            } else {
                segments.append([point])
            }
        }
        return segments
    }

    /// The chart for a window and its stored hours, or nil when the period
    /// has no readings at all (the popover then says so in one line).
    public static func chart(
        window: DeckWindow,
        history: [UsageHistoryBucket],
        now: Date,
        calendar: Calendar = .current
    ) -> Chart? {
        guard let period = Self.period(for: window, now: now) else { return nil }
        var latest: Point?
        if let observedAt = window.observedAt, let remaining = window.remainingPercent {
            latest = Point(date: observedAt, remainingPercent: remaining)
        }
        let readings = points(history: history, latest: latest, in: period)
        guard let newest = readings.last else { return nil }
        return Chart(
            period: period,
            segments: segments(readings),
            latest: newest,
            pace: pace(of: newest, in: period),
            startText: startText(for: period.start, calendar: calendar),
            resetText: DeckBuilder.resetText(for: period.end, now: now, calendar: calendar)
        )
    }

    /// What the popover shows for a window, given where its read stands.
    public static func content(
        window: DeckWindow,
        load: WeeklyUsageGraphModel.Load?,
        now: Date,
        calendar: Calendar = .current
    ) -> Content {
        guard period(for: window, now: now) != nil else { return .message(noReadingsText) }
        switch load {
        case nil, .loading?:
            return .loading
        case .failed?:
            return .message(loadFailedText)
        case .loaded(let rows)?:
            return chart(window: window, history: rows, now: now, calendar: calendar)
                .map(Content.chart) ?? .message(noReadingsText)
        }
    }

    /// "Started Oct 15, 5:00 PM": local time with no zone, like every time
    /// on the deck (#137), set up the way `DeckBuilder.resetText` is.
    public static func startText(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateFormat = "MMM d, h:mm a"
        return "Started \(formatter.string(from: date))"
    }
}

/// Reads a window's history when its graph opens and keeps it a few minutes,
/// so reopening is instant and nothing is ever polled.
@MainActor
public final class WeeklyUsageGraphModel: ObservableObject {
    public enum Load: Equatable, Sendable {
        case loading
        case loaded([UsageHistoryBucket])
        case failed
    }

    /// What the popover asks for: one window's current week.
    public struct Request: Hashable, Sendable {
        public var accountID: String
        public var scope: String
        public var period: WeeklyUsageGraph.Period

        public init(accountID: String, scope: String, period: WeeklyUsageGraph.Period) {
            self.accountID = accountID
            self.scope = scope
            self.period = period
        }
    }

    /// What a read is kept under: the window, and the end of its week as
    /// first read.
    public struct Key: Hashable, Sendable {
        public var accountID: String
        public var scope: String
        public var weekEnd: Date
    }

    /// How long a read is reused before the next open reads again.
    public static let cacheLifetime: TimeInterval = 5 * 60

    /// Resets this close together are the same week. Providers recompute
    /// `resetsAt` on every poll, so it drifts by fractions of a second, while
    /// a real reset moves it by the window's length. The daemon draws the same
    /// line (RESET_MARKER_TOLERANCE_MS, src/usage-estimate.mjs).
    public static let resetTolerance: TimeInterval = 5 * 60

    private struct Entry {
        var load: Load
        var readAt: Date?
        var isReading = false
    }

    @Published private var entries: [Key: Entry] = [:]
    private let provider: (any UsageHistoryProviding)?
    private let now: () -> Date

    public init(provider: (any UsageHistoryProviding)? = nil, now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    /// The key a request reads under: the one already held for its window
    /// while the reset has only drifted, a new one when the week is new.
    public func key(for request: Request) -> Key {
        entries.keys.first {
            $0.accountID == request.accountID && $0.scope == request.scope
                && abs($0.weekEnd.timeIntervalSince(request.period.end)) <= Self.resetTolerance
        } ?? Key(accountID: request.accountID, scope: request.scope, weekEnd: request.period.end)
    }

    public func load(for request: Request) -> Load? {
        entries[key(for: request)]?.load
    }

    /// The popover opened: read the week so far, unless a fresh read is
    /// cached or one is already running. The read runs in its own task, so
    /// closing the popover never abandons it: a quick reopen finds it running
    /// and the result is kept for the next look.
    public func open(_ request: Request) async {
        let key = self.key(for: request)
        if let entry = entries[key] {
            if entry.isReading { return }
            if let at = entry.readAt, now().timeIntervalSince(at) < Self.cacheLifetime { return }
        } else {
            // A new week for this window: the old week's read goes.
            let older = entries.keys.filter { $0.accountID == key.accountID && $0.scope == key.scope }
            for old in older { entries[old] = nil }
        }
        guard let provider else {
            entries[key] = Entry(load: .failed)
            return
        }
        var starting = entries[key] ?? Entry(load: .loading)
        // Good rows stay on screen while they refresh; a first read or a
        // retry after a failure shows the spinner.
        if case .loaded = starting.load {} else { starting.load = .loading }
        starting.isReading = true
        entries[key] = starting
        let until = now()
        let read = Task {
            try await provider.usageHistory(
                accountID: request.accountID,
                scope: request.scope,
                since: request.period.start,
                until: until
            )
        }
        let result = await read.result
        // A newer week may have replaced this one during the read.
        guard var entry = entries[key] else { return }
        entry.isReading = false
        switch result {
        case .success(let rows):
            entry.load = .loaded(rows)
            entry.readAt = now()
        case .failure:
            // A failed refresh keeps the last good read on screen.
            if case .loaded = entry.load {} else { entry.load = .failed }
        }
        entries[key] = entry
    }
}
