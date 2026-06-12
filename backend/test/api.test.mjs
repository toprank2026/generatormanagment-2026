/**
 * End-to-end integration tests for the Moldati accounts backend.
 *
 * Runs with the built-in node:test runner against a REAL booted Express
 * server (real HTTP via fetch). Uses an in-memory MongoDB
 * (mongodb-memory-server) and an isolated temp BACKUP_DIR so the suite is
 * hermetic and leaves no artifacts behind.
 *
 *   cd backend && npm test
 *
 * IMPORTANT: process.env MUST be configured before any backend module is
 * required, because src/config/env.js snapshots process.env at require time.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';

// The backend is CommonJS; load it through createRequire from this ESM file.
const require = createRequire(import.meta.url);

// ---------------------------------------------------------------------------
// Environment: configure BEFORE requiring the backend (env.js caches on load).
// ---------------------------------------------------------------------------
const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-test-backups-'));
const MAX_BACKUPS = 2; // small so we can exercise pruning quickly

process.env.USE_MEMORY_DB = 'true';
process.env.NODE_ENV = 'test';
process.env.BACKUP_DIR = TMP_BACKUP_DIR;
process.env.MAX_BACKUPS = String(MAX_BACKUPS);
process.env.JWT_SECRET = 'test-secret';
process.env.ADMIN_USERNAME = 'admin';
process.env.ADMIN_PASSWORD = 'admin123';

// Now safe to require the app + supporting modules.
const { buildApp } = require('../src/server');
const { connectDb, disconnectDb } = require('../src/config/db');
const { runSeed } = require('../src/bootstrap/seed');

// ---------------------------------------------------------------------------
// Shared state across the (ordered) test file.
// ---------------------------------------------------------------------------
let server; // http.Server
let baseUrl; // e.g. http://127.0.0.1:54321

// A fresh device fingerprint helper.
let deviceCounter = 0;
function makeDevice(overrides = {}) {
  deviceCounter += 1;
  return {
    installId: `install-${deviceCounter}`,
    deviceId: `device-${deviceCounter}`,
    platform: 'android',
    model: 'SM-TEST',
    brand: 'samsung',
    osVersion: 'Android 13 (SDK 33)',
    ...overrides,
  };
}

let userCounter = 0;
function uniqueUsername(prefix = 'owner') {
  userCounter += 1;
  return `${prefix}${Date.now()}_${userCounter}`;
}

// Small fetch wrapper that resolves the base URL + parses JSON when present.
async function api(method, urlPath, { token, body, headers } = {}) {
  const h = { ...(headers || {}) };
  if (token) h.Authorization = `Bearer ${token}`;
  let payload = body;
  if (body !== undefined && !(body instanceof FormData)) {
    h['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  const res = await fetch(`${baseUrl}${urlPath}`, { method, headers: h, body: payload });
  const ct = res.headers.get('content-type') || '';
  let data = null;
  if (ct.includes('application/json')) {
    data = await res.json();
  } else {
    data = await res.arrayBuffer();
  }
  return { status: res.status, data, res };
}

// Register a brand-new owner; returns { token, account, username, password, device }.
async function registerOwner(deviceOverrides) {
  const username = uniqueUsername();
  const password = 'secret1';
  const device = makeDevice(deviceOverrides);
  const r = await api('POST', '/api/auth/register', {
    body: { name: 'Owner Name', phone: username, username, password, device },
  });
  assert.equal(r.status, 201, `register should 201, got ${r.status} ${JSON.stringify(r.data)}`);
  return { token: r.data.token, account: r.data.account, username, password, device };
}

// Admin login (seeded admin). Cached after first call.
let adminToken = null;
async function getAdminToken() {
  if (adminToken) return adminToken;
  const r = await api('POST', '/api/auth/login', {
    body: { username: 'admin', password: 'admin123', device: makeDevice() },
  });
  assert.equal(r.status, 200, `admin login should 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.account.role, 'admin');
  adminToken = r.data.token;
  return adminToken;
}

// ---------------------------------------------------------------------------
// Boot / teardown.
// ---------------------------------------------------------------------------
test.before(async () => {
  await connectDb();
  await runSeed();
  const app = buildApp();
  await new Promise((resolve) => {
    server = app.listen(0, '127.0.0.1', resolve);
  });
  const { port } = server.address();
  baseUrl = `http://127.0.0.1:${port}`;
});

test.after(async () => {
  if (server) {
    await new Promise((resolve) => server.close(resolve));
  }
  await disconnectDb();
  try {
    fs.rmSync(TMP_BACKUP_DIR, { recursive: true, force: true });
  } catch {
    /* ignore */
  }
});

// ---------------------------------------------------------------------------
// Health
// ---------------------------------------------------------------------------
test('GET /api/health -> 200 { ok: true }', async () => {
  const r = await api('GET', '/api/health');
  assert.equal(r.status, 200);
  assert.equal(r.data.ok, true);
  assert.equal(typeof r.data.ts, 'string');
});

// ---------------------------------------------------------------------------
// Auth: register / duplicate / login / bad creds
// ---------------------------------------------------------------------------
test('register -> 201 { token, account } with bound device', async () => {
  const username = uniqueUsername();
  const device = makeDevice();
  const r = await api('POST', '/api/auth/register', {
    body: { name: 'Reg User', phone: '0771', username, password: 'secret1', device },
  });
  assert.equal(r.status, 201);
  assert.equal(typeof r.data.token, 'string');
  assert.ok(r.data.token.length > 10);

  const acc = r.data.account;
  assert.equal(acc.username, username.toLowerCase());
  assert.equal(acc.name, 'Reg User');
  assert.equal(acc.role, 'owner');
  assert.equal(acc.blocked, false);
  // fresh subscription is "none" with null dates.
  assert.deepEqual(acc.subscription, {
    planCode: null,
    status: 'none',
    startedAt: null,
    expiresAt: null,
  });
  // calling device is bound + marked current.
  assert.equal(acc.devices.length, 1);
  assert.equal(acc.devices[0].deviceId, device.deviceId);
  assert.equal(acc.devices[0].current, true);
});

test('register duplicate username -> 409 USERNAME_TAKEN', async () => {
  const username = uniqueUsername();
  const first = await api('POST', '/api/auth/register', {
    body: { name: 'Dup', username, password: 'secret1', device: makeDevice() },
  });
  assert.equal(first.status, 201);

  const second = await api('POST', '/api/auth/register', {
    body: { name: 'Dup Again', username, password: 'secret1', device: makeDevice() },
  });
  assert.equal(second.status, 409);
  assert.equal(second.data.code, 'USERNAME_TAKEN');
  assert.equal(typeof second.data.message, 'string');
});

test('login -> 200 with valid creds; 401 with bad creds', async () => {
  const { username, password, device } = await registerOwner();

  const good = await api('POST', '/api/auth/login', {
    body: { username, password, device },
  });
  assert.equal(good.status, 200);
  assert.equal(typeof good.data.token, 'string');
  assert.equal(good.data.account.username, username.toLowerCase());

  const badPw = await api('POST', '/api/auth/login', {
    body: { username, password: 'wrong-password', device },
  });
  assert.equal(badPw.status, 401);

  const badUser = await api('POST', '/api/auth/login', {
    body: { username: `nope_${Date.now()}`, password: 'whatever', device: makeDevice() },
  });
  assert.equal(badUser.status, 401);
});

// ---------------------------------------------------------------------------
// Auth: /me
// ---------------------------------------------------------------------------
test('GET /api/auth/me -> 200 with token, 401 without', async () => {
  const { token, username } = await registerOwner();

  const withToken = await api('GET', '/api/auth/me', { token });
  assert.equal(withToken.status, 200);
  assert.equal(withToken.data.account.username, username.toLowerCase());

  const noToken = await api('GET', '/api/auth/me');
  assert.equal(noToken.status, 401);

  const badToken = await api('GET', '/api/auth/me', { token: 'not-a-real-jwt' });
  assert.equal(badToken.status, 401);
});

// ---------------------------------------------------------------------------
// Subscription
// ---------------------------------------------------------------------------
test('GET /api/subscription/plans -> active plans only', async () => {
  const r = await api('GET', '/api/subscription/plans');
  assert.equal(r.status, 200);
  assert.ok(Array.isArray(r.data.plans));
  const codes = r.data.plans.map((p) => p.code);
  // seeded defaults are all active.
  assert.ok(codes.includes('trial'));
  assert.ok(codes.includes('monthly'));
  assert.ok(codes.includes('yearly'));
  for (const p of r.data.plans) {
    assert.equal(p.active, true);
    assert.equal(typeof p.maxDevices, 'number');
    assert.equal(typeof p.durationDays, 'number');
  }
});

test('POST /api/subscription/request -> pending with null dates', async () => {
  const { token } = await registerOwner();

  const r = await api('POST', '/api/subscription/request', {
    token,
    body: { planCode: 'monthly' },
  });
  assert.equal(r.status, 200);
  assert.deepEqual(r.data.subscription, {
    planCode: 'monthly',
    status: 'pending',
    startedAt: null,
    expiresAt: null,
  });
});

test('admin approve pending plan -> active with start/expiry dates', async () => {
  const owner = await registerOwner();
  const adminTok = await getAdminToken();

  // owner requests a plan
  const req = await api('POST', '/api/subscription/request', {
    token: owner.token,
    body: { planCode: 'yearly' },
  });
  assert.equal(req.status, 200);
  assert.equal(req.data.subscription.status, 'pending');

  // admin approves
  const approve = await api('POST', `/api/admin/users/${owner.account.id}/approve-plan`, {
    token: adminTok,
  });
  assert.equal(approve.status, 200);
  const sub = approve.data.user.subscription;
  assert.equal(sub.planCode, 'yearly');
  assert.equal(sub.status, 'active');
  assert.equal(typeof sub.startedAt, 'string');
  assert.equal(typeof sub.expiresAt, 'string');
  // expiry must be after start.
  assert.ok(new Date(sub.expiresAt).getTime() > new Date(sub.startedAt).getTime());

  // owner sees the active sub via /me
  const me = await api('GET', '/api/auth/me', { token: owner.token });
  assert.equal(me.status, 200);
  assert.equal(me.data.account.subscription.status, 'active');
});

test('admin reject pending plan -> rejected with null dates', async () => {
  const owner = await registerOwner();
  const adminTok = await getAdminToken();

  await api('POST', '/api/subscription/request', {
    token: owner.token,
    body: { planCode: 'monthly' },
  });

  const reject = await api('POST', `/api/admin/users/${owner.account.id}/reject-plan`, {
    token: adminTok,
  });
  assert.equal(reject.status, 200);
  const sub = reject.data.user.subscription;
  assert.equal(sub.status, 'rejected');
  assert.equal(sub.planCode, 'monthly');
  assert.equal(sub.startedAt, null);
  assert.equal(sub.expiresAt, null);
});

test('admin approve when requested plan was deleted -> 404 PLAN_NOT_FOUND', async () => {
  const owner = await registerOwner();
  const adminTok = await getAdminToken();

  // Create a throwaway plan the owner can request.
  const planCode = `temp_${Date.now()}`;
  const upsert = await api('PUT', '/api/admin/plans', {
    token: adminTok,
    body: { code: planCode, name: 'Temp', durationDays: 30, maxDevices: 1, price: 0, active: true },
  });
  assert.equal(upsert.status, 200);

  // Owner requests it.
  const req = await api('POST', '/api/subscription/request', {
    token: owner.token,
    body: { planCode },
  });
  assert.equal(req.status, 200);
  assert.equal(req.data.subscription.status, 'pending');

  // Admin deletes the plan out from under the pending request.
  const del = await api('DELETE', `/api/admin/plans/${planCode}`, { token: adminTok });
  assert.equal(del.status, 200);

  // Approving the now-orphaned request must 404 (validates the recent fix).
  const approve = await api('POST', `/api/admin/users/${owner.account.id}/approve-plan`, {
    token: adminTok,
  });
  assert.equal(approve.status, 404);
  assert.equal(approve.data.code, 'PLAN_NOT_FOUND');
});

// ---------------------------------------------------------------------------
// Device binding + limit
// ---------------------------------------------------------------------------
test('GET /api/device lists the bound device; POST bind adds another within limit', async () => {
  // yearly plan allows maxDevices=2.
  const owner = await registerOwner();
  const adminTok = await getAdminToken();

  // Activate yearly (maxDevices=2) directly.
  const setPlan = await api('PUT', `/api/admin/users/${owner.account.id}/plan`, {
    token: adminTok,
    body: { planCode: 'yearly', status: 'active' },
  });
  assert.equal(setPlan.status, 200);
  assert.equal(setPlan.data.user.subscription.status, 'active');

  const listed = await api('GET', '/api/device', { token: owner.token });
  assert.equal(listed.status, 200);
  assert.equal(listed.data.devices.length, 1);

  // Bind a second NEW device — allowed (limit 2).
  const second = makeDevice();
  const bind = await api('POST', '/api/device/bind', {
    token: owner.token,
    body: { device: second },
  });
  assert.equal(bind.status, 200);
  assert.equal(bind.data.device.deviceId, second.deviceId);

  const after = await api('GET', '/api/device', { token: owner.token });
  assert.equal(after.data.devices.length, 2);
});

test('binding a NEW device beyond the active plan limit -> 403 DEVICE_LIMIT', async () => {
  // monthly plan: maxDevices=1.
  const owner = await registerOwner();
  const adminTok = await getAdminToken();

  const setPlan = await api('PUT', `/api/admin/users/${owner.account.id}/plan`, {
    token: adminTok,
    body: { planCode: 'monthly', status: 'active' },
  });
  assert.equal(setPlan.status, 200);

  // Already 1 device bound from registration; a NEW device must be rejected.
  const newDevice = makeDevice();
  const bind = await api('POST', '/api/device/bind', {
    token: owner.token,
    body: { device: newDevice },
  });
  assert.equal(bind.status, 403);
  assert.equal(bind.data.code, 'DEVICE_LIMIT');

  // The same is enforced at LOGIN with a new device.
  const loginNew = await api('POST', '/api/auth/login', {
    body: { username: owner.username, password: owner.password, device: makeDevice() },
  });
  assert.equal(loginNew.status, 403);
  assert.equal(loginNew.data.code, 'DEVICE_LIMIT');
});

test('re-login with the SAME device does NOT trip the device limit', async () => {
  const owner = await registerOwner();
  const adminTok = await getAdminToken();

  await api('PUT', `/api/admin/users/${owner.account.id}/plan`, {
    token: adminTok,
    body: { planCode: 'monthly', status: 'active' },
  });

  // Re-login repeatedly with the original device — should always succeed and
  // keep exactly one bound device.
  for (let i = 0; i < 3; i += 1) {
    const r = await api('POST', '/api/auth/login', {
      body: { username: owner.username, password: owner.password, device: owner.device },
    });
    assert.equal(r.status, 200, `re-login attempt ${i} should 200`);
    assert.equal(r.data.account.devices.length, 1);
    assert.equal(r.data.account.devices[0].deviceId, owner.device.deviceId);
  }
});

// ---------------------------------------------------------------------------
// Backup: upload / list / download / delete / ownership / prune
// ---------------------------------------------------------------------------

// Build a multipart upload using the global FormData + Blob.
async function uploadBackup(token, bytes, note) {
  const form = new FormData();
  form.append('file', new Blob([bytes], { type: 'application/octet-stream' }), 'moldati.db');
  if (note !== undefined) form.append('note', note);
  return api('POST', '/api/backup', { token, body: form });
}

test('backup upload -> 201 { backup.id }; list; download bytes match; delete', async () => {
  const { token } = await registerOwner();

  const payload = Buffer.from('SQLite format 3 -test-bytes-12345', 'utf8');
  const up = await uploadBackup(token, payload, 'first backup');
  assert.equal(up.status, 201);
  assert.equal(typeof up.data.backup.id, 'string');
  assert.equal(up.data.backup.size, payload.length);
  assert.equal(up.data.backup.note, 'first backup');
  const backupId = up.data.backup.id;

  // List shows it.
  const listed = await api('GET', '/api/backup', { token });
  assert.equal(listed.status, 200);
  assert.ok(listed.data.backups.some((b) => b.id === backupId));

  // Download returns the exact bytes.
  const dl = await fetch(`${baseUrl}/api/backup/${backupId}/download`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(dl.status, 200);
  assert.match(dl.headers.get('content-type') || '', /application\/octet-stream/);
  const got = Buffer.from(await dl.arrayBuffer());
  assert.ok(got.equals(payload), 'downloaded bytes must match uploaded bytes');

  // Delete it.
  const del = await api('DELETE', `/api/backup/${backupId}`, { token });
  assert.equal(del.status, 200);
  assert.equal(del.data.ok, true);

  // Now download 404s.
  const dl2 = await api('GET', `/api/backup/${backupId}/download`, { token });
  assert.equal(dl2.status, 404);
});

test('backups are per-user: a second user cannot download/delete another user backup', async () => {
  const a = await registerOwner();
  const b = await registerOwner();

  const up = await uploadBackup(a.token, Buffer.from('owner-a-secret-db'), 'a');
  assert.equal(up.status, 201);
  const id = up.data.backup.id;

  // User B cannot see it in their list.
  const bList = await api('GET', '/api/backup', { token: b.token });
  assert.equal(bList.status, 200);
  assert.ok(!bList.data.backups.some((x) => x.id === id));

  // User B cannot download it -> 404.
  const bDl = await api('GET', `/api/backup/${id}/download`, { token: b.token });
  assert.equal(bDl.status, 404);

  // User B cannot delete it -> 404.
  const bDel = await api('DELETE', `/api/backup/${id}`, { token: b.token });
  assert.equal(bDel.status, 404);

  // User A still has it.
  const aList = await api('GET', '/api/backup', { token: a.token });
  assert.ok(aList.data.backups.some((x) => x.id === id));
});

test('upload pruning keeps only MAX_BACKUPS most recent', async () => {
  const { token } = await registerOwner();

  // Upload MAX_BACKUPS + 1 backups. Space them out so createdAt + the
  // ISO-timestamp filenames are strictly distinct (ms resolution).
  const total = MAX_BACKUPS + 1;
  const ids = [];
  for (let i = 0; i < total; i += 1) {
    // eslint-disable-next-line no-await-in-loop
    const up = await uploadBackup(token, Buffer.from(`backup-#${i}-payload`), `n${i}`);
    assert.equal(up.status, 201, `upload ${i} should 201`);
    ids.push(up.data.backup.id);
    // small gap to guarantee distinct millisecond timestamps
    // eslint-disable-next-line no-await-in-loop
    await new Promise((r) => setTimeout(r, 8));
  }

  const listed = await api('GET', '/api/backup', { token });
  assert.equal(listed.status, 200);
  assert.equal(
    listed.data.backups.length,
    MAX_BACKUPS,
    `should keep exactly MAX_BACKUPS=${MAX_BACKUPS}`
  );

  // The OLDEST upload must have been pruned; the newest must remain.
  const remaining = new Set(listed.data.backups.map((b) => b.id));
  assert.ok(!remaining.has(ids[0]), 'oldest backup should be pruned');
  assert.ok(remaining.has(ids[total - 1]), 'newest backup should be kept');
});

// ---------------------------------------------------------------------------
// Admin authorization
// ---------------------------------------------------------------------------
test('owner hitting /api/admin/* -> 403 FORBIDDEN', async () => {
  const { token } = await registerOwner();

  const users = await api('GET', '/api/admin/users', { token });
  assert.equal(users.status, 403);
  assert.equal(users.data.code, 'FORBIDDEN');

  const plans = await api('GET', '/api/admin/plans', { token });
  assert.equal(plans.status, 403);
  assert.equal(plans.data.code, 'FORBIDDEN');

  // No token at all -> 401 (auth runs before admin check).
  const noTok = await api('GET', '/api/admin/users');
  assert.equal(noTok.status, 401);
});

test('admin can list users and plans', async () => {
  const adminTok = await getAdminToken();
  // ensure at least one owner exists.
  const owner = await registerOwner();

  const users = await api('GET', '/api/admin/users', { token: adminTok });
  assert.equal(users.status, 200);
  assert.ok(Array.isArray(users.data.users));
  assert.ok(users.data.users.some((u) => u.id === owner.account.id));
  // admin account is present too.
  assert.ok(users.data.users.some((u) => u.role === 'admin'));

  const plans = await api('GET', '/api/admin/plans', { token: adminTok });
  assert.equal(plans.status, 200);
  assert.ok(Array.isArray(plans.data.plans));
  const codes = plans.data.plans.map((p) => p.code);
  assert.ok(codes.includes('trial') && codes.includes('monthly') && codes.includes('yearly'));
});
