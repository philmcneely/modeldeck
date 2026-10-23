# Phone Deck

A read-only ModelDeck usage page for Tim's iPhone and iPad, available only on
his tailnet. It combines the M1 and M5 readings into one card per account and
uses the freshest reading for each usage window. As on the Mac deck, a Claude
card leads with its all-models weekly window; Codex cards, and Claude cards
without a weekly, lead with the lowest remaining window.

## Run on the M1

Requires Node (the repo's supported version), the local ModelDeck daemon,
Tailscale, and an existing SSH host named `m5` with noninteractive access.
No package installation is needed.

From the repo root, for a foreground run:

```sh
node tools/phone-deck/server.mjs
```

It listens on `127.0.0.1:3871` by default. Stop a foreground run with Ctrl-C.
`PORT` and `HOSTS` override the listener; keep the loopback default for tailnet
use. `M5_HOST` overrides the SSH host for a manual run.

To keep it running after login, use a stable checkout on the M1:

```sh
tools/phone-deck/launch-agent.sh install
tools/phone-deck/launch-agent.sh status
```

The installer uses `/opt/homebrew/bin/node` and writes
`~/Library/LaunchAgents/ai.modeldeck.phone-deck.plist`, with this folder as its
working directory, `PORT=3871`, `HOSTS=127.0.0.1`, RunAtLoad, and KeepAlive.
Both output streams go to `~/Library/Logs/modeldeck-phone-deck.log`.
Do not move or delete the checkout while it is installed. Re-run install after
updating the server. It refuses to replace another process on port 3871 and
prints instructions to stop the old `ai.modeldeck.phone-deck-proto` agent.

The installer checks Tailscale's serve status and, if it cannot confirm a
matching entry, prints this command. It does not change Tailscale configuration:

```sh
tailscale serve --bg --tcp=3871 tcp://127.0.0.1:3871
```

Use Tailscale Serve, which is tailnet-only. Do not enable Funnel or bind the
server publicly. The page has no separate sign-in; tailnet access controls
determine who can open it. It answers only when the address in the browser is an
IP address, `localhost` or a tailnet name, so another website can't read it
through a look-alike domain.

## Open on iPhone or iPad

1. Connect Tailscale on the phone or tablet to the same tailnet.
2. Open Safari at **http://100.97.205.116:3871/** (the M1's tailnet address).
3. Tap **Share → Add to Home Screen → Add**. If Share is in Safari's menu,
   open that menu first. Launch Phone Deck from the new home-screen icon.

## What it reads

- The local M1 daemon at `127.0.0.1:3867`, using GET requests only.
- The M5 daemon through `ssh m5 curl …`, also GET requests only. The endpoints
  are `/api/state`, `/api/usage/exhaustion-forecast`, and `/api/usage/history`.
- File **names only** in the M1's `~/.config/cliproxyapi/auth` directory to
  count Grok and Antigravity sign-ins. It never opens those files.
- This folder's page, manifest and icons, and the repo's provider images.

The browser receives display labels, plans, usage percentages, reset times,
reading ages, sign-in status, forecasts/history, and the M5 pool's routing
weights. It never receives account email fields, account UUIDs, tokens, profile
paths, or credentials. Use non-identifying display labels: labels and other
display text are shown as supplied by ModelDeck. No provider calls, refreshes,
sign-ins, routing changes, or credential writes are made by this tool.

State reads are cached for 60 seconds, forecasts for five minutes, and history
for ten minutes. Local reads have a 25-second timeout; remote curl reads use
`-m 15`. A failed read retains the previous data. A Mac stays reachable for five
minutes after its last successful read, then shows as unavailable; an unavailable
M5 is retried no more often than every two minutes.

## Stop

```sh
tools/phone-deck/launch-agent.sh uninstall
```

This stops and removes only the maintained phone-deck agent. Logs and Tailscale's
serve entry remain; with the server stopped the entry cannot serve the page.
To remove that forwarding entry as well:

```sh
tailscale serve --tcp=3871 off
```

## Offline checks

```sh
node --test tools/phone-deck/phone-deck.test.mjs
node --check tools/phone-deck/server.mjs
bash -n tools/phone-deck/launch-agent.sh
```

The tests import the pure deck builder with placeholder machine states. Live
HTTP calls, SSH, file reads, and starting an HTTP server are blocked by test
stubs. The repo's ordinary `node --test` discovery also finds the test file. Do not start the
server or run the installer to verify changes in a sandbox.
