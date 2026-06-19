/**
 * Integration tests for the PUBLIC receipt endpoint (scan-the-QR, no login).
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
 * Contract under test:
 *  - GET /api/public/receipt/:uuid  (PUBLIC, NO auth middleware)
 *      Looks up the receipt SyncRecord by uuid across ALL accounts:
 *        rec = SyncRecord.findOne({ entity:'receipts', localId: uuid, deleted:false })
 *      and resolves subscriberName (from the owner's subscribers mirror) +
 *      generatorName (from the owning User).
 *      -> 200 {
 *           found: boolean,
 *           receipt: { receipt_no, month, amps_snapshot, price_snapshot,
 *                      category_snapshot, discount_type, discount_value,
 *                      discount_amps, paid_amount, remaining_after, issued_at,
 *                      status } | null,
 *           subscriberName: string|null,
 *           accountantName: string|null,
 *           generatorName: string|null,
 *         }
 *      (category/discount/accountant added so the QR receipt matches the printed
 *      paper receipt field-for-field.)
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
const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-public-receipt-test-backups-'));

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

// Register a brand-new owner with a generatorName.
// Returns { token, account, username, password, device, generatorName }.
async function registerOwner({ generatorName, deviceOverrides } = {}) {
  const username = uniqueUsername();
  const password = 'secret1';
  const device = makeDevice(deviceOverrides);
  const r = await api('POST', '/api/auth/register', {
    body: { name: 'Owner Name', generatorName, phone: username, username, password, device },
  });
  assert.equal(r.status, 201, `register should 201, got ${r.status} ${JSON.stringify(r.data)}`);
  return { token: r.data.token, account: r.data.account, username, password, device, generatorName };
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
// Helpers: push a subscriber + a receipt that references it by subscriber_id.
// ---------------------------------------------------------------------------
const SUBSCRIBER_NAME = 'محمد علي'; // Arabic name to exercise UTF-8 round-trip.
const SUBSCRIBER_ID = 'sub-pub-1';
const RECEIPT_UUID = 'receipt-uuid-abc-123';

// Push one subscriber + one receipt (uuid = RECEIPT_UUID, subscriber_id = SUBSCRIBER_ID).
async function pushSubscriberAndReceipt(token) {
  const ts = new Date().toISOString();
  const r = await api('POST', '/api/sync/push', {
    token,
    body: {
      records: [
        {
          entity: 'subscribers',
          localId: SUBSCRIBER_ID,
          deleted: false,
          updatedAt: ts,
          data: {
            id: SUBSCRIBER_ID,
            name: SUBSCRIBER_NAME,
            phone: '0770',
            amps: 10,
            board_id: 'board-1',
            circuit_id: 'circuit-1',
            status: 'active',
          },
        },
        {
          entity: 'receipts',
          localId: RECEIPT_UUID,
          deleted: false,
          updatedAt: ts,
          data: {
            id: RECEIPT_UUID,
            uuid: RECEIPT_UUID,
            receipt_no: 1042,
            subscriber_id: SUBSCRIBER_ID,
            month: '2026-05',
            amps_snapshot: 10,
            price_snapshot: 5000,
            paid_amount: 50000,
            remaining_after: 0,
            issued_at: ts,
            status: 'paid',
          },
        },
      ],
    },
  });
  assert.equal(r.status, 200, `push should 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.count, 2);
}

// ---------------------------------------------------------------------------
// PUBLIC receipt endpoint
// ---------------------------------------------------------------------------
test('GET /api/public/receipt/:uuid (no auth) -> 200 found:true with receipt + names', async () => {
  const generatorName = 'مولدة الحي';
  const owner = await registerOwner({ generatorName });
  await pushSubscriberAndReceipt(owner.token);

  // No token / no Authorization header at all.
  const r = await api('GET', `/api/public/receipt/${RECEIPT_UUID}`);
  assert.equal(r.status, 200, `public receipt should 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.found, true);
  assert.ok(r.data.receipt, 'found:true must include a receipt object');
  assert.equal(r.data.receipt.receipt_no, 1042);
  assert.equal(r.data.receipt.month, '2026-05');
  assert.equal(r.data.receipt.amps_snapshot, 10);
  assert.equal(r.data.receipt.price_snapshot, 5000);
  assert.equal(r.data.receipt.paid_amount, 50000);
  assert.equal(r.data.receipt.remaining_after, 0);
  assert.equal(r.data.receipt.status, 'paid');
  assert.equal(typeof r.data.receipt.issued_at, 'string');
  assert.equal(r.data.subscriberName, SUBSCRIBER_NAME);
  assert.equal(r.data.generatorName, generatorName);
});

test('GET /api/public/receipt/:uuid requires NO token (request carries no auth header)', async () => {
  const owner = await registerOwner({ generatorName: 'Gen Co' });
  await pushSubscriberAndReceipt(owner.token);

  // Explicitly assert there is no Authorization header on the wire and it still
  // succeeds — this is the whole point of the public scan-the-QR flow.
  const res = await fetch(`${baseUrl}/api/public/receipt/${RECEIPT_UUID}`);
  assert.ok(!res.headers.has('authorization'));
  assert.equal(res.status, 200);
  const data = await res.json();
  assert.equal(data.found, true);
  assert.equal(data.receipt.receipt_no, 1042);
});

test('public receipt exposes tariff type + discount + accountant name (printed-parity)', async () => {
  const owner = await registerOwner({ generatorName: 'مولدة الخصم' });
  const ts = new Date().toISOString();
  const SUB = 'sub-pub-disc', RC = 'receipt-uuid-disc', ACC = 'acc-local-9';
  const push = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [
        { entity: 'accountants', localId: ACC, deleted: false, updatedAt: ts, data: { id: ACC, name: 'كريم' } },
        { entity: 'subscribers', localId: SUB, deleted: false, updatedAt: ts, data: { id: SUB, name: 'علي', amps: 10, status: 'active', category: 'gold' } },
        { entity: 'receipts', localId: RC, deleted: false, updatedAt: ts, data: {
            id: RC, uuid: RC, receipt_no: 7, subscriber_id: SUB, accountant_id: ACC, month: '2026-06',
            amps_snapshot: 10, price_snapshot: 3000, category_snapshot: 'gold',
            discount_type: 'ampere', discount_value: 6000, discount_amps: 2,
            paid_amount: 24000, remaining_after: 0, issued_at: ts, status: 'valid' } },
      ],
    },
  });
  assert.equal(push.status, 200, `push should 200, got ${push.status} ${JSON.stringify(push.data)}`);

  const r = await api('GET', `/api/public/receipt/${RC}`);
  assert.equal(r.status, 200);
  assert.equal(r.data.found, true);
  assert.equal(r.data.receipt.category_snapshot, 'gold', 'tariff type exposed');
  assert.equal(r.data.receipt.discount_type, 'ampere');
  assert.equal(r.data.receipt.discount_value, 6000);
  assert.equal(r.data.receipt.discount_amps, 2);
  assert.equal(r.data.accountantName, 'كريم', 'accountant name resolved from the localId-keyed mirror');
});

test('public receipt category falls back to the subscriber current category when no snapshot', async () => {
  const owner = await registerOwner({ generatorName: 'مولدة' });
  const ts = new Date().toISOString();
  const SUB = 'sub-pub-nocat', RC = 'receipt-uuid-nocat';
  await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [
        { entity: 'subscribers', localId: SUB, deleted: false, updatedAt: ts, data: { id: SUB, name: 'x', amps: 5, status: 'active', category: 'commercial' } },
        { entity: 'receipts', localId: RC, deleted: false, updatedAt: ts, data: {
            id: RC, uuid: RC, receipt_no: 8, subscriber_id: SUB, month: '2026-06',
            amps_snapshot: 5, price_snapshot: 1000, paid_amount: 5000, remaining_after: 0, issued_at: ts, status: 'valid' } },
      ],
    },
  });
  const r = await api('GET', `/api/public/receipt/${RC}`);
  assert.equal(r.status, 200);
  assert.equal(r.data.receipt.category_snapshot, 'commercial', 'no snapshot -> falls back to the subscriber category');
  assert.equal(r.data.accountantName, null, 'owner-collected receipt has no accountant');
});

test('GET /api/public/receipt/:uuid for an unknown uuid -> 200 found:false', async () => {
  const r = await api('GET', '/api/public/receipt/no-such-uuid-00000000');
  assert.equal(r.status, 200, `unknown uuid should still 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.found, false);
  assert.equal(r.data.receipt, null);
});
