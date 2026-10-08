import Foundation
import Testing
@testable import ModelDeckMacCore

// Issue #297 — the menu bar health dot follows the deck's general-weekly
// focus toggle (#254), the same pool selection the popover chip has used
// since #258. Before this, the dot always evaluated the Fable driver pool
// and could disagree with the chip rendered from the very same state.
// Placeholder labels only — never real account data.

private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

private func iso(hoursFromNow hours: Double) -> String {
    ISO8601DateFormatter().string(from: fixedNow.addingTimeInterval(hours * 3600))
}

/// One Claude account whose two windows tell opposite stories: the Fable
/// weekly is nearly drained with days left (measured pace droughts → RED)
/// while the all-models weekly is untouched (→ GREEN). Whichever pool the
/// dot evaluates is unambiguous from its color.
private var splitVerdictState: DeckState {
    DeckState(
        accounts: [DeckAccount(id: "c1", provider: "claude", label: "Studio", authState: "ok")],
        usage: [
            UsageSnapshot(
                accountId: "c1", scope: "Fable weekly", remainingPercent: 6,
                resetsAt: iso(hoursFromNow: 160), observedAt: iso(hoursFromNow: -0.01)
            ),
            UsageSnapshot(
                accountId: "c1", scope: "weekly", remainingPercent: 100,
                resetsAt: iso(hoursFromNow: 160), observedAt: iso(hoursFromNow: -0.01)
            ),
        ]
    )
}

@Suite("Menu bar health dot honors the general-weekly toggle (issue #297)")
@MainActor
struct MenuBarGeneralWeeklyDotTests {
    private func model() -> MenuBarStatusModel {
        let m = MenuBarStatusModel(
            evaluator: StubEvaluator(results: []),
            clock: { fixedNow }
        )
        m.pinnedAccountId = MenuBarPinResolver.healthSentinel(for: .claude)
        return m
    }

    @Test func defaultStaysTheFableDriverPool() {
        let m = model()
        m.apply(deckState: splitVerdictState)
        #expect(m.iconState == .health(provider: .claude, verdict: .red))
    }

    @Test func toggleFlipsThePoolWithoutWaitingForARefresh() {
        let m = model()
        m.apply(deckState: splitVerdictState)
        #expect(m.iconState == .health(provider: .claude, verdict: .red))
        // The mirror setter alone recomputes — the dot must not show the
        // stale pool until the next state lands.
        m.focusGeneralWeekly = true
        #expect(m.iconState == .health(provider: .claude, verdict: .green))
        m.focusGeneralWeekly = false
        #expect(m.iconState == .health(provider: .claude, verdict: .red))
    }

    @Test func dotAlwaysMatchesTheChipVerdictFromTheSameState() {
        // The invariant the issue is about: for either toggle state, the
        // dot's verdict equals what the popover chip computes (the chip
        // passes the toggle straight into the engine — issue #258).
        for focused in [false, true] {
            let m = model()
            m.focusGeneralWeekly = focused
            m.apply(deckState: splitVerdictState)
            let chipVerdict = AvailabilityHealthEngine.report(
                for: .claude, state: splitVerdictState, now: fixedNow,
                generalWeekly: focused
            ).verdict
            #expect(m.iconState == .health(provider: .claude, verdict: chipVerdict))
        }
    }
}

@Suite("Deck model mirrors the toggle to the app (issue #297)")
@MainActor
struct GeneralWeeklyFocusChangeHookTests {
    private func model() -> DeckPopoverModel {
        let defaults = ScratchDefaults.make("issue297-tests")
        return DeckPopoverModel(defaults: defaults)
    }

    @Test func hookFiresWithEachFlipsNewValue() {
        let m = model()
        // Issue #746: the hook carries the COMBINED basis, and only the
        // model window gives the toggle a Fable basis to flip away from.
        m.leadWindow = .modelWeekly
        var seen: [Bool] = []
        m.onHealthBasisChange = { seen.append($0) }
        m.toggleGeneralWeeklyFocus()
        m.toggleGeneralWeeklyFocus()
        #expect(seen == [true, false])
    }

    @Test func directAssignmentFiresTheHookToo() {
        // The header button goes through toggleGeneralWeeklyFocus(), but
        // any future setter path must keep the mirror honest.
        let m = model()
        m.leadWindow = .modelWeekly
        var seen: [Bool] = []
        m.onHealthBasisChange = { seen.append($0) }
        m.focusGeneralWeeklyHeadline = true
        #expect(seen == [true])
    }

    /// TRIPWIRE #746: the lead-window picker moves the health basis too —
    /// any choice but the model window evaluates the all-models weekly, and
    /// the header toggle still wins over the picker while it's on.
    @Test func leadWindowPickerFiresTheHookWithTheCombinedBasis() {
        let m = model()
        #expect(m.healthUsesGeneralWeekly, "a fresh install leads with the lowest window: weekly basis")
        var seen: [Bool] = []
        m.onHealthBasisChange = { seen.append($0) }
        m.leadWindow = .modelWeekly
        m.leadWindow = .generalWeekly
        m.leadWindow = .modelWeekly
        m.focusGeneralWeeklyHeadline = true
        #expect(seen == [false, true, false, true])
        #expect(m.healthUsesGeneralWeekly)
    }
}
