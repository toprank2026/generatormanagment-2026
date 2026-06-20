/**
 * Integration tests for BRANCH sub-accounts ("branch = owner-created sub-account").
 *
 * A BRANCH is a backend User that is a CHILD of the creating top-level owner
 * (role:'owner', parentOwner set). It logs in through the normal /api/auth/login
 * with its phone as username + its own password, behaves owner-like for its OWN
 * data mirror, inherits the parent's subscription/features, and is cascade-blocked
 * by the parent.
 *
 * Covers:
 *  - POST /api/account/branches -> 201 + persisted + listed under the parent
 *  - branch logs in via /api/auth/login -> token + inherited subscription
 *  - branch data is ISOLATED from the parent's mirror (parent /stats excludes it;
 *    parent /branches/:id/stats includes it)
 *  - a branch cannot create a sub-branch -> 403 SUB_BRANCH_FORBIDDEN
 *  - a non-owner (accountant) cannot create a branch -> 403 FORBIDDEN
 *  - parent lists + reads a branch's stats/data
 *  - another owner cannot read this owner's branch -> 404 BRANCH_NOT_FOUND
 *  - a blocked parent blocks the branch (login 403 + existing token 403)
 *
 * Mirrors backend/test/accountants.test.mjs: boots a REAL Express server on an
 * ephemeral port against an in-memory MongoDB (USE_MEMORY_DB=true) + isolated
 * temp BACKUP_DIR, so the suite is hermetic.
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

const require = createRequire(import.meta.url);

// ---------------------------------------------------------------------------
// Environment: configure BEFORE requiring the backend (env.js caches on load).
// ---------------------------------------------------------------------------
const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-branches-test-backups-'));

process.env.USE_MEMORY_DB = 'true';
process.env.NODE_ENV = 'test';
process.env.BACKUP_DIR = TMP_BACKUP_DIR;
process.env.JWT_SECRET = 'test-secret';
process.env.ADMIN_USERNAME = 'admin';
process.env.ADMIN_PASSWORD = 'admin123';

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
function uniquePhone(prefix = '0790') {
  userCounter += 1;
  // Digits-only phone so username == phone reads naturally; unique per call.
  return `${prefix}${Date.now()}${userCounter}`;
}

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
  if (ct.includes('application/json')) data = await res.json();
  else data = await res.arrayBuffer();
  return { status: res.status, data, res };
}

// Register a brand-new top-level owner.
async function registerOwner(deviceOverrides) {
  const phone = uniquePhone();
  const password = 'secret1';
  const device = makeDevice(deviceOverrides);
  const r = await api('POST', '/api/auth/register', {
    body: { name: 'Owner Name', phone, username: phone, password, device },
  });
  assert.equal(r.status, 201, `register should 201, got ${r.status} ${JSON.stringify(r.data)}`);
  return { token: r.data.token, account: r.data.account, phone, password, device };
}

let adminToken = null;
async function getAdminToken() {
  if (adminToken) return adminToken;
  const r = await api('POST', '/api/auth/login', {
    body: { username: 'admin', password: 'admin123', device: makeDevice() },
  });
  assert.equal(r.status, 200, `admin login should 200, got ${r.status} ${JSON.stringify(r.data)}`);
  adminToken = r.data.token;
  return adminToken;
}

async function activatePlan(ownerAccountId, planCode) {
  const adminTok = await getAdminToken();
  const r = await api('PUT', `/api/admin/users/${ownerAccountId}/plan`, {
    token: adminTok,
    body: { planCode, status: 'active' },
  });
  assert.equal(r.status, 200, `set plan should 200, got ${r.status} ${JSON.stringify(r.data)}`);
  return r.data.user;
}

// Create a branch under `owner`; returns { id, phone, password, branch }.
async function createBranch(owner, overrides = {}) {
  const phone = overrides.phone || uniquePhone('0791');
  const password = overrides.password || 'secret1';
  const r = await api('POST', '/api/account/branches', {
    token: owner.token,
    body: { generatorName: overrides.generatorName || 'Branch Gen', phone, password },
  });
  assert.equal(r.status, 201, `create branch should 201, got ${r.status} ${JSON.stringify(r.data)}`);
  return { id: r.data.branch.id, phone, password, branch: r.data.branch };
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
  if (server) await new Promise((resolve) => server.close(resolve));
  await disconnectDb();
  try {
    fs.rmSync(TMP_BACKUP_DIR, { recursive: true, force: true });
  } catch {
    /* ignore */
  }
});

// ---------------------------------------------------------------------------
// Create / list.
// ---------------------------------------------------------------------------
test('owner creates a branch -> 201 + persisted + listed under the parent', async () => {
  const owner = await registerOwner();
  const b = await createBranch(owner, { generatorName: 'North Gen' });

  assert.equal(typeof b.branch.id, 'string');
  assert.equal(b.branch.generatorName, 'North Gen');
  assert.equal(b.branch.phone, b.phone);
  assert.equal(b.branch.username, b.phone.toLowerCase());
  assert.equal(b.branch.parentOwnerId, owner.account.id, 'parentOwnerId points at the creator');
  assert.equal(b.branch.blocked, false);

  const listed = await api('GET', '/api/account/branches', { token: owner.token });
  assert.equal(listed.status, 200);
  assert.ok(Array.isArray(listed.data.branches));
  assert.ok(listed.data.branches.some((x) => x.id === b.id && x.phone === b.phone));
});

test('duplicate branch phone -> 409 PHONE_TAKEN; missing fields -> 400 VALIDATION', async () => {
  const owner = await registerOwner();
  const phone = uniquePhone('0791');

  const first = await api('POST', '/api/account/branches', {
    token: owner.token,
    body: { generatorName: 'B1', phone, password: 'secret1' },
  });
  assert.equal(first.status, 201);

  const dup = await api('POST', '/api/account/branches', {
    token: owner.token,
    body: { generatorName: 'B2', phone, password: 'secret1' },
  });
  assert.equal(dup.status, 409);
  assert.equal(dup.data.code, 'PHONE_TAKEN');

  // A branch's phone also collides with an existing owner account's username.
  const dupOwner = await api('POST', '/api/account/branches', {
    token: owner.token,
    body: { generatorName: 'B3', phone: owner.phone, password: 'secret1' },
  });
  assert.equal(dupOwner.status, 409);
  assert.equal(dupOwner.data.code, 'PHONE_TAKEN');

  const bad = await api('POST', '/api/account/branches', {
    token: owner.token,
    body: { generatorName: 'B4', phone: uniquePhone('0791') }, // no password
  });
  assert.equal(bad.status, 400);
  assert.equal(bad.data.code, 'VALIDATION');
});

// ---------------------------------------------------------------------------
// Branch login + inherited subscription.
// ---------------------------------------------------------------------------
test('branch logs in via /api/auth/login -> token + INHERITED active subscription', async () => {
  const owner = await registerOwner();
  await activatePlan(owner.account.id, 'yearly'); // active plan to inherit
  const b = await createBranch(owner);

  const login = await api('POST', '/api/auth/login', {
    body: { username: b.phone, password: b.password, device: makeDevice() },
  });
  assert.equal(login.status, 200, `branch login should 200, got ${login.status} ${JSON.stringify(login.data)}`);
  const acc = login.data.account;
  assert.equal(acc.role, 'owner', 'a branch is itself a role:owner');
  assert.equal(acc.parentOwnerId, owner.account.id, 'parentOwnerId points at the creator');
  // Inherited subscription from the parent (active yearly), NOT its own 'none'.
  assert.equal(acc.subscription.status, 'active', 'subscription inherited from parent');
  assert.equal(acc.subscription.planCode, 'yearly');
  assert.ok(acc.subscription.features && typeof acc.subscription.features === 'object');
  // A branch IS a real owner of its own mirror, so its login binds a device.
  assert.equal(acc.devices.length, 1, 'branch login binds the device (owner of its own mirror)');

  // /me applies the same inheritance.
  const me = await api('GET', '/api/auth/me', { token: login.data.token });
  assert.equal(me.status, 200);
  assert.equal(me.data.account.parentOwnerId, owner.account.id);
  assert.equal(me.data.account.subscription.status, 'active');
  assert.equal(me.data.account.subscription.planCode, 'yearly');
});

// ---------------------------------------------------------------------------
// Isolation + per-branch owner-panel reads.
// ---------------------------------------------------------------------------
test('branch data is isolated; parent /stats excludes it but /branches/:id/stats includes it', async () => {
  const owner = await registerOwner();
  const b = await createBranch(owner);

  // Owner pushes 1 subscriber + a price into ITS OWN mirror.
  const ownerPush = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [
        {
          entity: 'monthly_prices',
          localId: CURRENT_MONTH,
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { month: CURRENT_MONTH, price_per_amp: 100, category: 'standard' },
        },
        {
          entity: 'subscribers',
          localId: 'owner-sub-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'owner-sub-1', name: 'Owner Sub', amps: 10, category: 'standard', status: 'active' },
        },
      ],
    },
  });
  assert.equal(ownerPush.status, 200);

  // Branch logs in and pushes its OWN subscriber + price + receipt into ITS mirror.
  const blogin = await api('POST', '/api/auth/login', {
    body: { username: b.phone, password: b.password, device: makeDevice() },
  });
  assert.equal(blogin.status, 200);
  const bToken = blogin.data.token;

  const branchPush = await api('POST', '/api/sync/push', {
    token: bToken,
    body: {
      records: [
        {
          entity: 'monthly_prices',
          localId: CURRENT_MONTH,
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { month: CURRENT_MONTH, price_per_amp: 100, category: 'standard' },
        },
        {
          entity: 'subscribers',
          localId: 'branch-sub-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'branch-sub-1', name: 'Branch Sub', amps: 5, category: 'standard', status: 'active' },
        },
        {
          entity: 'receipts',
          localId: 'branch-rec-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: {
            uuid: 'branch-rec-1',
            receipt_no: 1,
            subscriber_id: 'branch-sub-1',
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
  assert.equal(branchPush.status, 200, `branch push should 200, got ${branchPush.status} ${JSON.stringify(branchPush.data)}`);
  assert.equal(branchPush.data.count, 3);

  // Parent's OWN /stats sees ONLY its own subscriber (1), not the branch's.
  const ownerStats = await api('GET', `/api/account/stats?month=${CURRENT_MONTH}`, { token: owner.token });
  assert.equal(ownerStats.status, 200);
  assert.equal(Number(ownerStats.data.counts.subscribers), 1, "parent's own mirror has only its 1 subscriber");
  assert.equal(Number(ownerStats.data.dashboard.collected), 0, "parent's own mirror collected nothing");

  // Parent reads the BRANCH's stats via the per-branch endpoint.
  const branchStats = await api('GET', `/api/account/branches/${b.id}/stats?month=${CURRENT_MONTH}`, { token: owner.token });
  assert.equal(branchStats.status, 200, `branch stats should 200, got ${branchStats.status} ${JSON.stringify(branchStats.data)}`);
  assert.equal(Number(branchStats.data.counts.subscribers), 1, 'branch mirror has its 1 subscriber');
  assert.equal(Number(branchStats.data.dashboard.collected), 500, 'branch dashboard reflects the branch receipt');

  // The branch's OWN /api/account/stats (it is an owner) === the parent's view of it.
  const branchSelfStats = await api('GET', `/api/account/stats?month=${CURRENT_MONTH}`, { token: bToken });
  assert.equal(branchSelfStats.status, 200);
  assert.equal(
    Number(branchSelfStats.data.dashboard.collected),
    Number(branchStats.data.dashboard.collected),
    'parent per-branch stats === branch self stats'
  );

  // Parent reads the branch's DATA via the per-branch endpoint.
  const branchData = await api('GET', `/api/account/branches/${b.id}/data?entity=subscribers`, { token: owner.token });
  assert.equal(branchData.status, 200);
  const ids = branchData.data.records.map((r) => r.localId).sort();
  assert.deepEqual(ids, ['branch-sub-1'], 'per-branch data shows only the branch mirror');
});

// ---------------------------------------------------------------------------
// Authorization: sub-branches, non-owners, cross-owner.
// ---------------------------------------------------------------------------
test('a branch cannot create a sub-branch -> 403 SUB_BRANCH_FORBIDDEN', async () => {
  const owner = await registerOwner();
  const b = await createBranch(owner);

  const blogin = await api('POST', '/api/auth/login', {
    body: { username: b.phone, password: b.password },
  });
  assert.equal(blogin.status, 200);

  const sub = await api('POST', '/api/account/branches', {
    token: blogin.data.token,
    body: { generatorName: 'Sub-branch', phone: uniquePhone('0792'), password: 'secret1' },
  });
  assert.equal(sub.status, 403, `sub-branch should 403, got ${sub.status} ${JSON.stringify(sub.data)}`);
  assert.equal(sub.data.code, 'SUB_BRANCH_FORBIDDEN');
});

test('a non-owner (accountant) cannot create a branch -> 403 FORBIDDEN', async () => {
  const owner = await registerOwner();
  // Owner makes an accountant.
  const acctUser = `acct${Date.now()}`;
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: { name: 'Acct', username: acctUser, password: 'secret1' },
  });
  assert.equal(created.status, 201);
  const acctLogin = await api('POST', '/api/auth/login', { body: { username: acctUser, password: 'secret1' } });
  assert.equal(acctLogin.status, 200);

  const r = await api('POST', '/api/account/branches', {
    token: acctLogin.data.token,
    body: { generatorName: 'Nope', phone: uniquePhone('0792'), password: 'secret1' },
  });
  assert.equal(r.status, 403);
  assert.equal(r.data.code, 'FORBIDDEN');

  // Accountant also cannot list branches.
  const list = await api('GET', '/api/account/branches', { token: acctLogin.data.token });
  assert.equal(list.status, 403);
  assert.equal(list.data.code, 'FORBIDDEN');
});

test('another owner cannot read this owner\'s branch -> 404 BRANCH_NOT_FOUND', async () => {
  const ownerA = await registerOwner();
  const ownerB = await registerOwner();
  const b = await createBranch(ownerA);

  // Owner B does not see A's branch in its own list.
  const bList = await api('GET', '/api/account/branches', { token: ownerB.token });
  assert.equal(bList.status, 200);
  assert.ok(!bList.data.branches.some((x) => x.id === b.id), "B must not see A's branch");

  // Owner B cannot read A's branch stats/data -> 404 (ownership-scoped).
  const stats = await api('GET', `/api/account/branches/${b.id}/stats`, { token: ownerB.token });
  assert.equal(stats.status, 404);
  assert.equal(stats.data.code, 'BRANCH_NOT_FOUND');

  const data = await api('GET', `/api/account/branches/${b.id}/data?entity=subscribers`, { token: ownerB.token });
  assert.equal(data.status, 404);
  assert.equal(data.data.code, 'BRANCH_NOT_FOUND');
});

// ---------------------------------------------------------------------------
// Cascade block.
// ---------------------------------------------------------------------------
test('blocking the PARENT blocks the branch (login 403 + existing token 403)', async () => {
  const owner = await registerOwner();
  const b = await createBranch(owner);

  // Branch can log in BEFORE the parent is blocked.
  const pre = await api('POST', '/api/auth/login', { body: { username: b.phone, password: b.password } });
  assert.equal(pre.status, 200);
  const bToken = pre.data.token;

  // Admin blocks the PARENT.
  const adminTok = await getAdminToken();
  const blk = await api('PUT', `/api/admin/users/${owner.account.id}/blocked`, {
    token: adminTok,
    body: { blocked: true },
  });
  assert.equal(blk.status, 200);

  // Fresh branch login is now rejected...
  const post = await api('POST', '/api/auth/login', { body: { username: b.phone, password: b.password } });
  assert.equal(post.status, 403, `blocked parent -> branch login should 403, got ${post.status}`);
  assert.equal(post.data.code, 'BLOCKED');

  // ...and an ALREADY-issued branch token is rejected by requireAuth.
  const me = await api('GET', '/api/auth/me', { token: bToken });
  assert.equal(me.status, 403, 'existing branch token must be rejected once the parent is blocked');
  assert.equal(me.data.code, 'BLOCKED');
});
