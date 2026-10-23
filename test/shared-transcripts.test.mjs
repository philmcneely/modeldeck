import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Store } from '../src/db.mjs';
import { ModelDeckService } from '../src/service.mjs';
import { enumerateTranscriptFiles } from '../src/transcript-ingest.mjs';
import { reconcileSharedTranscripts, sharedTranscriptState } from '../src/shared-transcripts.mjs';

const slug = '-Users-x-proj';
const session = '11111111-1111-4111-8111-111111111111.jsonl';

function fixture(t, options = {}) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'modeldeck-shared-transcripts-')));
  const profilesDir = path.join(root, 'claude-profiles');
  const firstHome = path.join(profilesDir, 'a');
  const secondHome = path.join(profilesDir, 'b');
  for (const directory of [firstHome, secondHome]) fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const activeLink = path.join(root, '.claude');
  fs.symlinkSync(firstHome, activeLink);
  const store = new Store(':memory:');
  // #648: these fixtures exercise managed (switching) behavior for both providers.
  store.saveSettings({ claudeManaged: true, codexManaged: true });
  const service = new ModelDeckService(store, {
    dataDir: root,
    claudeProfilesDir: profilesDir,
    claudeActiveLink: activeLink,
    codexProfilesDir: path.join(root, 'codex-profiles'),
    codexActiveLink: path.join(root, '.codex'),
    platform: 'linux',
    listProviderProcesses: async () => [],
    exec: async () => ({ stdout: '9.9.9' }),
    readClaudeIdentity: async () => null,
    readClaudeTier: async () => null,
    claudeCredentialsPresent: async () => false,
    ...options,
  });
  service.scopeClaudeSecureStorage = async () => {};
  const first = store.saveAccount({ provider: 'claude', label: 'A', profileRef: firstHome, isDefault: true });
  const second = store.saveAccount({ provider: 'claude', label: 'B', profileRef: secondHome });
  t.after(async () => {
    await service.stopAutoRefresh();
    await Promise.all([...service.sharedTranscriptCountTasks.values()]);
    store.close();
    fs.rmSync(root, { recursive: true, force: true });
  });
  return { root, profilesDir, firstHome, secondHome, activeLink, store, service, first, second };
}

function transcript(home, name = session, bytes = 'placeholder conversation\n') {
  const file = path.join(home, 'projects', slug, name);
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, bytes, { mode: 0o600 });
  return file;
}

test('resume-survives-account-switch', async (t) => {
  const data = fixture(t);
  const original = transcript(data.firstHome);
  await data.service.activateAccount(data.second.id);
  const linked = path.join(data.secondHome, 'projects', slug, session);
  assert.equal(fs.lstatSync(linked).isSymbolicLink(), true);
  assert.equal(fs.realpathSync(linked), original);
  assert.equal(path.isAbsolute(fs.readlinkSync(linked)), false);
  assert.equal(fs.readFileSync(path.join(data.activeLink, 'projects', slug, session), 'utf8'), 'placeholder conversation\n');
  assert.equal(fs.statSync(path.dirname(linked)).mode & 0o777, 0o700);
  const enumerated = await enumerateTranscriptFiles(data.profilesDir);
  assert.deepEqual(enumerated.files.filter((file) => path.basename(file.path) === session).map((file) => file.path), [original]);
});

test('own-conversation-never-overwritten', async (t) => {
  const data = fixture(t);
  const first = transcript(data.firstHome, session, 'A bytes');
  const second = transcript(data.secondHome, session, 'B bytes');
  const inode = fs.lstatSync(second).ino;
  await data.service.activateAccount(data.second.id);
  assert.equal(fs.lstatSync(second).isFile(), true);
  assert.equal(fs.lstatSync(second).ino, inode);
  assert.equal(fs.readFileSync(second, 'utf8'), 'B bytes');
  assert.equal(fs.readFileSync(first, 'utf8'), 'A bytes');
});

test('dangling-links-are-pruned-only-when-modeldeck-owned', async (t) => {
  const data = fixture(t);
  const first = transcript(data.firstHome);
  await data.service.activateAccount(data.second.id);
  const linked = path.join(data.secondHome, 'projects', slug, session);
  const outsideLink = path.join(path.dirname(linked), 'outside.jsonl');
  fs.symlinkSync(path.join(data.root, 'missing.jsonl'), outsideLink);
  const foreignInternal = path.join(path.dirname(linked), 'foreign.jsonl');
  const foreignTarget = path.relative(path.dirname(foreignInternal), path.join(data.firstHome, 'projects', slug, 'foreign.jsonl'));
  fs.symlinkSync(foreignTarget, foreignInternal);
  fs.unlinkSync(first);
  await data.service.activateAccount(data.second.id);
  assert.throws(() => fs.lstatSync(linked), { code: 'ENOENT' });
  assert.equal(fs.lstatSync(outsideLink).isSymbolicLink(), true);
  assert.equal(fs.readlinkSync(foreignInternal), foreignTarget, 'matching link syntax alone does not establish ownership');
});

test('usage-ingest-counts-each-transcript-once', async (t) => {
  const data = fixture(t);
  const original = transcript(data.firstHome);
  await data.service.activateAccount(data.second.id);
  const result = await enumerateTranscriptFiles(data.profilesDir);
  assert.deepEqual(result.files.map((file) => file.path), [original]);
  assert.equal(result.skippedSymlinks, 1);
});

test('activation-still-succeeds-when-linking-fails', async (t) => {
  const data = fixture(t);
  transcript(data.firstHome);
  const symlink = fs.symlinkSync;
  const log = t.mock.method(console, 'error', () => {});
  const deny = t.mock.method(fs, 'symlinkSync', (target, file, ...rest) => {
    if (file.endsWith('.jsonl')) throw Object.assign(new Error('private details must not be logged'), { code: 'EACCES' });
    return symlink(target, file, ...rest);
  });
  const result = await data.service.activateAccount(data.second.id);
  assert.equal(fs.realpathSync(data.activeLink), data.secondHome);
  assert.equal(result.account.isDefault, true);
  assert.equal(result.warnings.length, 1);
  assert.match(result.warnings[0], /EACCES/);
  assert.equal(log.mock.callCount(), 1);
  assert.doesNotMatch(log.mock.calls[0].arguments.join(' '), /private details|\.jsonl/);
  const state = await data.service.state();
  const account = state.accounts.find((item) => item.id === data.second.id);
  assert.equal(account.sharedTranscripts, undefined);
  await Promise.all([...data.service.sharedTranscriptCountTasks.values()]);
  assert.equal((await data.service.state()).accounts.find((item) => item.id === data.second.id).sharedTranscripts, 0);
  assert.equal(account.sharedTranscriptsWarning, result.warnings[0]);
  deny.mock.restore();
  await data.service.activateAccount(data.second.id);
  const recovered = (await data.service.state()).accounts.find((item) => item.id === data.second.id);
  assert.equal(recovered.sharedTranscripts, 1);
  assert.equal(recovered.sharedTranscriptsWarning, undefined);
  assert.equal(recovered.metadata.sharedTranscriptLinks, undefined, 'ownership details stay daemon-private');
});

test('new-profile-and-startup-reconcile-transcripts', async (t) => {
  const data = fixture(t);
  const original = transcript(data.firstHome);
  const created = await data.service.createClaudeAccount({ label: 'C' });
  assert.equal(fs.realpathSync(path.join(created.profileRef, 'projects', slug, session)), original);
  const newConversation = transcript(created.profileRef, 'new-placeholder.jsonl', 'new bytes');
  data.store.saveSettings({ autoRefreshEnabled: false, sharedUserScopeEnabled: false });
  data.service.startAutoRefresh();
  await Promise.all([...data.service.autoRefreshStartupTasks]);
  assert.equal(fs.realpathSync(path.join(data.activeLink, 'projects', slug, 'new-placeholder.jsonl')), newConversation);
});

test('codex-resume-files-are-shared-with-relative-links', async (t) => {
  const data = fixture(t);
  const profiles = path.join(data.root, 'codex-profiles');
  const a = path.join(profiles, 'a');
  const b = path.join(profiles, 'b');
  const relative = path.join('sessions', '2026', '09', '11', `rollout-2026-09-11T10-00-00-${session}`);
  fs.mkdirSync(path.join(a, path.dirname(relative)), { recursive: true, mode: 0o700 });
  fs.mkdirSync(b, { mode: 0o700 });
  fs.writeFileSync(path.join(a, relative), 'codex placeholder bytes');
  const account = data.store.saveAccount({ provider: 'codex', label: 'Codex B', profileRef: b });
  await data.service.activateAccount(account.id);
  assert.equal(fs.lstatSync(path.join(b, relative)).isSymbolicLink(), true);
  assert.equal(path.isAbsolute(fs.readlinkSync(path.join(b, relative))), false);
  assert.equal(fs.readFileSync(path.join(data.service.codexActiveLink, relative), 'utf8'), 'codex placeholder bytes');
  assert.equal(fs.realpathSync(path.join(b, relative)), path.join(a, relative));
});

test('reconciliation-is-bounded-and-reports-partial-work', async (t) => {
  const data = fixture(t);
  for (let index = 0; index < 8; index += 1) transcript(data.firstHome, `${index}.jsonl`);
  const result = await reconcileSharedTranscripts({ profilesDir: data.profilesDir, profileRef: data.secondHome, maxEntries: 5 });
  assert.equal(result.examined, 5);
  assert.match(result.warning, /ENTRY_LIMIT/);
  assert.doesNotMatch(result.warning, /retry/i);
  assert.equal(result.sharedTranscripts, undefined, 'a partial count must not be presented as a complete count');
});

test('foreign-links-are-never-claimed', async (t) => {
  const data = fixture(t);
  const original = transcript(data.firstHome);
  const linked = path.join(data.secondHome, 'projects', slug, session);
  fs.mkdirSync(path.dirname(linked), { recursive: true, mode: 0o700 });
  const target = path.relative(path.dirname(linked), original);
  fs.symlinkSync(target, linked);
  const stat = fs.lstatSync(linked);
  await data.service.saveAccount({
    provider: 'claude', label: 'Registered B', profileRef: data.secondHome,
    metadata: { sharedTranscriptLinks: { [`projects/${slug}/${session}`]: {
      target, ino: stat.ino, dev: stat.dev, birthtimeMs: stat.birthtimeMs,
    } } },
  });
  fs.unlinkSync(original);
  await data.service.activateAccount(data.second.id);
  assert.equal(fs.lstatSync(linked).ino, stat.ino);
  assert.deepEqual(await sharedTranscriptState({ profilesDir: data.profilesDir, profileRef: data.secondHome }), { sharedTranscripts: 0 });
});

test('registration-cannot-forge-ownership-of-a-dangling-link', async (t) => {
  const data = fixture(t);
  const home = path.join(data.profilesDir, 'new-placeholder');
  const linked = path.join(home, 'projects', slug, session);
  fs.mkdirSync(path.dirname(linked), { recursive: true, mode: 0o700 });
  const target = path.relative(path.dirname(linked), path.join(data.firstHome, 'projects', slug, session));
  fs.symlinkSync(target, linked);
  const stat = fs.lstatSync(linked);
  const account = await data.service.saveAccount({ provider: 'claude', label: 'New Placeholder', profileRef: home,
    metadata: { sharedTranscriptLinks: { [`projects/${slug}/${session}`]: {
      target, ino: stat.ino, dev: stat.dev, birthtimeMs: stat.birthtimeMs,
    } } },
  });
  assert.equal(fs.lstatSync(linked).ino, stat.ino);
  assert.deepEqual(data.store.getAccount(account.id).metadata.sharedTranscriptLinks, {});
});

test('link-count-is-cached-and-broken-targets-are-not-counted', async (t) => {
  let now = 0;
  const data = fixture(t, { now: () => now });
  const original = transcript(data.firstHome);
  await data.service.activateAccount(data.second.id);
  const lstat = t.mock.method(fs.promises, 'lstat');
  assert.deepEqual(await data.service.accountSharedTranscriptState(data.second), { sharedTranscripts: 1 });
  assert.deepEqual(await data.service.accountSharedTranscriptState(data.second), { sharedTranscripts: 1 });
  assert.equal(lstat.mock.callCount(), 0);
  fs.unlinkSync(original);
  now = 30_001;
  assert.deepEqual(await data.service.accountSharedTranscriptState(data.second), { sharedTranscripts: 1 });
  await data.service.sharedTranscriptCountTasks.get(data.secondHome);
  assert.deepEqual(await data.service.accountSharedTranscriptState(data.second), { sharedTranscripts: 0 });
  fs.mkdirSync(original);
  assert.deepEqual(await sharedTranscriptState({ profilesDir: data.profilesDir, profileRef: data.secondHome }), { sharedTranscripts: 0 });
});

test('linking-runs-after-the-activation-watchdog-has-finished', async (t) => {
  const timers = new Map();
  let timerId = 0;
  const data = fixture(t, {
    claudeActivationSetTimeout: (callback) => { timers.set(++timerId, callback); return timerId; },
    claudeActivationClearTimeout: (id) => timers.delete(id),
  });
  transcript(data.firstHome);
  const open = fs.promises.opendir;
  let enter;
  let release;
  const entered = new Promise((resolve) => { enter = resolve; });
  const gate = new Promise((resolve) => { release = resolve; });
  t.mock.method(fs.promises, 'opendir', async (directory, ...rest) => {
    if (directory === path.join(data.firstHome, 'projects')) {
      enter();
      await gate;
    }
    return open(directory, ...rest);
  });
  const activation = data.service.activateAccount(data.second.id);
  await entered;
  assert.equal(timers.size, 0, 'transcript work must not retain the activation timeout');
  assert.equal(data.store.getAccount(data.second.id).isDefault, true);
  assert.equal(fs.realpathSync(data.activeLink), data.secondHome);
  release();
  assert.deepEqual((await activation).warnings, []);
});

test('source-and-destination-directory-symlinks-fail-closed', async (t) => {
  for (const location of ['source-profile', 'source-projects', 'source-slug', 'destination-projects', 'destination-slug']) {
    await t.test(location, async (t) => {
      const data = fixture(t);
      transcript(data.firstHome);
      const outside = path.join(data.root, 'outside');
      fs.mkdirSync(outside, { mode: 0o700 });
      fs.writeFileSync(path.join(outside, session), 'outside bytes');
      const locations = {
        'source-profile': data.firstHome,
        'source-projects': path.join(data.firstHome, 'projects'),
        'source-slug': path.join(data.firstHome, 'projects', slug),
        'destination-projects': path.join(data.secondHome, 'projects'),
        'destination-slug': path.join(data.secondHome, 'projects', slug),
      };
      const directory = locations[location];
      fs.mkdirSync(path.dirname(directory), { recursive: true, mode: 0o700 });
      if (fs.existsSync(directory)) fs.renameSync(directory, `${directory}.saved`);
      fs.symlinkSync(outside, directory);
      await data.service.activateAccount(data.second.id);
      assert.equal(fs.readFileSync(path.join(outside, session), 'utf8'), 'outside bytes');
      assert.equal(fs.lstatSync(path.join(outside, session)).isFile(), true);
    });
  }
});

test('directory-replacement-during-pruning-cannot-delete-an-outside-file', async (t) => {
  const data = fixture(t);
  const original = transcript(data.firstHome);
  await data.service.activateAccount(data.second.id);
  fs.unlinkSync(original);
  const parent = path.join(data.secondHome, 'projects', slug);
  const linked = path.join(parent, session);
  const outside = path.join(data.root, 'outside');
  fs.mkdirSync(outside, { mode: 0o700 });
  const victim = path.join(outside, session);
  fs.writeFileSync(victim, 'outside bytes');
  const readlink = fs.promises.readlink;
  let reads = 0;
  t.mock.method(fs.promises, 'readlink', async (file, ...rest) => {
    const target = await readlink(file, ...rest);
    // The former asynchronous ownership recheck yielded here, after its
    // final ancestor check. The synchronous critical section never yields.
    if (file === linked && ++reads === 2) {
      fs.renameSync(parent, `${parent}.saved`);
      fs.symlinkSync(outside, parent);
    }
    return target;
  });
  await data.service.activateAccount(data.second.id);
  assert.throws(() => fs.lstatSync(linked), { code: 'ENOENT' });
  assert.equal(fs.readFileSync(victim, 'utf8'), 'outside bytes');
  assert.equal(fs.lstatSync(victim).isFile(), true);
});

test('relative-transcript-links-survive-moving-the-profiles-directory', async (t) => {
  const data = fixture(t);
  transcript(data.firstHome);
  await data.service.activateAccount(data.second.id);
  const moved = path.join(data.root, 'moved-profiles');
  fs.renameSync(data.profilesDir, moved);
  assert.equal(fs.realpathSync(path.join(moved, 'b', 'projects', slug, session)), path.join(moved, 'a', 'projects', slug, session));
});

test('directory-replacement-during-linking-cannot-create-an-outside-link', async (t) => {
  const data = fixture(t);
  transcript(data.firstHome);
  const parent = path.join(data.secondHome, 'projects', slug);
  fs.mkdirSync(parent, { recursive: true, mode: 0o700 });
  const outside = path.join(data.root, 'outside');
  fs.mkdirSync(outside, { mode: 0o700 });
  const linked = path.join(parent, session);
  const symlink = fs.symlinkSync;
  t.mock.method(fs, 'symlinkSync', (target, file, ...rest) => {
    // Reproduce the former yield at the transcript write, after all checks.
    // Activation's own directory symlink is intentionally unaffected.
    if (file === linked) {
      fs.renameSync(parent, `${parent}.saved`);
      fs.symlinkSync(outside, parent);
    }
    return symlink(target, file, ...rest);
  });
  const result = await data.service.activateAccount(data.second.id);
  // The swap is caught after the write: the stray link is removed, nothing
  // lands outside the managed root, the switch itself still succeeded, and
  // the failure surfaces as a warning rather than a silent skip.
  assert.equal(result.warnings.length, 1);
  assert.deepEqual(fs.readdirSync(outside), []);
  assert.throws(() => fs.lstatSync(path.join(outside, session)), { code: 'ENOENT' });
  assert.equal(fs.realpathSync(data.activeLink), fs.realpathSync(data.secondHome));
});

test('legacy-adopt-and-fresh-reconcile-after-success-without-populating-the-staging-home', async (t) => {
  for (const mode of ['adopt', 'fresh']) {
    await t.test(mode, async (t) => {
      const data = fixture(t);
      const original = transcript(data.firstHome);
      fs.unlinkSync(data.activeLink);
      fs.mkdirSync(data.activeLink, { mode: 0o700 });
      fs.writeFileSync(path.join(data.activeLink, 'settings.json'), '{}', { mode: 0o600 });
      const created = await data.service.createClaudeAccount({ label: 'New Placeholder' });
      assert.equal(fs.existsSync(path.join(created.profileRef, 'projects')), false);
      const result = await data.service.adoptClaudeLegacyHome(created.id, { mode });
      assert.equal(result.account.isDefault, true);
      assert.equal(fs.realpathSync(data.activeLink), created.profileRef);
      assert.equal(fs.realpathSync(path.join(data.activeLink, 'projects', slug, session)), original);
      assert.equal(fs.readFileSync(path.join(result.backupPath, 'settings.json'), 'utf8'), '{}');
    });
  }
});

test('owned-link-pruning-survives-a-daemon-restart-and-preserves-replacements', async (t) => {
  const data = fixture(t);
  const original = transcript(data.firstHome);
  await data.service.activateAccount(data.second.id);
  const linked = path.join(data.secondHome, 'projects', slug, session);
  const oldLink = `${linked}.saved`;
  const target = fs.readlinkSync(linked);
  fs.renameSync(linked, oldLink);
  fs.symlinkSync(target, linked);
  fs.unlinkSync(original);
  const restarted = new ModelDeckService(data.store, {
    dataDir: data.root, claudeProfilesDir: data.profilesDir, claudeActiveLink: data.activeLink,
    codexProfilesDir: path.join(data.root, 'codex-profiles'), codexActiveLink: path.join(data.root, '.codex'),
    platform: 'linux',
  });
  await restarted.reconcileActiveTranscripts();
  assert.equal(fs.lstatSync(linked).isSymbolicLink(), true, 'a user replacement is not owned');
  fs.unlinkSync(linked);
  fs.renameSync(oldLink, linked);
  transcript(data.firstHome);
  fs.unlinkSync(linked);
  await restarted.reconcileAccountTranscripts(data.second);
  fs.unlinkSync(original);
  const restartedAgain = new ModelDeckService(data.store, {
    dataDir: data.root, claudeProfilesDir: data.profilesDir, claudeActiveLink: data.activeLink,
    codexProfilesDir: path.join(data.root, 'codex-profiles'), codexActiveLink: path.join(data.root, '.codex'),
    platform: 'linux',
  });
  await restartedAgain.reconcileActiveTranscripts();
  assert.throws(() => fs.lstatSync(linked), { code: 'ENOENT' });
});


test('account-state-answers-while-shared-transcript-count-is-stalled', async (t) => {
  let now = 0;
  const data = fixture(t, { now: () => now });
  transcript(data.firstHome);
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  let entered;
  const scanning = new Promise((resolve) => { entered = resolve; });
  const open = fs.promises.opendir;
  let scans = 0;
  t.mock.method(fs.promises, 'opendir', async (...args) => {
    scans += 1;
    entered();
    await gate;
    return open(...args);
  });
  const first = data.service.state();
  try {
    const result = await Promise.race([
      first,
      new Promise((resolve) => setTimeout(() => resolve(null), 100)),
    ]);
    assert.ok(result, 'account status must not wait for optional conversation counts');
    assert.equal(result.accounts.length, 2);
    await scanning;
    const started = scans;
    now = 60_000;
    await data.service.state();
    assert.equal(scans, started, 'a slow count must not start another scan when its TTL passes');
  } finally {
    release();
    await first;
    await Promise.all([...data.service.sharedTranscriptCountTasks.values()]);
  }
});


test('reconciliation-does-not-start-a-second-pending-conversation-count', async (t) => {
  let now = 0;
  const data = fixture(t, { now: () => now });
  transcript(data.firstHome);
  transcript(data.secondHome, '22222222-2222-4222-8222-222222222222.jsonl');
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  let entered;
  const scanning = new Promise((resolve) => { entered = resolve; });
  const open = fs.promises.opendir;
  let scans = 0;
  t.mock.method(fs.promises, 'opendir', async (directory, ...args) => {
    if (directory === path.join(data.secondHome, 'projects')) {
      scans += 1;
      if (scans === 1) { entered(); await gate; }
    }
    return open(directory, ...args);
  });
  await data.service.accountSharedTranscriptState(data.second);
  const pending = data.service.sharedTranscriptCountTasks.get(data.secondHome);
  try {
    await scanning;
    await data.service.reconcileAccountTranscripts(data.second);
    const before = scans;
    now = 30_001;
    assert.deepEqual(await data.service.accountSharedTranscriptState(data.second), { sharedTranscripts: 1 });
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.equal(scans, before, 'reconciliation must retain ownership of the unfinished recount');
  } finally {
    release();
    await pending;
    await Promise.all([...data.service.sharedTranscriptCountTasks.values()]);
  }
});
