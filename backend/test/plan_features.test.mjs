/**
 * Integration tests for PER-PLAN CAPABILITY FLAGS.
 *
 * An admin chooses, per plan, whether that plan includes each capability; the
 * account's ACTIVE plan then enables/disables it everywhere:
 *   (1) sync       — online data sync (push/pull to the server mirror).
 *   (2) backup     — cloud backup (upload/list/restore/delete).
 *   (3) ownerPanel — the owner self-service dashboard (#/my*, /api/account/*).
 * Defaults: every flag defaults TRUE (existing plans keep all capabilities).
 * Flags resolve LIVE from the active plan (no User-schema change / snapshot).
 *
 * Contract under test:
 *  - Plan model gains syncEnabled / backupEnabled / ownerPanelEnabled (Boolean,
 *    default true); serializePlan() exposes them as flat booleans.
 *  - The account JSON gains account.subscription.features =
 *    { sync, backup, ownerPanel }, attached AFTER serializeAccount on
 *    login/register/me via featuresForUser().
 *  - requireFeature(name) middleware -> 403 { code:'FEATURE_DISABLED', feature }
 *    when the caller's active plan disables that capability.
 *
 * Mirrors backend/test/account_data.test.mjs: boots a REAL Express server on an
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
const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-plan-features-test-backups-'));

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
let adminToken = null;
let liteOwner; // owner whose ACTIVE plan is 'lite' (all flags false)
let freeOwner; // control owner: no special plan -> all features default true

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
async function registerOwner({ phone } = {}) {
  const username = uniqueUsername();
  const password = 'secret1';
  const device = makeDevice();
  const r = await api('POST', '/api/auth/register', {
    body: { name: 'Owner Name', phone: phone || username, username, password, device },
  });
  assert.equal(r.status, 201, `register should 201, got ${r.status} ${JSON.stringify(r.data)}`);
  return { token: r.data.token, account: r.data.account, username, password, device };
}

// Admin login (seeded admin). Cached after first call.
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

// The account JSON's subscription.features; tolerate the account living at the
// top level or under an `account` key.
function extractFeatures(body) {
  const account = body && body.account ? body.account : body;
  const sub = account && account.subscription;
  return sub && sub.features;
}

// A minimal valid sync push body (one subscriber upsert).
function makePushBody() {
  return {
    records: [
      {
        entity: 'subscribers',
        localId: 'pf-sub-1',
        deleted: false,
        updatedAt: new Date().toISOString(),
        data: {
          id: 'pf-sub-1',
          name: 'Feature Test',
          phone: '0780000099',
          amps: 10,
          board_id: 'pf-board-1',
          circuit_id: 'pf-c1',
          status: 'active',
        },
      },
    ],
  };
}

// ---------------------------------------------------------------------------
// Boot / teardown. Create the 'lite' plan (all flags false) as admin, register
// two owners, and put liteOwner on 'lite' + active. freeOwner stays on the
// default (no special plan) so its live features are all true.
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

  const adminTok = await getAdminToken();

  // Create the 'lite' plan with every capability disabled.
  const created = await api('PUT', '/api/admin/plans', {
    token: adminTok,
    body: {
      code: 'lite',
      name: 'Lite',
      durationDays: 30,
      maxDevices: 1,
      price: 1000,
      description: 'No sync / backup / owner panel',
      active: true,
      syncEnabled: false,
      backupEnabled: false,
      ownerPanelEnabled: false,
    },
  });
  assert.equal(created.status, 200, `create lite plan should 200, got ${created.status} ${JSON.stringify(created.data)}`);

  liteOwner = await registerOwner({ phone: '0700002001' });
  freeOwner = await registerOwner({ phone: '0700002002' });

  // Put liteOwner on the 'lite' plan, active.
  const setPlan = await api('PUT', `/api/admin/users/${liteOwner.account.id}/plan`, {
    token: adminTok,
    body: { planCode: 'lite', status: 'active' },
  });
  assert.equal(setPlan.status, 200, `set lite plan should 200, got ${setPlan.status} ${JSON.stringify(setPlan.data)}`);
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
// Admin plan flags: serializePlan exposes them; missing flags default true.
// ---------------------------------------------------------------------------
test('GET /api/admin/plans shows the three flags false for the lite plan', async () => {
  const adminTok = await getAdminToken();
  const r = await api('GET', '/api/admin/plans', { token: adminTok });
  assert.equal(r.status, 200, `list plans should 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.ok(Array.isArray(r.data.plans), 'response must carry a plans array');

  const lite = r.data.plans.find((p) => p.code === 'lite');
  assert.ok(lite, "the 'lite' plan must be listed");
  assert.equal(lite.syncEnabled, false, 'lite.syncEnabled must be false');
  assert.equal(lite.backupEnabled, false, 'lite.backupEnabled must be false');
  assert.equal(lite.ownerPanelEnabled, false, 'lite.ownerPanelEnabled must be false');
});

test('a plan created WITHOUT the flags defaults all three to true', async () => {
  const adminTok = await getAdminToken();

  const created = await api('PUT', '/api/admin/plans', {
    token: adminTok,
    body: {
      code: 'full',
      name: 'Full',
      durationDays: 30,
      maxDevices: 2,
      price: 5000,
      description: 'No flags provided -> defaults',
      active: true,
    },
  });
  assert.equal(created.status, 200, `create full plan should 200, got ${created.status} ${JSON.stringify(created.data)}`);

  const r = await api('GET', '/api/admin/plans', { token: adminTok });
  assert.equal(r.status, 200);
  const full = r.data.plans.find((p) => p.code === 'full');
  assert.ok(full, "the 'full' plan must be listed");
  assert.equal(full.syncEnabled, true, 'omitted syncEnabled defaults true');
  assert.equal(full.backupEnabled, true, 'omitted backupEnabled defaults true');
  assert.equal(full.ownerPanelEnabled, true, 'omitted ownerPanelEnabled defaults true');
});

// ---------------------------------------------------------------------------
// account.subscription.features resolves LIVE from the active plan.
// ---------------------------------------------------------------------------
test('lite owner GET /api/auth/me -> features { sync:false, backup:false, ownerPanel:false }', async () => {
  const r = await api('GET', '/api/auth/me', { token: liteOwner.token });
  assert.equal(r.status, 200, `me should 200, got ${r.status} ${JSON.stringify(r.data)}`);

  const features = extractFeatures(r.data);
  assert.ok(features && typeof features === 'object', `me must carry subscription.features, got ${JSON.stringify(r.data)}`);
  assert.deepEqual(
    { sync: features.sync, backup: features.backup, ownerPanel: features.ownerPanel },
    { sync: false, backup: false, ownerPanel: false },
    'lite plan disables all three capabilities'
  );
});

test('control owner (no special plan) GET /api/auth/me -> features all true', async () => {
  const r = await api('GET', '/api/auth/me', { token: freeOwner.token });
  assert.equal(r.status, 200, `me should 200, got ${r.status} ${JSON.stringify(r.data)}`);

  const features = extractFeatures(r.data);
  assert.ok(features && typeof features === 'object', `me must carry subscription.features, got ${JSON.stringify(r.data)}`);
  assert.deepEqual(
    { sync: features.sync, backup: features.backup, ownerPanel: features.ownerPanel },
    { sync: true, backup: true, ownerPanel: true },
    'no active capability-restricting plan -> every feature true'
  );
});

// ---------------------------------------------------------------------------
// Enforcement: the lite owner is 403 FEATURE_DISABLED on each gated endpoint.
// ---------------------------------------------------------------------------
test('lite owner POST /api/sync/push -> 403 FEATURE_DISABLED (sync)', async () => {
  const r = await api('POST', '/api/sync/push', { token: liteOwner.token, body: makePushBody() });
  assert.equal(r.status, 403, `lite push must 403, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.code, 'FEATURE_DISABLED');
  assert.equal(r.data.feature, 'sync');
});

test('lite owner GET /api/account/stats -> 403 FEATURE_DISABLED (ownerPanel)', async () => {
  const r = await api('GET', '/api/account/stats', { token: liteOwner.token });
  assert.equal(r.status, 403, `lite stats must 403, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.code, 'FEATURE_DISABLED');
  assert.equal(r.data.feature, 'ownerPanel');
});

test('lite owner GET /api/backup -> 403 FEATURE_DISABLED (backup)', async () => {
  const r = await api('GET', '/api/backup', { token: liteOwner.token });
  assert.equal(r.status, 403, `lite backup must 403, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.code, 'FEATURE_DISABLED');
  assert.equal(r.data.feature, 'backup');
});

// ---------------------------------------------------------------------------
// Control: the all-true owner is NOT blocked on those same endpoints (200).
// ---------------------------------------------------------------------------
test('control owner POST /api/sync/push -> 200 (sync enabled)', async () => {
  const r = await api('POST', '/api/sync/push', { token: freeOwner.token, body: makePushBody() });
  assert.equal(r.status, 200, `control push must 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.notEqual(r.data.code, 'FEATURE_DISABLED');
});

test('control owner GET /api/account/stats -> 200 (owner panel enabled)', async () => {
  const r = await api('GET', '/api/account/stats', { token: freeOwner.token });
  assert.equal(r.status, 200, `control stats must 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.notEqual(r.data.code, 'FEATURE_DISABLED');
});

test('control owner GET /api/backup -> 200 (backup enabled)', async () => {
  const r = await api('GET', '/api/backup', { token: freeOwner.token });
  assert.equal(r.status, 200, `control backup must 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.notEqual(r.data.code, 'FEATURE_DISABLED');
});
