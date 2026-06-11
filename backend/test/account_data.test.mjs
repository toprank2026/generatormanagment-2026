/**
 * Integration tests for the OWNER self-service data endpoints:
 *
 *  - GET /api/account/stats          -> per-entity counts of the caller's own
 *                                       mirrored business data (subscribers,
 *                                       boards, receipts, ...).
 *  - GET /api/account/data?entity=E  -> the caller's own mirrored rows for one
 *                                       entity, with q (search), relField/
 *                                       relValue (relationship filter) and
 *                                       page/limit, same shape as the admin
 *                                       endpoint: { entity, records, total,
 *                                       page, limit }.
 *
 * Both endpoints are strictly scoped to the JWT account (an owner can only
 * ever see their own mirror) and require a Bearer token (401 otherwise).
 *
 * Mirrors backend/test/sync_pull.test.mjs: boots a REAL Express server on an
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
const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-account-data-test-backups-'));

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
let ownerA; // { token, account, ... }
let ownerB;

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

// The stats endpoint returns per-entity counts; tolerate the counts object
// living at the top level or under a stats/counts key.
function extractCounts(body) {
  if (body && typeof body === 'object') {
    if (body.stats && typeof body.stats === 'object') return body.stats;
    if (body.counts && typeof body.counts === 'object') return body.counts;
  }
  return body;
}

// ---------------------------------------------------------------------------
// Boot / teardown. Owner A pushes 2 subscribers + 1 board + 1 receipt (linked
// to a-sub-1 via data.subscriber_id); owner B pushes 1 subscriber. All later
// tests assert against this fixed dataset.
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

  ownerA = await registerOwner({ phone: '0700001001' });
  ownerB = await registerOwner({ phone: '0700001002' });

  const aPush = await api('POST', '/api/sync/push', {
    token: ownerA.token,
    body: {
      records: [
        {
          entity: 'subscribers',
          localId: 'a-sub-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'a-sub-1', name: 'Ahmed Karim', phone: '0780000001', amps: 10, board_id: 'a-board-1', circuit_id: 'a-c1', status: 'active' },
        },
        {
          entity: 'subscribers',
          localId: 'a-sub-2',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'a-sub-2', name: 'Sara Noor', phone: '0780000002', amps: 15, board_id: 'a-board-1', circuit_id: 'a-c1', status: 'active' },
        },
        {
          entity: 'boards',
          localId: 'a-board-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'a-board-1', name: 'Main Board', code: 'B-01' },
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
  assert.equal(aPush.data.count, 4);

  const bPush = await api('POST', '/api/sync/push', {
    token: ownerB.token,
    body: {
      records: [
        {
          entity: 'subscribers',
          localId: 'b-sub-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'b-sub-1', name: 'Bilal Omar', phone: '0780000003', amps: 20, board_id: 'b-b1', circuit_id: 'b-c1', status: 'active' },
        },
      ],
    },
  });
  assert.equal(bPush.status, 200, `B push should 200, got ${bPush.status} ${JSON.stringify(bPush.data)}`);
  assert.equal(bPush.data.count, 1);
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
// /api/account/stats — per-entity counts, scoped to the caller's account.
// ---------------------------------------------------------------------------
test('GET /api/account/stats counts only the caller account (owner A)', async () => {
  const r = await api('GET', '/api/account/stats', { token: ownerA.token });
  assert.equal(r.status, 200, `stats should 200, got ${r.status} ${JSON.stringify(r.data)}`);

  const counts = extractCounts(r.data);
  assert.equal(Number(counts.subscribers), 2, 'A pushed 2 subscribers');
  assert.equal(Number(counts.boards), 1, 'A pushed 1 board');
  assert.equal(Number(counts.receipts), 1, 'A pushed 1 receipt');
});

test('GET /api/account/stats is isolated per account (owner B)', async () => {
  const r = await api('GET', '/api/account/stats', { token: ownerB.token });
  assert.equal(r.status, 200, `stats should 200, got ${r.status} ${JSON.stringify(r.data)}`);

  const counts = extractCounts(r.data);
  assert.equal(Number(counts.subscribers), 1, 'B pushed exactly 1 subscriber');
  assert.equal(Number(counts.boards || 0), 0, "B must not see A's board in its counts");
  assert.equal(Number(counts.receipts || 0), 0, "B must not see A's receipt in its counts");
});

// ---------------------------------------------------------------------------
// /api/account/data — entity listing, strictly per-account.
// ---------------------------------------------------------------------------
test('GET /api/account/data?entity=subscribers returns only the caller rows', async () => {
  // Owner A: exactly its 2 subscribers, none of B's.
  const a = await api('GET', '/api/account/data?entity=subscribers', { token: ownerA.token });
  assert.equal(a.status, 200, `data should 200, got ${a.status} ${JSON.stringify(a.data)}`);
  assert.equal(a.data.total, 2, 'A has 2 mirrored subscribers');
  assert.ok(Array.isArray(a.data.records));
  const aIds = a.data.records.map((rec) => rec.localId).sort();
  assert.deepEqual(aIds, ['a-sub-1', 'a-sub-2']);
  assert.ok(!aIds.includes('b-sub-1'), "A must never see B's records");

  // Owner B: exactly its 1 subscriber, none of A's.
  const b = await api('GET', '/api/account/data?entity=subscribers', { token: ownerB.token });
  assert.equal(b.status, 200);
  assert.equal(b.data.total, 1, 'B has 1 mirrored subscriber');
  const bIds = b.data.records.map((rec) => rec.localId);
  assert.deepEqual(bIds, ['b-sub-1'], 'B must list only its own record');
  assert.ok(!bIds.includes('a-sub-1'));
  assert.ok(!bIds.includes('a-sub-2'));
});

test('GET /api/account/data?entity=subscribers&q= filters by name substring', async () => {
  const r = await api('GET', '/api/account/data?entity=subscribers&q=ahmed', { token: ownerA.token });
  assert.equal(r.status, 200, `search should 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.total, 1, 'q=ahmed must match exactly one subscriber');
  assert.equal(r.data.records.length, 1);
  assert.equal(r.data.records[0].localId, 'a-sub-1');
  assert.equal(r.data.records[0].data.name, 'Ahmed Karim');

  // A substring that matches nothing for this account.
  const none = await api('GET', '/api/account/data?entity=subscribers&q=zzz-no-match', {
    token: ownerA.token,
  });
  assert.equal(none.status, 200);
  assert.equal(none.data.total, 0);
  assert.equal(none.data.records.length, 0);
});

test('GET /api/account/data relField/relValue returns the linked receipt', async () => {
  const r = await api(
    'GET',
    '/api/account/data?entity=receipts&relField=subscriber_id&relValue=a-sub-1',
    { token: ownerA.token }
  );
  assert.equal(r.status, 200, `relField should 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.total, 1, 'exactly one receipt is linked to a-sub-1');
  assert.equal(r.data.records.length, 1);
  const receipt = r.data.records[0];
  assert.equal(receipt.localId, 'a-rec-1');
  assert.equal(receipt.data.subscriber_id, 'a-sub-1');
  assert.equal(receipt.data.receipt_no, 1);

  // A subscriber with no receipts -> empty.
  const empty = await api(
    'GET',
    '/api/account/data?entity=receipts&relField=subscriber_id&relValue=a-sub-2',
    { token: ownerA.token }
  );
  assert.equal(empty.status, 200);
  assert.equal(empty.data.total, 0);
});

// ---------------------------------------------------------------------------
// Auth: both endpoints reject anonymous requests.
// ---------------------------------------------------------------------------
test('account endpoints without Authorization header return 401', async () => {
  const stats = await api('GET', '/api/account/stats');
  assert.equal(stats.status, 401, `anonymous stats must 401, got ${stats.status}`);

  const data = await api('GET', '/api/account/data?entity=subscribers');
  assert.equal(data.status, 401, `anonymous data must 401, got ${data.status}`);
});
