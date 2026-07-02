/**
 * Integration tests for the OWNER self-service data endpoints:
 *
 *  - GET /api/account/stats          -> per-entity counts of the caller's own
 *                                       mirrored business data (subscribers,
 *                                       boards, receipts, ...) plus a
 *                                       `dashboard` object replicating the
 *                                       Flutter app home screen: paid/unpaid
 *                                       subscriber counts for the CURRENT
 *                                       month (paid = sum of that month's
 *                                       receipts.paid_amount >= amps *
 *                                       price_per_amp; price 0 if the month
 *                                       has no monthly_prices row), the
 *                                       collected amount and price per amp.
 *                                       An optional ?month=YYYY-MM selects
 *                                       which month the dashboard describes
 *                                       (invalid values fall back to the
 *                                       current month); the dashboard also
 *                                       carries expensesTotal (sum of that
 *                                       month's expenses) and netProfit
 *                                       (collected - expensesTotal).
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
let ownerC; // dedicated to the dashboard tests so A/B count assertions stay valid

// The dashboard is computed for the CURRENT month — derive 'YYYY-MM' exactly
// like the backend does so these tests are date-independent.
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
async function registerOwner({ phone, deviceOverrides } = {}) {
  const username = uniqueUsername();
  const password = 'secret1';
  const device = makeDevice(deviceOverrides);
  const r = await api('POST', '/api/auth/register', {
    body: { name: 'Owner Name', phone: phone || username, username, password, device },
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

// The dashboard object of /api/account/stats; tolerate it living at the top
// level or nested under a stats key.
function extractDashboard(body) {
  if (body && typeof body === 'object') {
    if (body.dashboard && typeof body.dashboard === 'object') return body.dashboard;
    if (body.stats && typeof body.stats === 'object' && body.stats.dashboard) {
      return body.stats.dashboard;
    }
  }
  return undefined;
}

// First value that is neither undefined nor null (key-name tolerance for the
// boards/circuits dashboard counters).
function firstDefined(...values) {
  for (const v of values) {
    if (v !== undefined && v !== null) return v;
  }
  return undefined;
}

// ---------------------------------------------------------------------------
// Boot / teardown. Owner A pushes 2 subscribers + 1 board + 1 receipt (linked
// to a-sub-1 via data.subscriber_id); owner B pushes 1 subscriber. All later
// tests assert against this fixed dataset. Owner C is a separate account used
// only by the dashboard tests (current-month price + paid/unpaid receipts) so
// the A/B count expectations above are never disturbed.
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
  ownerC = await registerOwner({ phone: '0700001003' });

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

  // Owner C: a full current-month dashboard fixture. Price 1000/amp; c-sub-1
  // (10A) fully paid via 10000; c-sub-2 (15A) only 5000 of 15000 -> unpaid.
  const cPush = await api('POST', '/api/sync/push', {
    token: ownerC.token,
    body: {
      records: [
        {
          entity: 'monthly_prices',
          localId: CURRENT_MONTH,
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { month: CURRENT_MONTH, price_per_amp: 1000 },
        },
        {
          entity: 'boards',
          localId: 'c-board-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'c-board-1', name: 'C Board', code: 'CB-01' },
        },
        {
          entity: 'circuits',
          localId: 'c-c1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'c-c1', board_id: 'c-board-1', name: 'C Line 1', phase: 'A' },
        },
        {
          entity: 'subscribers',
          localId: 'c-sub-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'c-sub-1', name: 'Paid Person', phone: '0780000010', amps: 10, board_id: 'c-board-1', circuit_id: 'c-c1', status: 'active' },
        },
        {
          entity: 'subscribers',
          localId: 'c-sub-2',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'c-sub-2', name: 'Unpaid Person', phone: '0780000011', amps: 15, board_id: 'c-board-1', circuit_id: 'c-c1', status: 'active' },
        },
        {
          entity: 'receipts',
          localId: 'c-rec-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: {
            uuid: 'c-rec-1',
            receipt_no: 1,
            subscriber_id: 'c-sub-1',
            month: CURRENT_MONTH,
            amps_snapshot: 10,
            price_snapshot: 1000,
            paid_amount: 10000,
            remaining_after: 0,
            issued_at: `${CURRENT_MONTH}-01T00:00:00.000Z`,
            status: 'valid',
          },
        },
        {
          entity: 'receipts',
          localId: 'c-rec-2',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: {
            uuid: 'c-rec-2',
            receipt_no: 2,
            subscriber_id: 'c-sub-2',
            month: CURRENT_MONTH,
            amps_snapshot: 15,
            price_snapshot: 1000,
            paid_amount: 5000,
            remaining_after: 10000,
            issued_at: `${CURRENT_MONTH}-02T00:00:00.000Z`,
            status: 'valid',
          },
        },
      ],
    },
  });
  assert.equal(cPush.status, 200, `C push should 200, got ${cPush.status} ${JSON.stringify(cPush.data)}`);
  assert.equal(cPush.data.count, 7);
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
// /api/account/stats — `dashboard` object (app home-screen replica).
//
// Owner C fixture (pushed in test.before, current month M, P = 1000/amp):
//   c-sub-1 (10A):  paid 10000 >= 10 * 1000 -> PAID
//   c-sub-2 (15A):  paid  5000 <  15 * 1000 -> UNPAID
//   collected for M = 10000 + 5000 = 15000
// ---------------------------------------------------------------------------
test('GET /api/account/stats dashboard applies the app paid/unpaid formula (owner C)', async () => {
  const r = await api('GET', '/api/account/stats', { token: ownerC.token });
  assert.equal(r.status, 200, `stats should 200, got ${r.status} ${JSON.stringify(r.data)}`);

  const dashboard = extractDashboard(r.data);
  assert.ok(
    dashboard && typeof dashboard === 'object',
    `stats response must include a dashboard object, got ${JSON.stringify(r.data)}`
  );

  assert.equal(Number(dashboard.totalSubscribers), 2, 'C pushed 2 subscribers');
  assert.equal(Number(dashboard.paidCount), 1, 'only c-sub-1 covers amps * price (10000 >= 10000)');
  assert.equal(Number(dashboard.unpaidCount), 1, 'c-sub-2 paid 5000 of 15000 -> unpaid');
  assert.equal(Number(dashboard.collected), 15000, 'current-month collected = 10000 + 5000');
  assert.equal(Number(dashboard.pricePerAmp), 1000, 'current-month price_per_amp');

  const boardsCount = firstDefined(dashboard.totalBoards, dashboard.boards);
  const circuitsCount = firstDefined(dashboard.totalCircuits, dashboard.circuits);
  assert.equal(Number(boardsCount), 1, 'C pushed 1 board');
  assert.equal(Number(circuitsCount), 1, 'C pushed 1 circuit');

  // The plain per-entity counts must still be present alongside the dashboard.
  const counts = extractCounts(r.data);
  assert.equal(Number(counts.subscribers), 2);
  assert.equal(Number(counts.receipts), 2);
  assert.equal(Number(counts.monthly_prices), 1);
});

test('dashboard is per-account: owner B (no price row) counts everyone as UNPAID', async () => {
  const r = await api('GET', '/api/account/stats', { token: ownerB.token });
  assert.equal(r.status, 200, `stats should 200, got ${r.status} ${JSON.stringify(r.data)}`);

  const dashboard = extractDashboard(r.data);
  assert.ok(
    dashboard && typeof dashboard === 'object',
    `stats response must include a dashboard object, got ${JSON.stringify(r.data)}`
  );

  // v23 (§2.2): B never pushed monthly_prices -> its category is UNPRICED -> its
  // single subscriber counts UNPAID (subscribers start unpaid until a price is
  // set), exactly like the app. Nothing of C's data may leak in.
  assert.equal(Number(dashboard.totalSubscribers), 1, 'B has exactly 1 subscriber');
  assert.equal(Number(dashboard.paidCount), 0, 'no price row -> nobody counts paid');
  assert.equal(Number(dashboard.unpaidCount), 1, 'the unpriced subscriber counts unpaid');
  assert.equal(Number(dashboard.collected || 0), 0, 'B pushed no receipts');
  assert.equal(Number(dashboard.pricePerAmp || 0), 0, 'no monthly_prices row for the current month');
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

// ---------------------------------------------------------------------------
// /api/account/stats — monthly report fields (expensesTotal / netProfit) and
// the optional ?month=YYYY-MM selector.
//
// These tests PUSH additional fixtures for owner C. node:test runs tests
// sequentially in declaration order, so pushing inside these test bodies
// (declared last) keeps every earlier dashboard/count assertion untouched.
// ---------------------------------------------------------------------------
test('dashboard.expensesTotal sums only the selected month; netProfit = collected - expenses', async () => {
  // Two current-month expenses (2000 + 1000) and one from 2020-01 (999) that
  // must be excluded. amount '1000' is pushed as a string on purpose — the
  // mirror is untyped, so the backend must coerce numbers.
  const push = await api('POST', '/api/sync/push', {
    token: ownerC.token,
    body: {
      records: [
        {
          entity: 'expenses',
          localId: 'c-exp-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'c-exp-1', category: 'fuel', amount: 2000, note: null, date: `${CURRENT_MONTH}-05` },
        },
        {
          entity: 'expenses',
          localId: 'c-exp-2',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'c-exp-2', category: 'oil', amount: '1000', note: 'stringy amount', date: `${CURRENT_MONTH}-05` },
        },
        {
          entity: 'expenses',
          localId: 'c-exp-old',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'c-exp-old', category: 'maintenance', amount: 999, note: 'other month', date: '2020-01-15' },
        },
      ],
    },
  });
  assert.equal(push.status, 200, `expense push should 200, got ${push.status} ${JSON.stringify(push.data)}`);
  assert.equal(push.data.count, 3);

  const r = await api('GET', '/api/account/stats', { token: ownerC.token });
  assert.equal(r.status, 200, `stats should 200, got ${r.status} ${JSON.stringify(r.data)}`);

  const dashboard = extractDashboard(r.data);
  assert.ok(
    dashboard && typeof dashboard === 'object',
    `stats response must include a dashboard object, got ${JSON.stringify(r.data)}`
  );

  assert.equal(Number(dashboard.expensesTotal), 3000, '2000 + 1000; the 2020-01 expense is excluded');
  assert.equal(Number(dashboard.collected), 15000, 'current-month collected is unchanged by expenses');
  assert.equal(Number(dashboard.netProfit), 12000, 'netProfit = collected (15000) - expenses (3000)');

  const counts = extractCounts(r.data);
  assert.equal(Number(counts.expenses), 3, 'all 3 expense rows are mirrored regardless of month');
});

test('?month=YYYY-MM selects the dashboard month without mixing in other months', async () => {
  // Backfill a complete '2025-01' month for owner C: price 500/amp, one extra
  // subscriber (c-old-sub, 10A) and a 5000 receipt that fully pays them.
  const push = await api('POST', '/api/sync/push', {
    token: ownerC.token,
    body: {
      records: [
        {
          entity: 'monthly_prices',
          localId: '2025-01',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { month: '2025-01', price_per_amp: 500 },
        },
        {
          entity: 'subscribers',
          localId: 'c-old-sub',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'c-old-sub', name: 'Old Month Person', phone: '0780000012', amps: 10, board_id: 'c-board-1', circuit_id: 'c-c1', status: 'active' },
        },
        {
          entity: 'receipts',
          localId: 'c-rec-old',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: {
            uuid: 'c-rec-old',
            receipt_no: 3,
            subscriber_id: 'c-old-sub',
            month: '2025-01',
            amps_snapshot: 10,
            price_snapshot: 500,
            paid_amount: 5000,
            remaining_after: 0,
            issued_at: '2025-01-10T00:00:00.000Z',
            status: 'valid',
          },
        },
      ],
    },
  });
  assert.equal(push.status, 200, `2025-01 push should 200, got ${push.status} ${JSON.stringify(push.data)}`);
  assert.equal(push.data.count, 3);

  const r = await api('GET', '/api/account/stats?month=2025-01', { token: ownerC.token });
  assert.equal(r.status, 200, `stats should 200, got ${r.status} ${JSON.stringify(r.data)}`);

  const dashboard = extractDashboard(r.data);
  assert.ok(
    dashboard && typeof dashboard === 'object',
    `stats response must include a dashboard object, got ${JSON.stringify(r.data)}`
  );

  assert.equal(dashboard.month, '2025-01', 'dashboard must describe the requested month');
  assert.equal(Number(dashboard.pricePerAmp), 500, "2025-01's monthly_prices row, not the current month's 1000");
  assert.equal(Number(dashboard.collected), 5000, 'only the 2025-01 receipt — the 15000 of the current month must not leak in');
  assert.equal(Number(dashboard.expensesTotal || 0), 0, 'no 2025-01 expenses (the 2020-01 one stays excluded)');
  assert.equal(Number(dashboard.netProfit), 5000, 'netProfit = 5000 collected - 0 expenses');

  // Subscribers have no month, so all 3 are evaluated against P(2025-01)=500:
  // only c-old-sub (10A) has 2025-01 receipts covering 10 * 500.
  assert.equal(Number(dashboard.totalSubscribers), 3, 'c-sub-1 + c-sub-2 + c-old-sub');
  assert.equal(Number(dashboard.paidCount), 1, 'only c-old-sub paid 5000 >= 10 * 500 in 2025-01');
  assert.equal(Number(dashboard.unpaidCount), 2, 'c-sub-1/c-sub-2 have no 2025-01 receipts');

  // And the default (no ?month) must still be the CURRENT month, with the
  // 2025-01 backfill excluded from its money totals. The new subscriber has
  // no current-month receipt, so the current month now counts them as unpaid.
  const cur = await api('GET', '/api/account/stats', { token: ownerC.token });
  assert.equal(cur.status, 200);
  const curDash = extractDashboard(cur.data);
  assert.equal(curDash.month, CURRENT_MONTH);
  assert.equal(Number(curDash.collected), 15000, 'the 2025-01 receipt must not be mixed into the current month');
  assert.equal(Number(curDash.pricePerAmp), 1000);
  assert.equal(Number(curDash.totalSubscribers), 3);
  assert.equal(Number(curDash.paidCount), 1, 'c-old-sub has no current-month receipt -> unpaid');
  assert.equal(Number(curDash.unpaidCount), 2);
  assert.equal(Number(curDash.expensesTotal), 3000);
  assert.equal(Number(curDash.netProfit), 12000);
});

test('invalid ?month falls back to the current month', async () => {
  const r = await api('GET', '/api/account/stats?month=20xx-99', { token: ownerC.token });
  assert.equal(r.status, 200, `stats should 200, got ${r.status} ${JSON.stringify(r.data)}`);

  const dashboard = extractDashboard(r.data);
  assert.ok(
    dashboard && typeof dashboard === 'object',
    `stats response must include a dashboard object, got ${JSON.stringify(r.data)}`
  );

  assert.equal(dashboard.month, CURRENT_MONTH, "month '20xx-99' fails /^\\d{4}-\\d{2}$/ -> current month");
  assert.equal(Number(dashboard.collected), 15000, 'and the data is the current-month data');
});

// ---------------------------------------------------------------------------
// /api/account/stats?branchId= scopes the per-entity COUNT cards to that branch
// (full isolation in the owner panel). A separate owner D keeps A/B/C intact.
// ---------------------------------------------------------------------------
test('GET /api/account/stats?branchId= scopes the per-entity counts to that branch', async () => {
  const ownerD = await registerOwner({ phone: '0700009001' });
  const push = await api('POST', '/api/sync/push', {
    token: ownerD.token,
    body: {
      records: [
        { entity: 'subscribers', localId: 'd-s1', deleted: false, updatedAt: new Date().toISOString(), data: { id: 'd-s1', name: 'M1', amps: 5, branch_id: 'bA' } },
        { entity: 'subscribers', localId: 'd-s2', deleted: false, updatedAt: new Date().toISOString(), data: { id: 'd-s2', name: 'M2', amps: 5, branch_id: 'bA' } },
        { entity: 'subscribers', localId: 'd-s3', deleted: false, updatedAt: new Date().toISOString(), data: { id: 'd-s3', name: 'K1', amps: 5, branch_id: 'bB' } },
        { entity: 'boards', localId: 'd-b1', deleted: false, updatedAt: new Date().toISOString(), data: { id: 'd-b1', name: 'BA', branch_id: 'bA' } },
      ],
    },
  });
  assert.equal(push.status, 200, `push should 200, got ${push.status} ${JSON.stringify(push.data)}`);

  // No branch -> all rows counted.
  const all = await api('GET', '/api/account/stats', { token: ownerD.token });
  assert.equal(Number(extractCounts(all.data).subscribers), 3, 'all 3 subscribers when no branch filter');
  assert.equal(Number(extractCounts(all.data).boards), 1);

  // branchId=bA -> only that branch's rows.
  const bA = await api('GET', '/api/account/stats?branchId=bA', { token: ownerD.token });
  assert.equal(Number(extractCounts(bA.data).subscribers), 2, 'branch bA has 2 subscribers');
  assert.equal(Number(extractCounts(bA.data).boards), 1, 'branch bA has 1 board');

  // branchId=bB -> only that branch's rows.
  const bB = await api('GET', '/api/account/stats?branchId=bB', { token: ownerD.token });
  assert.equal(Number(extractCounts(bB.data).subscribers), 1, 'branch bB has 1 subscriber');
  assert.equal(Number(extractCounts(bB.data).boards), 0, 'branch bB has no boards');
});
