/**
 * Integration tests for the offline-first SYNC server side.
 *
 * Mirrors backend/test/api.test.mjs: boots a REAL Express server on an
 * ephemeral port against an in-memory MongoDB (USE_MEMORY_DB=true) and an
 * isolated temp BACKUP_DIR, so the suite is hermetic.
 *
 *   cd backend && npm test
 *
 * IMPORTANT: process.env MUST be configured before any backend module is
 * required, because src/config/env.js snapshots process.env at require time.
 *
 * Sync contract under test:
 *  - POST /api/sync/push  { records: [{ entity, localId, deleted, updatedAt, data? }] }
 *      -> 200 { ok: true, count: N, serverTime: ISO }
 *  - GET  /api/sync/pull?since=ISO -> { records: [{ entity, localId, deleted, updatedAt, data }] }
 *  - GET  /api/admin/users/:id/data?entity=subscribers (admin only)
 *      -> { entity, records: [{ localId, data, deleted, updatedAt }] } (excludes deleted)
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
const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-sync-test-backups-'));

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

// A push body for one subscriber upsert + one subscriber delete.
function makeSyncBody(now) {
  const ts = now || new Date().toISOString();
  return {
    records: [
      {
        entity: 'subscribers',
        localId: 'sub-1',
        deleted: false,
        updatedAt: ts,
        data: {
          id: 'sub-1',
          name: 'Ahmed',
          phone: '0770',
          amps: 10,
          board_id: 'board-1',
          circuit_id: 'circuit-1',
          status: 'active',
        },
      },
      {
        entity: 'subscribers',
        localId: 'sub-2',
        deleted: true,
        updatedAt: ts,
      },
    ],
  };
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
// Auth gate on the sync routes
// ---------------------------------------------------------------------------
test('POST /api/sync/push without a token -> 401', async () => {
  const r = await api('POST', '/api/sync/push', { body: makeSyncBody() });
  assert.equal(r.status, 401);
});

test('GET /api/sync/pull without a token -> 401', async () => {
  const r = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z');
  assert.equal(r.status, 401);
});

// ---------------------------------------------------------------------------
// Push -> Pull round-trip
// ---------------------------------------------------------------------------
test('push upserts + deletes records -> 200 { ok, count, serverTime }', async () => {
  const { token } = await registerOwner();

  const r = await api('POST', '/api/sync/push', { token, body: makeSyncBody() });
  assert.equal(r.status, 200, `push should 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.ok, true);
  assert.equal(r.data.count, 2);
  assert.equal(typeof r.data.serverTime, 'string');
  // serverTime is a valid ISO timestamp.
  assert.ok(!Number.isNaN(new Date(r.data.serverTime).getTime()));
});

test('pull returns all pushed records (since the epoch) incl. the deleted one', async () => {
  const { token } = await registerOwner();

  const push = await api('POST', '/api/sync/push', { token, body: makeSyncBody() });
  assert.equal(push.status, 200);

  const pull = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z', { token });
  assert.equal(pull.status, 200);
  assert.ok(Array.isArray(pull.data.records));

  const byId = new Map(pull.data.records.map((rec) => [rec.localId, rec]));

  const up = byId.get('sub-1');
  assert.ok(up, 'pull must include the upserted subscriber');
  assert.equal(up.entity, 'subscribers');
  assert.equal(up.deleted, false);
  assert.equal(up.data.name, 'Ahmed');
  assert.equal(up.data.board_id, 'board-1');
  assert.equal(typeof up.updatedAt, 'string');

  const del = byId.get('sub-2');
  assert.ok(del, 'pull (full restore) must include the deleted tombstone');
  assert.equal(del.deleted, true);
});

test('pull is scoped per-account: another owner does not see the first owner records', async () => {
  const a = await registerOwner();
  const b = await registerOwner();

  await api('POST', '/api/sync/push', { token: a.token, body: makeSyncBody() });

  const bPull = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z', { token: b.token });
  assert.equal(bPull.status, 200);
  const bIds = bPull.data.records.map((rec) => rec.localId);
  assert.ok(!bIds.includes('sub-1'), 'owner B must not see owner A upsert');
  assert.ok(!bIds.includes('sub-2'), 'owner B must not see owner A tombstone');
});

test('push upserts (last write wins) when the same localId is pushed again', async () => {
  const { token } = await registerOwner();

  // First push: name Ahmed.
  await api('POST', '/api/sync/push', { token, body: makeSyncBody() });

  // Second push: same localId 'sub-1' with a newer value.
  const later = new Date(Date.now() + 60_000).toISOString();
  const update = await api('POST', '/api/sync/push', {
    token,
    body: {
      records: [
        {
          entity: 'subscribers',
          localId: 'sub-1',
          deleted: false,
          updatedAt: later,
          data: {
            id: 'sub-1',
            name: 'Ahmed Updated',
            amps: 20,
            board_id: 'board-1',
            circuit_id: 'circuit-1',
            status: 'active',
          },
        },
      ],
    },
  });
  assert.equal(update.status, 200);

  const pull = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z', { token });
  const recs = pull.data.records.filter((rec) => rec.localId === 'sub-1');
  assert.equal(recs.length, 1, 'the same (entity, localId) must be a single upserted row');
  assert.equal(recs[0].data.name, 'Ahmed Updated');
});

// ---------------------------------------------------------------------------
// Admin data view
// ---------------------------------------------------------------------------
test('admin GET /api/admin/users/:id/data?entity=subscribers shows the non-deleted record', async () => {
  const owner = await registerOwner();
  const adminTok = await getAdminToken();

  const push = await api('POST', '/api/sync/push', { token: owner.token, body: makeSyncBody() });
  assert.equal(push.status, 200);

  const r = await api(
    'GET',
    `/api/admin/users/${owner.account.id}/data?entity=subscribers`,
    { token: adminTok }
  );
  assert.equal(r.status, 200, `admin data should 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.entity, 'subscribers');
  assert.ok(Array.isArray(r.data.records));

  const ids = r.data.records.map((rec) => rec.localId);
  assert.ok(ids.includes('sub-1'), 'admin view must include the non-deleted subscriber');
  assert.ok(!ids.includes('sub-2'), 'admin view must exclude deleted records by default');

  const up = r.data.records.find((rec) => rec.localId === 'sub-1');
  assert.equal(up.deleted, false);
  assert.equal(up.data.name, 'Ahmed');
  assert.equal(typeof up.updatedAt, 'string');
});

test('admin data view with ?includeDeleted=true also returns tombstones', async () => {
  const owner = await registerOwner();
  const adminTok = await getAdminToken();

  await api('POST', '/api/sync/push', { token: owner.token, body: makeSyncBody() });

  const r = await api(
    'GET',
    `/api/admin/users/${owner.account.id}/data?entity=subscribers&includeDeleted=true`,
    { token: adminTok }
  );
  assert.equal(r.status, 200);
  const ids = r.data.records.map((rec) => rec.localId);
  assert.ok(ids.includes('sub-1'));
  assert.ok(ids.includes('sub-2'), 'includeDeleted=true must surface the tombstone');
});

test('owner hitting the admin data route -> 403 FORBIDDEN', async () => {
  const owner = await registerOwner();

  // Owner uses their own token against the admin-only data endpoint.
  const r = await api(
    'GET',
    `/api/admin/users/${owner.account.id}/data?entity=subscribers`,
    { token: owner.token }
  );
  assert.equal(r.status, 403);
  assert.equal(r.data.code, 'FORBIDDEN');
});
