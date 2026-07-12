/**
 * Integration tests for Flash v11:
 *  - TASK 1: the `settlements` synced entity + owner approval flow. An accountant
 *    pushes a PENDING settlement into the owner mirror; the owner approves it via
 *    POST /api/account/settlements/:localId/decision; a subsequent pull returns it
 *    as approved (data.status==='approved', decided_at set). A non-owner cannot
 *    decide (403); an unknown localId -> 404; a bad status -> 400.
 *  - TASK 5: payment_method round-trips through /api/sync (no backend schema
 *    change — SyncRecord.data is Mixed) and is exposed on the public QR receipt.
 *
 * Mirrors backend/test/accountants.test.mjs: boots a REAL Express server on an
 * ephemeral port against an in-memory MongoDB (USE_MEMORY_DB=true) and an
 * isolated temp BACKUP_DIR, so the suite is hermetic.
 *
 *   cd backend && npm test
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-settlements-test-backups-'));

process.env.USE_MEMORY_DB = 'true';
process.env.NODE_ENV = 'test';
process.env.BACKUP_DIR = TMP_BACKUP_DIR;
process.env.JWT_SECRET = 'test-secret';
process.env.ADMIN_USERNAME = 'admin';
process.env.ADMIN_PASSWORD = 'admin123';

const { buildApp } = require('../src/server');
const { connectDb, disconnectDb } = require('../src/config/db');
const { runSeed } = require('../src/bootstrap/seed');

let server;
let baseUrl;

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

// Create an accountant (Flash v11: by phone) + log them in. Returns { token, account, phone }.
async function makeAccountant(owner, { branchId, permissions } = {}) {
  const phone = uniqueUsername('acct');
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: {
      name: 'Acct One',
      phone,
      password: 'secret1',
      branchId: branchId || null,
      permissions: permissions || [],
      localId: `acct-local-${phone}`,
    },
  });
  assert.equal(created.status, 201, `create accountant should 201, got ${created.status} ${JSON.stringify(created.data)}`);
  const login = await api('POST', '/api/auth/login', { body: { username: phone, password: 'secret1' } });
  assert.equal(login.status, 200, `accountant login should 200, got ${login.status} ${JSON.stringify(login.data)}`);
  return { token: login.data.token, account: login.data.account, phone, created: created.data.accountant };
}

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
// TASK 1 — settlements: accountant requests, owner approves, pull sees approved.
// ---------------------------------------------------------------------------
test('accountant pushes a pending settlement; owner approves; pull returns approved', async () => {
  const owner = await registerOwner();
  const acct = await makeAccountant(owner);

  // Accountant pushes a pending settlement into the OWNER mirror.
  const reqIso = new Date(Date.now() - 60000).toISOString();
  const push = await api('POST', '/api/sync/push', {
    token: acct.token,
    body: {
      records: [
        {
          entity: 'settlements',
          localId: 'settle-1',
          deleted: false,
          updatedAt: reqIso,
          data: {
            id: 'settle-1',
            accountant_id: acct.created.localId,
            amount: 250000,
            status: 'pending',
            requested_at: reqIso,
            updated_at: reqIso,
          },
        },
      ],
    },
  });
  assert.equal(push.status, 200, `settlement push should 200, got ${push.status} ${JSON.stringify(push.data)}`);
  assert.equal(push.data.count, 1);

  // Before the decision: pull shows it as pending.
  const prePull = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z', { token: acct.token });
  const preRec = prePull.data.records.find((r) => r.localId === 'settle-1');
  assert.ok(preRec, 'accountant pull must include the settlement');
  assert.equal(preRec.data.status, 'pending');

  // Owner approves it.
  const decide = await api('POST', '/api/account/settlements/settle-1/decision', {
    token: owner.token,
    body: { status: 'approved', note: 'ok by owner' },
  });
  assert.equal(decide.status, 200, `decide should 200, got ${decide.status} ${JSON.stringify(decide.data)}`);
  assert.equal(decide.data.settlement.status, 'approved');
  assert.ok(decide.data.settlement.decided_at, 'decided_at must be set');
  assert.equal(decide.data.settlement.decided_by, owner.account.id);
  assert.equal(decide.data.settlement.note, 'ok by owner');

  // A subsequent accountant pull returns it as approved (the owner mutated the
  // mirror row in place; last-EDIT-wins bumped data.updated_at).
  const postPull = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z', { token: acct.token });
  const postRec = postPull.data.records.find((r) => r.localId === 'settle-1');
  assert.ok(postRec, 'pull must still include the settlement');
  assert.equal(postRec.data.status, 'approved', 'pull must reflect the owner approval');
  assert.ok(postRec.data.decided_at, 'decided_at present after approval');
  assert.equal(postRec.data.amount, 250000, 'untouched fields preserved');
});

test('settlements: bad status -> 400; unknown localId -> 404; non-owner -> 403', async () => {
  const owner = await registerOwner();
  const acct = await makeAccountant(owner);

  // Seed one settlement.
  const iso = new Date().toISOString();
  const push = await api('POST', '/api/sync/push', {
    token: acct.token,
    body: {
      records: [
        {
          entity: 'settlements',
          localId: 'settle-err',
          deleted: false,
          updatedAt: iso,
          data: { id: 'settle-err', accountant_id: acct.created.localId, amount: 1000, status: 'pending', requested_at: iso, updated_at: iso },
        },
      ],
    },
  });
  assert.equal(push.status, 200);

  // Bad status.
  const bad = await api('POST', '/api/account/settlements/settle-err/decision', {
    token: owner.token,
    body: { status: 'maybe' },
  });
  assert.equal(bad.status, 400);
  assert.equal(bad.data.code, 'BAD_STATUS');

  // Unknown localId.
  const missing = await api('POST', '/api/account/settlements/does-not-exist/decision', {
    token: owner.token,
    body: { status: 'approved' },
  });
  assert.equal(missing.status, 404);
  assert.equal(missing.data.code, 'SETTLEMENT_NOT_FOUND');

  // Non-owner (the accountant) cannot decide.
  const forbidden = await api('POST', '/api/account/settlements/settle-err/decision', {
    token: acct.token,
    body: { status: 'approved' },
  });
  assert.equal(forbidden.status, 403, `accountant decide should 403, got ${forbidden.status} ${JSON.stringify(forbidden.data)}`);
  assert.equal(forbidden.data.code, 'FORBIDDEN');
});

// ---------------------------------------------------------------------------
// v28 item 12 — a SALARY settlement is requested with no amount; the owner sets
// it on approval (panel parity with the Flutter owner flow). A valid positive
// `amount` in the decision body is stamped onto data.amount; it is ignored on
// reject and when non-positive/invalid.
// ---------------------------------------------------------------------------
test('salary decision: approve stamps the owner-entered amount onto the mirror row', async () => {
  const owner = await registerOwner();
  const acct = await makeAccountant(owner);

  const reqIso = new Date(Date.now() - 60000).toISOString();
  const push = await api('POST', '/api/sync/push', {
    token: acct.token,
    body: {
      records: [
        {
          entity: 'settlements',
          localId: 'sal-1',
          deleted: false,
          updatedAt: reqIso,
          data: {
            id: 'sal-1',
            accountant_id: acct.created.localId,
            amount: 0, // salary requested with NO amount
            method: 'salary',
            status: 'pending',
            requested_at: reqIso,
            updated_at: reqIso,
          },
        },
      ],
    },
  });
  assert.equal(push.status, 200);

  // Owner approves WITH an amount → data.amount is set.
  const decide = await api('POST', '/api/account/settlements/sal-1/decision', {
    token: owner.token,
    body: { status: 'approved', amount: 500000 },
  });
  assert.equal(decide.status, 200, `salary approve should 200, got ${decide.status} ${JSON.stringify(decide.data)}`);
  assert.equal(decide.data.settlement.status, 'approved');
  assert.equal(decide.data.settlement.amount, 500000, 'owner-entered salary amount is stamped');

  // Accountant pull reflects the amount.
  const pull = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z', { token: acct.token });
  const rec = pull.data.records.find((r) => r.localId === 'sal-1');
  assert.ok(rec, 'pull must include the salary settlement');
  assert.equal(rec.data.amount, 500000, 'pull reflects the owner-entered salary amount');
});

test('salary decision: a non-positive/invalid amount is ignored (stays as requested)', async () => {
  const owner = await registerOwner();
  const acct = await makeAccountant(owner);

  const reqIso = new Date(Date.now() - 60000).toISOString();
  await api('POST', '/api/sync/push', {
    token: acct.token,
    body: {
      records: [
        {
          entity: 'settlements',
          localId: 'sal-2',
          deleted: false,
          updatedAt: reqIso,
          data: { id: 'sal-2', accountant_id: acct.created.localId, amount: 0, method: 'salary', status: 'pending', requested_at: reqIso, updated_at: reqIso },
        },
      ],
    },
  });

  // Reject carries an amount → amount must NOT change (only approvals set it).
  const rej = await api('POST', '/api/account/settlements/sal-2/decision', {
    token: owner.token,
    body: { status: 'rejected', amount: 999 },
  });
  assert.equal(rej.status, 200);
  assert.equal(rej.data.settlement.status, 'rejected');
  assert.equal(rej.data.settlement.amount, 0, 'reject does not stamp an amount');
});

// ---------------------------------------------------------------------------
// TASK 5 — payment_method round-trips through sync + appears on the public receipt.
// ---------------------------------------------------------------------------
test('payment_method round-trips through sync and shows on the public receipt', async () => {
  const owner = await registerOwner();

  const recIso = `${CURRENT_MONTH}-05T00:00:00.000Z`;
  const push = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [
        {
          entity: 'subscribers',
          localId: 'pm-sub-1',
          deleted: false,
          updatedAt: recIso,
          data: { id: 'pm-sub-1', name: 'PM Sub', amps: 5, status: 'active' },
        },
        {
          entity: 'receipts',
          localId: 'pm-rec-1',
          deleted: false,
          updatedAt: recIso,
          data: {
            uuid: 'pm-rec-1',
            receipt_no: 7,
            subscriber_id: 'pm-sub-1',
            month: CURRENT_MONTH,
            amps_snapshot: 5,
            price_snapshot: 1000,
            paid_amount: 5000,
            payment_method: 'card',
            remaining_after: 0,
            issued_at: recIso,
            status: 'valid',
          },
        },
      ],
    },
  });
  assert.equal(push.status, 200, `push should 200, got ${push.status} ${JSON.stringify(push.data)}`);

  // Round-trips back through pull verbatim.
  const pull = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z', { token: owner.token });
  const rec = pull.data.records.find((r) => r.localId === 'pm-rec-1');
  assert.ok(rec, 'pull must include the receipt');
  assert.equal(rec.data.payment_method, 'card', 'payment_method must survive the mirror round-trip');

  // Exposed on the public QR receipt (whitelisted field).
  const pub = await api('GET', '/api/public/receipt/pm-rec-1');
  assert.equal(pub.status, 200);
  assert.equal(pub.data.found, true);
  assert.equal(pub.data.receipt.payment_method, 'card', 'public receipt must expose payment_method');
});

// ---------------------------------------------------------------------------
// v12 — per-method wallet: GET /api/account/wallet buckets receipts/settlements
// by payment method (cash|card) and returns a wallet object for each, with the
// top-level fields mirroring the cash wallet for backward-compat.
// ---------------------------------------------------------------------------
test('wallet splits collected/settled/balance by payment method (cash vs card)', async () => {
  const owner = await registerOwner();
  const acct = await makeAccountant(owner);

  const recIso = `${CURRENT_MONTH}-08T00:00:00.000Z`;
  // A cash receipt (5000) + a card receipt (8000) by the accountant, plus an
  // APPROVED cash settlement (3000). All pushed into the owner mirror.
  const push = await api('POST', '/api/sync/push', {
    token: acct.token,
    body: {
      records: [
        {
          entity: 'receipts',
          localId: 'w-rec-cash',
          deleted: false,
          updatedAt: recIso,
          data: {
            uuid: 'w-rec-cash',
            receipt_no: 101,
            subscriber_id: 'w-sub',
            month: CURRENT_MONTH,
            paid_amount: 5000,
            payment_method: 'cash',
            accountant_id: acct.created.localId,
            status: 'valid',
            issued_at: recIso,
            updated_at: recIso,
          },
        },
        {
          entity: 'receipts',
          localId: 'w-rec-card',
          deleted: false,
          updatedAt: recIso,
          data: {
            uuid: 'w-rec-card',
            receipt_no: 102,
            subscriber_id: 'w-sub',
            month: CURRENT_MONTH,
            paid_amount: 8000,
            payment_method: 'card',
            accountant_id: acct.created.localId,
            status: 'valid',
            issued_at: recIso,
            updated_at: recIso,
          },
        },
        {
          entity: 'settlements',
          localId: 'w-settle-cash',
          deleted: false,
          updatedAt: recIso,
          data: {
            id: 'w-settle-cash',
            accountant_id: acct.created.localId,
            amount: 3000,
            method: 'cash',
            status: 'pending',
            requested_at: recIso,
            updated_at: recIso,
          },
        },
      ],
    },
  });
  assert.equal(push.status, 200, `wallet push should 200, got ${push.status} ${JSON.stringify(push.data)}`);

  // Owner approves the cash settlement so it counts toward settled(cash).
  const decide = await api('POST', '/api/account/settlements/w-settle-cash/decision', {
    token: owner.token,
    body: { status: 'approved' },
  });
  assert.equal(decide.status, 200, `approve should 200, got ${decide.status} ${JSON.stringify(decide.data)}`);

  // Accountant reads their own wallet.
  const w = await api('GET', '/api/account/wallet', { token: acct.token });
  assert.equal(w.status, 200, `wallet should 200, got ${w.status} ${JSON.stringify(w.data)}`);

  assert.equal(w.data.cash.collected, 5000, 'cash.collected = cash receipt');
  assert.equal(w.data.card.collected, 8000, 'card.collected = card receipt');
  assert.equal(w.data.cash.settled, 3000, 'cash.settled = approved cash settlement');
  assert.equal(w.data.card.settled, 0, 'card.settled = 0 (no card settlement)');
  assert.equal(w.data.cash.balance, 2000, 'cash.balance = 5000 - 3000');
  assert.equal(w.data.card.balance, 8000, 'card.balance = 8000 - 0');

  // Top-level fields mirror the cash wallet (backward-compat).
  assert.equal(w.data.collected, 5000, 'top-level collected = cash.collected');
  assert.equal(w.data.settled, 3000, 'top-level settled = cash.settled');
  assert.equal(w.data.balance, 2000, 'top-level balance = cash.balance');
});

// ---------------------------------------------------------------------------
// TASK 4 (regression) — receiptsMonth pull scopes ONLY receipts to a month.
// ---------------------------------------------------------------------------
test('pull?receiptsMonth=YYYY-MM scopes only receipts; other entities unaffected', async () => {
  const owner = await registerOwner();

  const push = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [
        {
          entity: 'subscribers',
          localId: 'rm-sub-1',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: 'rm-sub-1', name: 'RM Sub', amps: 5, status: 'active' },
        },
        {
          entity: 'receipts',
          localId: 'rm-rec-jun',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { uuid: 'rm-rec-jun', receipt_no: 1, subscriber_id: 'rm-sub-1', month: '2026-06', paid_amount: 100, status: 'valid' },
        },
        {
          entity: 'receipts',
          localId: 'rm-rec-jul',
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { uuid: 'rm-rec-jul', receipt_no: 2, subscriber_id: 'rm-sub-1', month: '2026-07', paid_amount: 200, status: 'valid' },
        },
      ],
    },
  });
  assert.equal(push.status, 200);

  const pull = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z&receiptsMonth=2026-06', {
    token: owner.token,
  });
  assert.equal(pull.status, 200);
  const ids = pull.data.records.map((r) => r.localId);
  assert.ok(ids.includes('rm-sub-1'), 'non-receipt entities are unaffected by receiptsMonth');
  assert.ok(ids.includes('rm-rec-jun'), 'June receipt is included');
  assert.ok(!ids.includes('rm-rec-jul'), 'July receipt is excluded by receiptsMonth=2026-06');
});

// ---------------------------------------------------------------------------
// v39 item 1/4 — the data endpoint's month param now also filters SETTLEMENTS
// (requested_at UTC prefix), so the owner-panel settlements screen is strictly
// month-isolated server-side. Omitting month keeps the old all-months list.
// ---------------------------------------------------------------------------
test('v39: GET /api/account/data?entity=settlements&month= filters by requested_at prefix', async () => {
  const owner = await registerOwner();
  const acct = await makeAccountant(owner);

  const rows = [
    { localId: 'm-sep-appr', status: 'approved', requested_at: '2026-09-10T09:00:00.000Z', amount: 6000 },
    { localId: 'm-sep-pend', status: 'pending', requested_at: '2026-09-20T09:00:00.000Z', amount: 2000 },
    { localId: 'm-aug-appr', status: 'approved', requested_at: '2026-08-10T09:00:00.000Z', amount: 4000 },
    { localId: 'm-aug-pend', status: 'pending', requested_at: '2026-08-20T09:00:00.000Z', amount: 1000 },
  ];
  const push = await api('POST', '/api/sync/push', {
    token: acct.token,
    body: {
      records: rows.map((r) => ({
        entity: 'settlements',
        localId: r.localId,
        deleted: false,
        updatedAt: r.requested_at,
        data: {
          id: r.localId,
          accountant_id: acct.created.localId,
          amount: r.amount,
          method: 'cash',
          status: r.status,
          requested_at: r.requested_at,
          updated_at: r.requested_at,
        },
      })),
    },
  });
  assert.equal(push.status, 200, `push should 200, got ${push.status} ${JSON.stringify(push.data)}`);

  // month=2026-09 -> ONLY September rows, pending included (strict isolation:
  // August's pending must NOT leak into September's view).
  const sep = await api('GET', '/api/account/data?entity=settlements&month=2026-09&limit=200', { token: owner.token });
  assert.equal(sep.status, 200);
  const sepIds = sep.data.records.map((r) => r.localId).sort();
  assert.deepEqual(sepIds, ['m-sep-appr', 'm-sep-pend'], 'September view = September rows only');
  assert.equal(sep.data.total, 2, 'total respects the month filter');

  const aug = await api('GET', '/api/account/data?entity=settlements&month=2026-08&limit=200', { token: owner.token });
  const augIds = aug.data.records.map((r) => r.localId).sort();
  assert.deepEqual(augIds, ['m-aug-appr', 'm-aug-pend']);

  // Backward compatible: no month param -> all rows, exactly as before.
  const all = await api('GET', '/api/account/data?entity=settlements&limit=200', { token: owner.token });
  assert.equal(all.data.total, 4, 'omitting month keeps the all-months list');

  // The month param composes with the accountant relation filter (panel usage).
  const scoped = await api(
    'GET',
    `/api/account/data?entity=settlements&month=2026-09&relField=accountant_id&relValue=${encodeURIComponent(acct.created.localId)}&limit=200`,
    { token: owner.token }
  );
  assert.equal(scoped.data.total, 2, 'month + accountant filters compose');
});
