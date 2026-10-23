import test, { mock, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import childProcess from 'node:child_process';
import fs from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import { realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Fail closed: importing or building a deck must never do live I/O.
const forbidden = () => { throw new Error('Live I/O is forbidden in phone deck tests'); };
mock.method(http, 'createServer', forbidden);
mock.method(childProcess, 'execFile', forbidden);
mock.method(fs, 'readdir', forbidden);
mock.method(fs, 'readFile', forbidden);
mock.method(globalThis, 'fetch', forbidden);
syncBuiltinESMExports();
const {
  buildDeck, mergeAccounts, headlineOf, weightOf, windowTitle, windowRank,
  severity, hidden, planLabel, signInOf, SAFE_PATH, DOWN_AFTER, handle, isMain,
} = await import('./server.mjs');
after(() => {
  try {
    for (const fn of [http.createServer, childProcess.execFile, fs.readdir, fs.readFile, globalThis.fetch]) {
      assert.equal(fn.mock.callCount(), 0, 'No live I/O may even be attempted');
    }
  } finally {
    mock.restoreAll();
    syncBuiltinESMExports();
  }
});

const NOW = Date.parse('2026-10-22T12:00:00Z');
const machine = (name, accounts = [], usage = []) => ({
  name, remote: name === 'M5', ok: true, stateAt: NOW,
  state: { accounts, usage }, forecast: null,
});
const account = (id, extra = {}) => ({ id, provider: 'claude', label: 'Probe', enabled: true, ...extra });
const usage = (accountId, scope, remainingPercent, age = 0) => ({
  accountId, scope, remainingPercent,
  observedAt: new Date(NOW - age).toISOString(),
  resetsAt: '2026-10-24T12:00:00Z',
});

test('merge: same account on both Macs becomes one card with freshest reading per window', () => {
  const states = {
    M5: machine('M5', [account('remote')], [usage('remote', 'week', 70), usage('remote', '5h', 40, 60_000)]),
    M1: machine('M1', [account('local')], [usage('local', 'week', 90, 60_000), usage('local', '5h', 20)]),
  };
  const deck = buildDeck(states, NOW);
  assert.equal(deck.accounts.length, 1);
  assert.deepEqual(deck.accounts[0].windows.map((w) => [w.title, w.remaining, w.source]), [
    ['5-hour limit', 20, 'M1'], ['Weekly · all models', 70, 'M5'],
  ]);
});

test('import and pure deck building perform no network, process, or filesystem reads', () => {
  assert.deepEqual(buildDeck({ M5: machine('M5'), M1: machine('M1') }, NOW).accounts, []);
});

test('merge: accounts present on only one Mac survive; disabled accounts do not', () => {
  const states = {
    M5: machine('M5', [account('remote', { label: 'Remote' })]),
    M1: machine('M1', [account('local', { label: 'Local' }), account('disabled', { enabled: false })]),
  };
  assert.deepEqual(buildDeck(states, NOW).accounts.map((a) => a.label), ['Remote', 'Local']);
});

test('merge: UUID match wins over renamed labels, distinct UUIDs stay separate', () => {
  const metadata = { claudeAccountUuid: '11111111-2222-4333-8444-555555555555' };
  const states = {
    M5: machine('M5', [account('remote', { metadata })]),
    M1: machine('M1', [account('local', { label: 'Renamed', metadata })]),
  };
  assert.equal(mergeAccounts(states).length, 1);
  assert.equal(buildDeck(states, NOW).accounts[0].label, 'Probe');
  states.M1.state.accounts[0] = account('other', { metadata: { claudeAccountUuid: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' } });
  assert.equal(mergeAccounts(states).length, 2);
});

const window = (scope, remaining, resetsAt = null) => ({
  title: windowTitle(scope), rank: windowRank(scope), remaining, resetsAt, spend: scope === 'spend',
});
test('headline: on a Claude card the weekly all-models leads even when another window is lower', () => {
  assert.equal(headlineOf([window('5h', 5), window('week', 80), window('week:model', 10)], 'claude'), 1);
});
test('headline: a Codex card leads with its lowest window, as on the Mac deck', () => {
  assert.equal(headlineOf([window('5h', 3), window('week', 80)], 'codex'), 0);
  assert.equal(headlineOf([window('5h', 90), window('week', 80)], 'codex'), 1);
});
test('headline: monthly and usage-period windows do not masquerade as the weekly lead', () => {
  assert.equal(headlineOf([window('month', 90), window('week', 80), window('5h', 5)], 'claude'), 1);
  assert.equal(headlineOf([window('month', 90), window('usage period', 80), window('5h', 5)], 'claude'), 2);
});
test('headline: lowest non-spend window leads without a weekly; earlier reset breaks ties', () => {
  assert.equal(headlineOf([window('5h', 40), window('week:model', 10), window('spend', 1)], 'claude'), 1);
  assert.equal(headlineOf([window('5h', 10, NOW + 2000), window('week:model', 10, NOW + 1000)], 'claude'), 1);
  assert.equal(headlineOf([], 'claude'), -1);
});

test('weight: member preserves number including zero, absent is null, missing M5 account is undefined', () => {
  assert.equal(weightOf(account('a', { proxyPool: 'member', proxyWeight: 7 })), 7);
  assert.equal(weightOf(account('a', { proxyPool: 'member', proxyWeight: 0 })), 0);
  assert.equal(weightOf(account('a', { proxyPool: 'absent', proxyWeight: 7 })), null);
  assert.equal(weightOf(account('a')), null);
  assert.equal(weightOf(undefined), undefined);
  const states = { M5: machine('M5'), M1: machine('M1', [account('local', { proxyPool: 'member', proxyWeight: 9 })]) };
  assert.equal(buildDeck(states, NOW).accounts[0].weight, undefined);
  assert.equal(Object.hasOwn(JSON.parse(JSON.stringify(buildDeck(states, NOW))).accounts[0], 'weight'), false);
});

test('privacy: serialized deck excludes emails, UUIDs, credentials, and identity fields', () => {
  const uuid = '11111111-2222-4333-8444-555555555555';
  const a = account(uuid, {
    email: 'probe@example.invalid', token: 'placeholder-token', key: 'placeholder-key',
    credential: 'placeholder-credential', profileRef: '/placeholder/profile', identity: 'probe@example.invalid',
    metadata: { claudeAccountUuid: uuid, email: 'probe@example.invalid', plan: 'pro' },
  });
  const states = { M5: machine('M5', [a], [usage(uuid, 'week', 70)]), M1: machine('M1') };
  const histories = new Map([[`M5:${uuid}:2026-10-24T12:00:00.000Z`, { rows: [
    { bucketStart: '2026-10-21T12:00:00Z', lastUsedPercent: 10, token: 'placeholder-token' },
    { bucketStart: '2026-10-22T11:00:00Z', lastUsedPercent: 20 },
  ] }]]);
  states.M5.forecast = { accounts: [{ accountId: uuid, scope: 'week', status: 'forecast', dryAt: '2026-10-23T12:00:00Z' }] };
  const deck = buildDeck(states, NOW, { histories, pool: { grok: 1, antigravity: 2 } });
  assert.ok(deck.accounts[0].history);
  assert.ok(deck.accounts[0].forecast);
  const json = JSON.stringify(deck);
  assert.doesNotMatch(json, /@|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/i);
  assert.doesNotMatch(json, /"[^"\\]*(?:token|key|credential|profileRef|identity)[^"\\]*"\s*:/i);
  assert.doesNotMatch(json, /placeholder/);
});

test('reachability: a failed read stays reachable inside DOWN_AFTER, then expires', () => {
  const states = { M5: { ...machine('M5'), ok: false }, M1: machine('M1') };
  assert.equal(buildDeck(states, NOW + DOWN_AFTER - 1).sources[0].reachable, true);
  assert.equal(buildDeck(states, NOW + DOWN_AFTER).sources[0].reachable, false);
  assert.equal(buildDeck(states, NOW + DOWN_AFTER + 1).sources[0].reachable, false);
  states.M5.stateAt = 0;
  assert.equal(buildDeck(states, NOW).sources[0].reachable, false);
});

test('SAFE_PATH accepts daemon paths and rejects quotes, semicolons, spaces, backticks, and command substitution', () => {
  assert.equal(SAFE_PATH.test('/api/usage/history?accountId=probe&since=2026-10-22T12%3A00%3A00Z'), true);
  for (const suffix of ["'", '"', ';id', ' space', '`id`', '$(id)', '\n', '\r']) {
    assert.equal(SAFE_PATH.test(`/api/state${suffix}`), false, JSON.stringify(suffix));
  }
  assert.equal(SAFE_PATH.test('https://example.invalid/api/state'), false);
});
test('SAFE_PATH accepts the + that URLSearchParams writes for a space in a window scope', () => {
  const q = new URLSearchParams({ accountId: 'probe', scope: 'usage period', bucket: 'hour' });
  assert.equal(SAFE_PATH.test(`/api/usage/history?${q}`), true);
  assert.equal(SAFE_PATH.test('/api/usage/history?scope=usage+period'), true);
});

const request = async (url, headers = { host: '127.0.0.1:3871' }) => {
  const res = { status: 0, writeHead(status) { this.status = status; }, end() {} };
  await handle({ method: 'GET', url, headers }, res);
  return res.status;
};
test('http: a malformed request path answers 400 instead of crashing the server', async () => {
  for (const url of ['//', '//x%20y', '//[', '//?x', '//a:99999']) assert.equal(await request(url), 400, url);
});
test('http: answers only to an IP address, localhost or a tailnet name', async () => {
  for (const host of ['100.97.205.116:3871', '127.0.0.1:3871', 'localhost:3871', '[fd7a::1]:3871',
    'probe-mac', 'probe-mac.tail0000.ts.net:3871']) {
    assert.equal(await request('/missing', { host }), 404, host);
  }
  for (const host of ['attacker.example', 'attacker.example:3871', '100.97.205.116.attacker.example', '']) {
    assert.equal(await request('/missing', { host }), 403, host);
  }
  assert.equal(await request('/missing', {}), 403, 'no Host header');
});

test('the server starts when node is given a symlinked path to it', async () => {
  const real = fileURLToPath(new URL('./server.mjs', import.meta.url));
  const dir = await fs.mkdtemp(join(tmpdir(), 'phone-deck-'));
  try {
    const link = join(dir, 'server.mjs');
    await fs.symlink(real, link);
    const url = pathToFileURL(realpathSync(real)).href;
    assert.equal(isMain(link, url), true);
    assert.equal(isMain(real, url), true);
    assert.equal(isMain(fileURLToPath(import.meta.url), url), false);
    assert.equal(isMain(undefined, url), false);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('window titles and ranks preserve session, weekly, model, and spend ordering', () => {
  assert.deepEqual(['session', 'weekly', 'week:model', 'spend'].map(windowTitle),
    ['5-hour limit', 'Weekly · all models', 'Weekly · Model', 'Spend']);
  assert.deepEqual(['5h', '7d', 'model weekly', 'spend'].map(windowRank), [0, 1, 2, 3]);
  assert.equal(windowTitle('unknown-scope'), 'unknown-scope');
});
test('severity uses the 10 and 25 percent boundaries', () => {
  assert.deepEqual([null, 0, 10, 10.1, 25, 25.1].map(severity),
    ['unknown', 'critical', 'critical', 'warning', 'warning', 'healthy']);
});
test('hidden windows suppress unused Codex models and meaningless unknown windows', () => {
  const w = { scope: 'week:model', rank: 2, remaining: 100 };
  assert.equal(hidden(w, 'codex'), true);
  assert.equal(hidden({ ...w, remaining: null }, 'codex'), true);
  assert.equal(hidden({ ...w, remaining: 99 }, 'codex'), false);
  assert.equal(hidden(w, 'claude'), false);
  assert.equal(hidden({ scope: 'unknown', remaining: 100 }, 'claude'), true);
  assert.equal(hidden({ scope: 'spend', spend: true, spendText: '$1 of $5' }, 'claude'), false);
});
test('plan labels format subscription tiers without exposing metadata', () => {
  assert.equal(planLabel({ claudePlan: { subscriptionType: 'max', rateLimitTier: 'default_claude_max_20x' } }), 'Max (20x)');
  assert.equal(planLabel({ codexPlan: 'pro' }), 'Pro');
  assert.equal(planLabel({}), null);
});
test('sign-in state distinguishes idle expiry, repeated renewal failure, and duplicates', () => {
  assert.deepEqual(signInOf(account('a')), { state: 'ok', text: null });
  const expired = account('a', { authState: 'signin-required', signinReason: 'expired' });
  assert.equal(signInOf(expired).state, 'idle');
  assert.equal(signInOf({ ...expired, renew: { consecutiveFailures: 2 } }).state, 'needed');
  assert.equal(signInOf(account('a', { authState: 'duplicate-token' })).state, 'needed');
});
