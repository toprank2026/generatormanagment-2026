/**
 * Integration tests for the offline-first SYNC pull endpoint + per-account
 * isolation.
 *
 * Mirrors backend/test/sync.test.mjs: boots a REAL Express server on an
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
 *      scoped strictly to the JWT account; since filters updatedAt > since.
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
const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-sync-pull-test-backups-'));

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
async function registerOwner({ phone, deviceOverrides } = {}) {
  const username = uniqueUsername();
  const password = 'secret1';
  const device = makeDevice(deviceOverrides);
  const r = await api('POST', '/api/auth/register', {
    body: { name: 'Owner Name', phone: phone || '0770', username, password, device },
  });
  assert.equal(r.status, 201, `register should 201, got ${r.status} ${JSON.stringify(r.data)}`);
  return { token: r.data.token, account: r.data.account, username, password, device };
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
// Per-account isolation: each owner only ever pulls their own records.
// ---------------------------------------------------------------------------
test('pull is strictly per-account: A pulls only A, B pulls only B', async () => {
  const a = await registerOwner({ phone: '0700000001' });
  const b = await registerOwner({ phone: '0700000002' });

  // Owner A pushes 2 subscribers + 1 receipt.
  const aPush = await api('POST', '/api/sync/push', {
    token: a.token,
    body: {
      records: [
        {
          entity: 'subscribers',
          localId: 'a-sub-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'a-sub-1', name: 'A One', amps: 10, board_id: 'a-b1', circuit_id: 'a-c1', status: 'active' },
        },
        {
          entity: 'subscribers',
          localId: 'a-sub-2',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'a-sub-2', name: 'A Two', amps: 15, board_id: 'a-b1', circuit_id: 'a-c1', status: 'active' },
        },
        {
          entity: 'receipts',
          localId: 'a-rec-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: {
            uuid: 'a-rec-1',
            receipt_no: 1,
            subscriber_id: 'a-sub-1',
            month: '2026-06',
            amps_snapshot: 10,
            price_snapshot: 5,
            paid_amount: 50,
            remaining_after: 0,
            issued_at: '2026-06-01T00:00:00.000Z',
            status: 'valid',
          },
        },
      ],
    },
  });
  assert.equal(aPush.status, 200, `A push should 200, got ${aPush.status} ${JSON.stringify(aPush.data)}`);
  assert.equal(aPush.data.count, 3);

  // Owner B pushes 1 different subscriber.
  const bPush = await api('POST', '/api/sync/push', {
    token: b.token,
    body: {
      records: [
        {
          entity: 'subscribers',
          localId: 'b-sub-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'b-sub-1', name: 'B One', amps: 20, board_id: 'b-b1', circuit_id: 'b-c1', status: 'active' },
        },
      ],
    },
  });
  assert.equal(bPush.status, 200);
  assert.equal(bPush.data.count, 1);

  // A pulls -> exactly A's 3 records, none of B's.
  const aPull = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z', { token: a.token });
  assert.equal(aPull.status, 200);
  assert.ok(Array.isArray(aPull.data.records));
  const aIds = aPull.data.records.map((rec) => rec.localId).sort();
  assert.equal(aPull.data.records.length, 3, 'A must pull exactly its 3 records');
  assert.deepEqual(aIds, ['a-rec-1', 'a-sub-1', 'a-sub-2']);
  assert.ok(!aIds.includes('b-sub-1'), 'A must never see B records');

  // B pulls -> exactly B's 1 record, none of A's.
  const bPull = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z', { token: b.token });
  assert.equal(bPull.status, 200);
  const bIds = bPull.data.records.map((rec) => rec.localId);
  assert.deepEqual(bIds, ['b-sub-1'], 'B must pull only its own record');
  assert.ok(!bIds.includes('a-sub-1'));
  assert.ok(!bIds.includes('a-sub-2'));
  assert.ok(!bIds.includes('a-rec-1'));
});

// ---------------------------------------------------------------------------
// since filtering: future -> empty, past -> everything.
// ---------------------------------------------------------------------------
test('pull?since=<future> returns empty; since=<past> returns all', async () => {
  const owner = await registerOwner({ phone: '0700000003' });

  const now = new Date();
  const push = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [
        {
          entity: 'subscribers',
          localId: 's-future-1',
          deleted: false,
          updatedAt: now.toISOString(),
          data: { id: 's-future-1', name: 'When', amps: 10, board_id: 'b1', circuit_id: 'c1', status: 'active' },
        },
        {
          entity: 'subscribers',
          localId: 's-future-2',
          deleted: false,
          updatedAt: now.toISOString(),
          data: { id: 's-future-2', name: 'Whenever', amps: 12, board_id: 'b1', circuit_id: 'c1', status: 'active' },
        },
      ],
    },
  });
  assert.equal(push.status, 200);
  assert.equal(push.data.count, 2);

  // A timestamp far in the future -> nothing was updated after it.
  const future = new Date(Date.now() + 365 * 24 * 60 * 60 * 1000).toISOString();
  const futurePull = await api('GET', `/api/sync/pull?since=${encodeURIComponent(future)}`, {
    token: owner.token,
  });
  assert.equal(futurePull.status, 200);
  assert.equal(futurePull.data.records.length, 0, 'future since must return no records');

  // A timestamp far in the past -> everything.
  const past = new Date(Date.now() - 365 * 24 * 60 * 60 * 1000).toISOString();
  const pastPull = await api('GET', `/api/sync/pull?since=${encodeURIComponent(past)}`, {
    token: owner.token,
  });
  assert.equal(pastPull.status, 200);
  const ids = pastPull.data.records.map((rec) => rec.localId).sort();
  assert.deepEqual(ids, ['s-future-1', 's-future-2'], 'past since must return all records');
});

// ---------------------------------------------------------------------------
// Tombstones round-trip with deleted:true.
// ---------------------------------------------------------------------------
test('a pushed tombstone (deleted:true) comes back from pull with deleted:true', async () => {
  const owner = await registerOwner({ phone: '0700000004' });

  const push = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [
        {
          entity: 'subscribers',
          localId: 'alive-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'alive-1', name: 'Alive', amps: 10, board_id: 'b1', circuit_id: 'c1', status: 'active' },
        },
        {
          entity: 'subscribers',
          localId: 'tomb-1',
          deleted: true,
          updatedAt: new Date().toISOString(),
        },
      ],
    },
  });
  assert.equal(push.status, 200);
  assert.equal(push.data.count, 2);

  const pull = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z', { token: owner.token });
  assert.equal(pull.status, 200);
  const byId = new Map(pull.data.records.map((rec) => [rec.localId, rec]));

  const alive = byId.get('alive-1');
  assert.ok(alive, 'pull must include the live record');
  assert.equal(alive.deleted, false);
  assert.equal(alive.data.name, 'Alive');

  const tomb = byId.get('tomb-1');
  assert.ok(tomb, 'pull must include the tombstone');
  assert.equal(tomb.deleted, true, 'the tombstone must round-trip as deleted:true');
});
