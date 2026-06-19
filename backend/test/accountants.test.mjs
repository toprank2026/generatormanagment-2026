/**
 * Integration tests for ACCOUNTANT sub-accounts (v7).
 *
 * Covers:
 *  - POST /api/account/accountants -> 201 + persisted, owned by the caller
 *  - duplicate username -> 409 USERNAME_TAKEN
 *  - GET /api/account/accountants -> the caller's sub-accounts only
 *  - PUT/DELETE ownership guard (404 across owners)
 *  - non owner/admin caller -> 403 FORBIDDEN
 *  - accountant login: role 'accountant' + ownerId + INHERITED subscription +
 *    no DEVICE_LIMIT (device-exempt)
 *  - effective-owner scoping: an accountant's /api/sync push & pull and
 *    /api/account/stats resolve to the OWNER's mirror
 *
 * Mirrors backend/test/sync.test.mjs: boots a REAL Express server on an
 * ephemeral port against an in-memory MongoDB (USE_MEMORY_DB=true) and an
 * isolated temp BACKUP_DIR, so the suite is hermetic.
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
const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-accountants-test-backups-'));

process.env.USE_MEMORY_DB = 'true';
process.env.NODE_ENV = 'test';
process.env.BACKUP_DIR = TMP_BACKUP_DIR;
process.env.JWT_SECRET = 'test-secret';
process.env.ADMIN_USERNAME = 'admin';
process.env.ADMIN_PASSWORD = 'admin123';

// Now safe to require the app + supporting modules.
const { buildApp } = require('../src/server');
const { connectDb, disconnectDb } = require('../src/config/db');
const { runSeed } = require('../src/bootstrap/seed');

// ---------------------------------------------------------------------------
// Shared state.
// ---------------------------------------------------------------------------
let server; // http.Server
let baseUrl; // e.g. http://127.0.0.1:54321

const NOW = new Date();
const CURRENT_MONTH = `${NOW.getFullYear()}-${String(NOW.getMonth() + 1).padStart(2, '0')}`;

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

// Activate a plan on an owner via admin so the inherited-subscription test has
// a concrete active subscription to inherit.
async function activatePlan(ownerAccountId, planCode) {
  const adminTok = await getAdminToken();
  const r = await api('PUT', `/api/admin/users/${ownerAccountId}/plan`, {
    token: adminTok,
    body: { planCode, status: 'active' },
  });
  assert.equal(r.status, 200, `set plan should 200, got ${r.status} ${JSON.stringify(r.data)}`);
  return r.data.user;
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
// Create / list / duplicate.
// ---------------------------------------------------------------------------
test('owner creates an accountant -> 201 + persisted + listed', async () => {
  const owner = await registerOwner();

  const uname = uniqueUsername('acct');
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: {
      name: 'Acct One',
      username: uname,
      password: 'secret1',
      branchId: 'branch-1',
      permissions: ['receipts', 'expenses'],
      localId: 'acct-local-1',
    },
  });
  assert.equal(created.status, 201, `create should 201, got ${created.status} ${JSON.stringify(created.data)}`);
  const acc = created.data.accountant;
  assert.equal(typeof acc.id, 'string');
  assert.equal(acc.localId, 'acct-local-1');
  assert.equal(acc.name, 'Acct One');
  assert.equal(acc.username, uname.toLowerCase());
  assert.equal(acc.branchId, 'branch-1');
  assert.deepEqual(acc.permissions, ['receipts', 'expenses']);
  assert.equal(acc.active, true);

  // Persisted + listed under this owner.
  const listed = await api('GET', '/api/account/accountants', { token: owner.token });
  assert.equal(listed.status, 200);
  assert.ok(Array.isArray(listed.data.accountants));
  assert.ok(listed.data.accountants.some((a) => a.id === acc.id && a.username === uname.toLowerCase()));
});

test('duplicate accountant username -> 409 USERNAME_TAKEN', async () => {
  const owner = await registerOwner();
  const uname = uniqueUsername('acct');

  const first = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: { name: 'A', username: uname, password: 'secret1' },
  });
  assert.equal(first.status, 201);

  const second = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: { name: 'A2', username: uname, password: 'secret1' },
  });
  assert.equal(second.status, 409);
  assert.equal(second.data.code, 'USERNAME_TAKEN');
});

test('accountants list is per-owner; PUT/DELETE across owners -> 404', async () => {
  const ownerA = await registerOwner();
  const ownerB = await registerOwner();

  const a = await api('POST', '/api/account/accountants', {
    token: ownerA.token,
    body: { name: 'A acct', username: uniqueUsername('acct'), password: 'secret1' },
  });
  assert.equal(a.status, 201);
  const acctId = a.data.accountant.id;

  // Owner B cannot see A's accountant in its own list.
  const bList = await api('GET', '/api/account/accountants', { token: ownerB.token });
  assert.equal(bList.status, 200);
  assert.ok(!bList.data.accountants.some((x) => x.id === acctId), "B must not see A's accountant");

  // Owner B cannot update or delete A's accountant -> 404.
  const bUpdate = await api('PUT', `/api/account/accountants/${acctId}`, {
    token: ownerB.token,
    body: { name: 'hijacked' },
  });
  assert.equal(bUpdate.status, 404);
  assert.equal(bUpdate.data.code, 'ACCOUNTANT_NOT_FOUND');

  const bDelete = await api('DELETE', `/api/account/accountants/${acctId}`, { token: ownerB.token });
  assert.equal(bDelete.status, 404);

  // Owner A can update (active:false) then delete.
  const aUpdate = await api('PUT', `/api/account/accountants/${acctId}`, {
    token: ownerA.token,
    body: { active: false, permissions: ['receipts'] },
  });
  assert.equal(aUpdate.status, 200);
  assert.equal(aUpdate.data.accountant.active, false);
  assert.deepEqual(aUpdate.data.accountant.permissions, ['receipts']);

  const aDelete = await api('DELETE', `/api/account/accountants/${acctId}`, { token: ownerA.token });
  assert.equal(aDelete.status, 200);
  assert.equal(aDelete.data.ok, true);
});

test('an accountant cannot manage accountants -> 403 FORBIDDEN', async () => {
  const owner = await registerOwner();
  const uname = uniqueUsername('acct');
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: { name: 'Acct', username: uname, password: 'secret1' },
  });
  assert.equal(created.status, 201);

  const login = await api('POST', '/api/auth/login', {
    body: { username: uname, password: 'secret1' },
  });
  assert.equal(login.status, 200);
  const acctToken = login.data.token;

  const r = await api('GET', '/api/account/accountants', { token: acctToken });
  assert.equal(r.status, 403);
  assert.equal(r.data.code, 'FORBIDDEN');

  const c = await api('POST', '/api/account/accountants', {
    token: acctToken,
    body: { name: 'nope', username: uniqueUsername('acct'), password: 'secret1' },
  });
  assert.equal(c.status, 403);
});

// ---------------------------------------------------------------------------
// Accountant login: role + ownerId + inherited subscription + device-exempt.
// ---------------------------------------------------------------------------
test('accountant login -> role accountant + ownerId + INHERITED active subscription', async () => {
  const owner = await registerOwner();
  // Give the owner an ACTIVE plan to inherit (yearly: maxDevices=2).
  await activatePlan(owner.account.id, 'yearly');

  const uname = uniqueUsername('acct');
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: {
      name: 'Acct',
      username: uname,
      password: 'secret1',
      branchId: 'branch-9',
      permissions: ['reports'],
      localId: 'acct-local-9',
    },
  });
  assert.equal(created.status, 201);

  // Login WITHOUT a device (accountants are device-exempt) — must still succeed.
  const login = await api('POST', '/api/auth/login', {
    body: { username: uname, password: 'secret1' },
  });
  assert.equal(login.status, 200, `accountant login should 200, got ${login.status} ${JSON.stringify(login.data)}`);
  const acc = login.data.account;
  assert.equal(acc.role, 'accountant');
  assert.equal(acc.ownerId, owner.account.id, 'ownerId must point at the parent owner');
  assert.equal(acc.branchId, 'branch-9');
  assert.deepEqual(acc.permissions, ['reports']);
  assert.equal(acc.localId, 'acct-local-9');
  // Inherited subscription from the owner (active yearly), NOT its own 'none'.
  assert.equal(acc.subscription.status, 'active', 'subscription inherited from owner');
  assert.equal(acc.subscription.planCode, 'yearly');
  assert.ok(acc.subscription.features && typeof acc.subscription.features === 'object');

  // /me applies the same inheritance.
  const me = await api('GET', '/api/auth/me', { token: login.data.token });
  assert.equal(me.status, 200);
  assert.equal(me.data.account.role, 'accountant');
  assert.equal(me.data.account.ownerId, owner.account.id);
  assert.equal(me.data.account.subscription.status, 'active');
});

test('accountant login WITH a new device does NOT trip DEVICE_LIMIT', async () => {
  const owner = await registerOwner();
  // monthly plan: maxDevices=1; the owner already has 1 device from register.
  await activatePlan(owner.account.id, 'monthly');

  const uname = uniqueUsername('acct');
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: { name: 'Acct', username: uname, password: 'secret1' },
  });
  assert.equal(created.status, 201);

  // A brand-new device for the accountant would exceed the owner's limit if it
  // were enforced — but accountants are device-exempt, so this must 200.
  const login = await api('POST', '/api/auth/login', {
    body: { username: uname, password: 'secret1', device: makeDevice() },
  });
  assert.equal(login.status, 200, `accountant login w/ device should 200, got ${login.status} ${JSON.stringify(login.data)}`);
  assert.equal(login.data.account.role, 'accountant');
  // No device was bound onto the accountant account.
  assert.equal(login.data.account.devices.length, 0, 'accountants never bind a device');
});

test('a blocked (active:false) accountant cannot log in -> 403', async () => {
  const owner = await registerOwner();
  const uname = uniqueUsername('acct');
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: { name: 'Acct', username: uname, password: 'secret1' },
  });
  assert.equal(created.status, 201);

  const off = await api('PUT', `/api/account/accountants/${created.data.accountant.id}`, {
    token: owner.token,
    body: { active: false },
  });
  assert.equal(off.status, 200);
  assert.equal(off.data.accountant.active, false);

  const login = await api('POST', '/api/auth/login', {
    body: { username: uname, password: 'secret1' },
  });
  assert.equal(login.status, 403);
  assert.equal(login.data.code, 'BLOCKED');
});

// ---------------------------------------------------------------------------
// Effective-owner scoping: accountant sync push/pull + stats hit owner mirror.
// ---------------------------------------------------------------------------
test('accountant sync push lands in the OWNER mirror; pull + stats resolve to it', async () => {
  const owner = await registerOwner();
  // Owner pushes a baseline subscriber.
  const ownerPush = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [
        {
          entity: 'subscribers',
          localId: 'o-sub-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'o-sub-1', name: 'Owner Sub', phone: '0790', amps: 10, board_id: 'o-b1', circuit_id: 'o-c1', status: 'active' },
        },
      ],
    },
  });
  assert.equal(ownerPush.status, 200);

  const uname = uniqueUsername('acct');
  // Grant the permissions this test's accountant exercises (subscribers + prices;
  // receipts are always allowed). No branchId -> not branch-confined, so branch
  // stamping is a no-op and the pushed rows land verbatim in the owner mirror.
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: { name: 'Acct', username: uname, password: 'secret1', permissions: ['subscribers', 'prices'] },
  });
  assert.equal(created.status, 201);
  const acctLogin = await api('POST', '/api/auth/login', {
    body: { username: uname, password: 'secret1' },
  });
  assert.equal(acctLogin.status, 200);
  const acctToken = acctLogin.data.token;

  // Accountant pushes a NEW subscriber + a current-month price + a receipt.
  const acctPush = await api('POST', '/api/sync/push', {
    token: acctToken,
    body: {
      records: [
        {
          entity: 'monthly_prices',
          localId: CURRENT_MONTH,
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { month: CURRENT_MONTH, price_per_amp: 100 },
        },
        {
          entity: 'subscribers',
          localId: 'acct-sub-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'acct-sub-1', name: 'Acct Sub', phone: '0791', amps: 5, board_id: 'o-b1', circuit_id: 'o-c1', status: 'active' },
        },
        {
          entity: 'receipts',
          localId: 'acct-rec-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: {
            uuid: 'acct-rec-1',
            receipt_no: 1,
            subscriber_id: 'acct-sub-1',
            month: CURRENT_MONTH,
            amps_snapshot: 5,
            price_snapshot: 100,
            paid_amount: 500,
            remaining_after: 0,
            issued_at: `${CURRENT_MONTH}-01T00:00:00.000Z`,
            status: 'valid',
          },
        },
      ],
    },
  });
  assert.equal(acctPush.status, 200, `accountant push should 200, got ${acctPush.status} ${JSON.stringify(acctPush.data)}`);
  assert.equal(acctPush.data.count, 3);

  // The OWNER pull now sees BOTH its own row and the accountant's pushed rows.
  const ownerPull = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z', { token: owner.token });
  assert.equal(ownerPull.status, 200);
  const ownerIds = ownerPull.data.records.map((r) => r.localId);
  assert.ok(ownerIds.includes('o-sub-1'), 'owner sees its own subscriber');
  assert.ok(ownerIds.includes('acct-sub-1'), "owner sees the accountant's pushed subscriber");
  assert.ok(ownerIds.includes('acct-rec-1'), "owner sees the accountant's pushed receipt");

  // The ACCOUNTANT pull resolves to the SAME (owner) mirror.
  const acctPull = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z', { token: acctToken });
  assert.equal(acctPull.status, 200);
  const acctIds = acctPull.data.records.map((r) => r.localId);
  assert.ok(acctIds.includes('o-sub-1'), "accountant pull sees the owner's pre-existing subscriber");
  assert.ok(acctIds.includes('acct-sub-1'));

  // /api/account/stats for the accountant === the owner's mirror stats.
  const acctStats = await api('GET', '/api/account/stats', { token: acctToken });
  assert.equal(acctStats.status, 200, `accountant stats should 200, got ${acctStats.status} ${JSON.stringify(acctStats.data)}`);
  const ownerStats = await api('GET', '/api/account/stats', { token: owner.token });
  assert.equal(ownerStats.status, 200);

  assert.equal(Number(acctStats.data.counts.subscribers), 2, 'owner mirror has 2 subscribers (owner + accountant)');
  assert.equal(
    Number(acctStats.data.counts.subscribers),
    Number(ownerStats.data.counts.subscribers),
    'accountant stats must match the owner stats (effective-owner scoping)'
  );
  assert.equal(Number(acctStats.data.dashboard.collected), 500, 'collected resolves over the owner mirror');
  assert.equal(
    Number(acctStats.data.dashboard.collected),
    Number(ownerStats.data.dashboard.collected)
  );

  // The accountant also reads the owner mirror via /api/account/data.
  const acctData = await api('GET', '/api/account/data?entity=subscribers', { token: acctToken });
  assert.equal(acctData.status, 200);
  const dataIds = acctData.data.records.map((r) => r.localId).sort();
  assert.deepEqual(dataIds, ['acct-sub-1', 'o-sub-1'], 'accountant data view = the owner mirror');
});

// ---------------------------------------------------------------------------
// Review regression: blocked owner, owner-plan feature gating, revoke by localId.
// ---------------------------------------------------------------------------
test('blocking the OWNER cuts off its accountants (login 403 + existing token 403)', async () => {
  const owner = await registerOwner();
  const uname = uniqueUsername('acct');
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: { name: 'A', username: uname, password: 'secret1', localId: 'blk-local-1' },
  });
  assert.equal(created.status, 201);

  // Accountant can log in BEFORE the owner is blocked.
  const pre = await api('POST', '/api/auth/login', { body: { username: uname, password: 'secret1' } });
  assert.equal(pre.status, 200);
  const acctToken = pre.data.token;

  // Admin blocks the OWNER (block is orthogonal to subscription.status).
  const adminTok = await getAdminToken();
  const blk = await api('PUT', `/api/admin/users/${owner.account.id}/blocked`, {
    token: adminTok,
    body: { blocked: true },
  });
  assert.equal(blk.status, 200);

  // Fresh accountant login is now rejected...
  const post = await api('POST', '/api/auth/login', { body: { username: uname, password: 'secret1' } });
  assert.equal(post.status, 403, `blocked owner -> accountant login should 403, got ${post.status}`);
  assert.equal(post.data.code, 'BLOCKED');

  // ...and an ALREADY-issued accountant token is rejected by requireAuth.
  const stats = await api('GET', '/api/account/stats', { token: acctToken });
  assert.equal(stats.status, 403, 'existing accountant token must be rejected once the owner is blocked');
});

test('accountant is feature-gated by the OWNER plan (sync/ownerPanel disabled -> 403)', async () => {
  const Plan = require('../src/models/Plan');
  await Plan.findOneAndUpdate(
    { code: 'lite' },
    { code: 'lite', name: 'Lite', maxDevices: 1, syncEnabled: false, backupEnabled: false, ownerPanelEnabled: false },
    { upsert: true }
  );
  const owner = await registerOwner();
  await activatePlan(owner.account.id, 'lite');

  const uname = uniqueUsername('acct');
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: { name: 'A', username: uname, password: 'secret1' },
  });
  assert.equal(created.status, 201);

  const login = await api('POST', '/api/auth/login', { body: { username: uname, password: 'secret1' } });
  assert.equal(login.status, 200);
  const acctToken = login.data.token;

  // The owner's plan disables sync -> the accountant's sync push is gated too
  // (the gate must resolve features via the effective owner, not the
  // accountant's own empty subscription which would default sync=true).
  const push = await api('POST', '/api/sync/push', { token: acctToken, body: { records: [] } });
  assert.equal(push.status, 403, `owner sync disabled -> accountant push should 403, got ${push.status}`);
  assert.equal(push.data.code, 'FEATURE_DISABLED');

  // ownerPanel disabled on the owner's plan -> accountant account-panel read gated.
  const stats = await api('GET', '/api/account/stats', { token: acctToken });
  assert.equal(stats.status, 403, 'owner ownerPanel disabled -> accountant stats should 403');
});

test('owner revokes an accountant BY localId (update + delete) and login stops', async () => {
  const owner = await registerOwner();
  const uname = uniqueUsername('acct');
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: { name: 'A', username: uname, password: 'secret1', localId: 'rev-local-1' },
  });
  assert.equal(created.status, 201);

  // Disable BY localId (the app addresses accountants by their local UUID).
  const upd = await api('PUT', '/api/account/accountants/rev-local-1', {
    token: owner.token,
    body: { active: false },
  });
  assert.equal(upd.status, 200, `update by localId should 200, got ${upd.status} ${JSON.stringify(upd.data)}`);
  assert.equal(upd.data.accountant.active, false);

  const blocked = await api('POST', '/api/auth/login', { body: { username: uname, password: 'secret1' } });
  assert.equal(blocked.status, 403, 'disabled accountant cannot log in');

  // Delete BY localId -> the backend login account is gone.
  const del = await api('DELETE', '/api/account/accountants/rev-local-1', { token: owner.token });
  assert.equal(del.status, 200, `delete by localId should 200, got ${del.status} ${JSON.stringify(del.data)}`);

  const gone = await api('POST', '/api/auth/login', { body: { username: uname, password: 'secret1' } });
  assert.equal(gone.status, 401, 'deleted accountant no longer exists');
});
