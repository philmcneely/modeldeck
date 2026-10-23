import AppKit
import SwiftUI
import Testing
import ModelDeckMacCore
@testable import ModelDeckMac

// Issue #771 tripwires (PR #773 reviews) on the real card and popover views,
// rendered in a hosting view with no window.

/// The reviewer's case: the longest label and its plan tier, the menu bar
/// checkmark, and the bare routing glyph of an account outside the pool,
/// with a 5-hour window lower than its weekly.
private func card(provider: String) -> DeckAccountRow {
    let now = Date()
    let iso = ISO8601DateFormatter()
    let account = DeckAccount(
        id: "c1",
        provider: provider,
        label: "Business Account",
        identity: "c1@example.com",
        metadata: DeckAccountMetadata(
            claudePlan: ProviderPlanInfo(subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
        ),
        proxyPool: "absent"
    )
    let weekly = UsageSnapshot(
        accountId: "c1",
        scope: "weekly",
        remainingPercent: 47,
        resetsAt: iso.string(from: now.addingTimeInterval(2 * 86_400)),
        observedAt: iso.string(from: now)
    )
    // Lower than the weekly, so it is the collapsed card's headline.
    let fiveHour = UsageSnapshot(
        accountId: "c1",
        scope: "5-hour",
        remainingPercent: 30,
        resetsAt: iso.string(from: now.addingTimeInterval(2 * 3600)),
        observedAt: iso.string(from: now)
    )
    return DeckBuilder.rows(state: DeckState(accounts: [account], usage: [fiveHour, weekly]), now: now)[0]
}

/// A deck model on a throwaway defaults suite under $TMPDIR, never
/// ~/Library/Preferences. With analytics on, the daemon serves usage history.
@MainActor
private func withDeck<T>(analytics: Bool = true, _ body: (DeckPopoverModel) -> T) -> T {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("modeldeck-771-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let deck = DeckPopoverModel(defaults: UserDefaults(suiteName: folder.appendingPathComponent("deck").path)!)
    deck.usageAnalyticsDashboardURL = analytics
        ? UsageAnalytics.dashboardURL(base: DaemonConfiguration().baseURL)
        : nil
    return body(deck)
}

@MainActor
private func cardView(_ row: DeckAccountRow, deck: DeckPopoverModel, isExpanded: Bool) -> DeckAccountRowView {
    DeckAccountRowView(
        row: row,
        deckModel: deck,
        showsProviderMark: false,
        isMenuBarSource: true,
        isExpanded: isExpanded,
        onToggle: {}
    )
}

/// The trigger may add no width to a card. The first build put a 21 pt chart
/// icon on the top line, which cut "Business Account · Max (20x)" short once a
/// second marker showed, against the #30 rule that nothing on a card
/// truncates. The card is compared with the identical card on a provider that
/// never has a graph, which is the card exactly as main draws it.
@MainActor
struct Issue771GraphTriggerWidthTests {
    private func width(of row: DeckAccountRow, isExpanded: Bool) -> CGFloat {
        withDeck { deck in
            NSHostingView(rootView: cardView(row, deck: deck, isExpanded: isExpanded).fixedSize()).fittingSize.width
        }
    }

    @Test func theGraphTriggerAddsNoWidthToTheCard() {
        let withGraph = card(provider: "claude")
        let withoutGraph = card(provider: "grok")
        withDeck { deck in
            #expect(deck.weeklyGraphOffer(for: withGraph, isExpanded: false) != nil)
            #expect(deck.weeklyGraphOffer(for: withoutGraph, isExpanded: false) == nil)
        }
        #expect(withGraph.account.planLabel == "Max (20x)")
        #expect(withGraph.proxyWeightPresentation?.absentFromPool == true)
        #expect(width(of: withGraph, isExpanded: false) == width(of: withoutGraph, isExpanded: false))
    }

    @Test func norToTheExpandedCard() {
        #expect(width(of: card(provider: "claude"), isExpanded: true) == width(of: card(provider: "grok"), isExpanded: true))
    }
}

/// Which of the card's numbers opens the graph, read from what the card
/// actually renders: the collapsed card's headline, and on an expanded card
/// the weekly row and no other. Nothing at all with analytics off.
@MainActor
struct Issue771GraphTriggerPlacementTests {
    @MainActor
    private final class Slots {
        var value: [WeeklyUsageGraph.Offer.Trigger] = []
    }

    private func triggers(_ row: DeckAccountRow, isExpanded: Bool, analytics: Bool = true) -> [WeeklyUsageGraph.Offer.Trigger] {
        withDeck(analytics: analytics) { deck in
            let slots = Slots()
            let view = cardView(row, deck: deck, isExpanded: isExpanded)
                .onPreferenceChange(WeeklyGraphTriggerSlots.self) { value in
                    MainActor.assumeIsolated { slots.value = value }
                }
            let host = NSHostingView(rootView: view.frame(width: 300))
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            return slots.value
        }
    }

    @Test func collapsedTheHeadlineCarriesTheTrigger() {
        #expect(triggers(card(provider: "claude"), isExpanded: false) == [.headline])
    }

    @Test func expandedOnlyTheWeeklyRowCarriesIt() {
        #expect(triggers(card(provider: "claude"), isExpanded: true) == [.row(scope: "weekly")])
    }

    @Test func withAnalyticsOffNoNumberCarriesIt() {
        #expect(triggers(card(provider: "claude"), isExpanded: false, analytics: false).isEmpty)
        #expect(triggers(card(provider: "claude"), isExpanded: true, analytics: false).isEmpty)
    }

    @Test func aCardWithNoGraphCarriesNone() {
        #expect(triggers(card(provider: "grok"), isExpanded: false).isEmpty)
        #expect(triggers(card(provider: "grok"), isExpanded: true).isEmpty)
    }
}

/// Counts reads and answers at once; the first read can be made to fail.
/// Locked rather than an actor so the tests can read the count directly.
private final class CountingHistory: UsageHistoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let failsFirstRead: Bool

    init(failsFirstRead: Bool = false) {
        self.failsFirstRead = failsFirstRead
    }

    var calls: Int {
        lock.withLock { count }
    }

    func usageHistory(accountID: String, scope: String, since: Date, until: Date) async throws -> [UsageHistoryBucket] {
        let call = lock.withLock { () -> Int in
            count += 1
            return count
        }
        if failsFirstRead, call == 1 { throw URLError(.timedOut) }
        return []
    }
}

/// The open popover reads when it opens and when its week changes, not each
/// time a poll nudges the reset by a fraction of a second: its read task is
/// keyed on the model's drift-tolerant key. Whether a change restarted the
/// task is checked synchronously, straight after the layout pass that would
/// restart it. The only waits are for reads to land, and they have no
/// deadline but the suite's time limit: a loaded run (the window-sizing
/// tests run beside these) can slow them down but not fail them.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct Issue771PopoverReadTests {
    /// The card's weekly window, read now and resetting at `reset`.
    private func weekly(resetsAt reset: Date) -> DeckWindow {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let snapshot = UsageSnapshot(
            accountId: "c1",
            scope: "weekly",
            remainingPercent: 40,
            resetsAt: iso.string(from: reset),
            observedAt: iso.string(from: Date())
        )
        let account = DeckAccount(id: "c1", provider: "claude", label: "Deck c1", identity: "c1@example.com")
        let row = DeckBuilder.rows(state: DeckState(accounts: [account], usage: [snapshot]))[0]
        return row.windows[0]
    }

    private func request(for window: DeckWindow) -> WeeklyUsageGraphModel.Request? {
        WeeklyUsageGraph.request(accountID: "c1", window: window, now: Date())
    }

    private func popover(_ window: DeckWindow, _ model: WeeklyUsageGraphModel) -> WeeklyGraphPopoverView {
        WeeklyGraphPopoverView(accountID: "c1", accountLabel: "Deck c1", window: window, model: model)
    }

    /// Waits for a read to land, however long a loaded run takes.
    private func until(_ condition: () -> Bool) async {
        while !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // The first read fails on purpose: a failure leaves nothing cached, so a
    // restarted task would read again at once and show the spinner in the
    // very layout pass that restarted it.
    @Test func aResetThatOnlyDriftsDoesNotRestartTheRead() async {
        let reset = Date().addingTimeInterval(2 * 86_400)
        let first = weekly(resetsAt: reset)
        let drifted = weekly(resetsAt: reset.addingTimeInterval(0.344))
        let stub = CountingHistory(failsFirstRead: true)
        let model = WeeklyUsageGraphModel(provider: stub)
        let host = NSHostingView(rootView: popover(first, model))
        host.frame = NSRect(x: 0, y: 0, width: 290, height: 200)
        host.layoutSubtreeIfNeeded()
        await until { request(for: first).flatMap { model.load(for: $0) } == .failed }

        host.rootView = popover(drifted, model)
        host.layoutSubtreeIfNeeded()
        #expect(request(for: drifted).flatMap { model.load(for: $0) } == .failed)
        #expect(stub.calls == 1)
    }

    // The control for the check above: a reset that really moves restarts
    // the read inside the same layout pass.
    @Test func aNewWeekReadsAgainWhileOpen() async {
        let reset = Date().addingTimeInterval(2 * 86_400)
        let first = weekly(resetsAt: reset)
        let nextWeek = weekly(resetsAt: reset.addingTimeInterval(6 * 60))
        let stub = CountingHistory()
        let model = WeeklyUsageGraphModel(provider: stub)
        let host = NSHostingView(rootView: popover(first, model))
        host.frame = NSRect(x: 0, y: 0, width: 290, height: 200)
        host.layoutSubtreeIfNeeded()
        await until { request(for: first).flatMap { model.load(for: $0) } == .loaded([]) }

        host.rootView = popover(nextWeek, model)
        host.layoutSubtreeIfNeeded()
        #expect(request(for: nextWeek).flatMap { model.load(for: $0) } == .loading)
        await until { request(for: nextWeek).flatMap { model.load(for: $0) } == .loaded([]) }
        #expect(stub.calls == 2)
        withExtendedLifetime(host) {}
    }
}
