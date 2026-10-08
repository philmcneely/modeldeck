# 0044 — Claude cards lead with a chosen window (deck-wide and per card); the all-models weekly drives proxy routing weights

- Date: 2026-10-08
- Links: issues #746 (lead-window picker), #747 (routing weights), #745 (codename windows); supersedes the 2026-08-02 "lead with the model window" directive and the 2026-08-05 two-tier weight basis in `rebalance-weights.py`; amends decision 0023 (menu-bar health basis), which issue #297 had already moved onto the deck's basis
- Status: recorded by the session from Tim's rulings in chat; Tim may overrule

## The problem, in Tim's words

"Now that Opus 5.5 is out and it's so powerful, I find myself [...] using Opus 5.5 in a lot of cases, even more than Fable. I'm barely even using Fable these days, yet on the deck, I think we made a decision to have it be focused on showing Fable as a top-line item."

"I was just hoping for a setting that would allow me to either display: the weekly reset, the 5-hour window, Fable. Either for all Claude accounts, as well as being able to do it on any individual account."

"I'm barely using Fable, so we shouldn't have Fable leading my rebalancing. We should have the weekly reset be the primary driver of the weightings."

## What the data says

Anthropic's usage endpoint reports, per Claude account: a 5-hour window, the all-models weekly, a Fable-scoped weekly, spend, and a rotating set of undocumented codename buckets. There is **no Opus-specific window**; Opus 5.5 and Sonnet draw from the all-models weekly, and Fable has its own smaller ceiling on top. On 2026-10-08 LoanMeld's card led with "Weekly · Fable · 100% left" while its all-models weekly sat at 21% left, and the routing-weight job read the same account as 100% available.

## Decision

1. **Deck**: Settings → General gets a picker, "Claude cards lead with": Lowest window (default; the original rule) / 5-hour limit / Weekly · all models / Model weekly (e.g. Fable). Any Claude card can override it from its context menu ("Lead With"), offering only the windows that card reports. Precedence: the header calendar button while on → the card's override → the deck setting → lowest. A chosen class the card does not report falls back to the lowest window, so no preference can hide a card's only data. The choice is a window class, never a model name. An install that had the old switch on starts at "Model weekly", so nothing moves until the user picks. App-local, never synced to the daemon.
2. **Health basis**: the Availability Health chip and the menu-bar health dot evaluate the Fable pool only while the deck leads with the model window and the header button is off; otherwise the all-models weekly. This replaces 0023's "always Fable" for the dot (issue #297 had already tied the dot to the chip's basis; this records that the default basis is now the all-models weekly).
3. **Routing weights** (`~/.config/cliproxyapi/rebalance-weights.py`, outside the repo): the general `weekly` scope drives every Claude account's pace and weight, as it already does for Codex. `Fable weekly` keeps one job: the `claude-fable-5` exclusion below the floor, restored above floor + margin. Fallback to the Fable weekly only when the general weekly is unreadable. `--selftest` pins the policy.
4. **Codename windows** (#745): a usage window of a kind the deck has no title for hides until it reports real usage, whatever its reset date says.

## Tripwires named

- Each picker choice binds its window class and falls back to lowest when the class is absent; a per-card override beats the deck setting; the header button beats both; Codex cards ignore all of it.
- The old `preferModelWindow` key migrates to "Model weekly" exactly once; an absent key reads "Lowest".
- `healthUsesGeneralWeekly` is true for every lead window but the model window, and true whenever the header button is on; the mirror hook fires on both inputs.
- `rebalance-weights.py --selftest`: Fable 100 / weekly 21 → driver `weekly`, 21%, no exclusion; Fable drained / weekly 60 → `weekly`, 60%, excluded; weekly unreadable / Fable 80 → `Fable weekly (fallback)`, 80%.
- An unknown-kind window at 100% left with a reset date renders no row; at 99% it does.
