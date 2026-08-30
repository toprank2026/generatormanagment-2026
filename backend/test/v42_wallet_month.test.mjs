/**
 * Flash v42 item 1 (server side) — the accountant wallet is isolated per
 * ACCOUNTING month: GET /api/account/wallet?month=YYYY-MM.
 *
 * What is asserted here:
 *  - collected buckets by `receipts.month`, settled by the v40 tariff-month rule
 *    `COALESCE(settlements.month, substr(requested_at,1,7))`, for BOTH the cash
 *    and the card wallet;
 *  - month A and month B are strictly isolated (no figure leaks across months);
 *  - a settlement stamped with data.month wins over its requested_at (v40
 *    future-month billing), while a LEGACY settlement that carries only
 *    requested_at still buckets by that prefix — exactly its old behaviour;
 *  - only APPROVED settlements subtract, in the month-scoped path too;
 *  - ABSENT ?month ⇒ the all-time response every not-yet-updated device still
 *    expects (asserted to equal the sum across the months);
 *  - a MALFORMED month is ignored (200 + all-time), never a 400 — an old/odd
 *    client must not lose its wallet over a bad query string.
 *
 * Harness mirrors backend/test/settlements.test.mjs: a REAL Express server on an
 * ephemeral port against an in-memory MongoDB (USE_MEMORY_DB=true) and an
 * isolated temp BACKUP_DIR, so the suite stays hermetic.
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

const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-v42-wallet-test-backups-'));

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

// Two fixed accounting months, far from any wall-clock month so nothing another
// test seeds can collide with them (each test also uses its own fresh owner
// mirror, so the figures below are the ONLY rows in scope).
const MONTH_A = '2031-01';
const MONTH_B = '2031-02';
const EMPTY_MONTH = '2031-07';

let deviceCounter = 0;
function makeDevice(overrides = {}) {
  deviceCounter += 1;
  return {
    installId: `v42w-install-${deviceCounter}`,
    deviceId: `v42w-device-${deviceCounter}`,
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
  return `v42w${prefix}${Date.now()}_${userCounter}`;
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

// Create an accountant (by phone) + log them in. Returns { token, created, ... }.
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
      localId: `v42w-acct-local-${phone}`,
    },
  });
  assert.equal(created.status, 201, `create accountant should 201, got ${created.status} ${JSON.stringify(created.data)}`);
  const login = await api('POST', '/api/auth/login', { body: { username: phone, password: 'secret1' } });
  assert.equal(login.status, 200, `accountant login should 200, got ${login.status} ${JSON.stringify(login.data)}`);
  return { token: login.data.token, account: login.data.account, phone, created: created.data.accountant };
}

/** A mirrored `receipts` row for the given accounting month + payment method. */
function receipt({ localId, no, month, amount, method, acctId, issuedAt }) {
  return {
    entity: 'receipts',
    localId,
    deleted: false,
    updatedAt: issuedAt,
    data: {
      uuid: localId,
      receipt_no: no,
      subscriber_id: 'v42w-sub',
      month,
      paid_amount: amount,
      payment_method: method,
      accountant_id: acctId,
      status: 'valid',
      issued_at: issuedAt,
      updated_at: issuedAt,
    },
  };
}

/**
 * A mirrored `settlements` row. `month` is the v40 TARIFF stamp: pass it to get a
 * v42 row, OMIT it entirely to get a LEGACY row (pre-v40 devices never wrote the
 * key) that must still bucket by its requested_at prefix.
 */
function settlement({ localId, month, requestedAt, amount, method, acctId, status = 'pending' }) {
  const data = {
    id: localId,
    accountant_id: acctId,
    amount,
    method,
    status,
    requested_at: requestedAt,
    updated_at: requestedAt,
  };
  if (month !== undefined) data.month = month;
  return { entity: 'settlements', localId, deleted: false, updatedAt: requestedAt, data };
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

/**
 * Seeds one owner + accountant with a two-month wallet history and returns both,
 * so every assertion below reads the same fixture:
 *
 *          | collected cash | collected card | settled cash | settled card
 *  MONTH_A |           5000 |           8000 |         3000 |         1000
 *  MONTH_B |           2000 |            300 |          500 |            0
 *  all-time|           7000 |           8300 |         3500 |         1000
 *
 * The MONTH_A cash settlement is REQUESTED in month B but STAMPED month A (v40
 * future-month billing); the MONTH_B cash settlement is LEGACY (no data.month)
 * and may only be found through its requested_at prefix. A pending month-A
 * settlement of 7777 is seeded to prove the approved-only rule still holds under
 * the month scope.
 */
async function seedTwoMonthWallet() {
  const owner = await registerOwner();
  const acct = await makeAccountant(owner);
  const acctId = acct.created.localId;

  const inA = `${MONTH_A}-08T00:00:00.000Z`;
  const inB = `${MONTH_B}-05T00:00:00.000Z`;

  const push = await api('POST', '/api/sync/push', {
    token: acct.token,
    body: {
      records: [
        receipt({ localId: 'v42w-rec-a-cash', no: 201, month: MONTH_A, amount: 5000, method: 'cash', acctId, issuedAt: inA }),
        receipt({ localId: 'v42w-rec-a-card', no: 202, month: MONTH_A, amount: 8000, method: 'card', acctId, issuedAt: inA }),
        receipt({ localId: 'v42w-rec-b-cash', no: 203, month: MONTH_B, amount: 2000, method: 'cash', acctId, issuedAt: inB }),
        receipt({ localId: 'v42w-rec-b-card', no: 204, month: MONTH_B, amount: 300, method: 'card', acctId, issuedAt: inB }),
        // Stamped month A, but requested DURING month B — the stamp must win.
        settlement({ localId: 'v42w-set-a-cash', month: MONTH_A, requestedAt: inB, amount: 3000, method: 'cash', acctId }),
        settlement({ localId: 'v42w-set-a-card', month: MONTH_A, requestedAt: inA, amount: 1000, method: 'card', acctId }),
        // LEGACY row: no data.month at all -> buckets by requested_at's prefix (B).
        settlement({ localId: 'v42w-set-b-legacy', requestedAt: inB, amount: 500, method: 'cash', acctId }),
        // Left PENDING on purpose: must never subtract, in any month or all-time.
        settlement({ localId: 'v42w-set-a-pending', month: MONTH_A, requestedAt: inA, amount: 7777, method: 'cash', acctId }),
      ],
    },
  });
  assert.equal(push.status, 200, `wallet push should 200, got ${push.status} ${JSON.stringify(push.data)}`);

  // Only the three non-pending requests get the owner's approval.
  for (const localId of ['v42w-set-a-cash', 'v42w-set-a-card', 'v42w-set-b-legacy']) {
    const decide = await api('POST', `/api/account/settlements/${localId}/decision`, {
      token: owner.token,
      body: { status: 'approved' },
    });
    assert.equal(decide.status, 200, `approve ${localId} should 200, got ${decide.status} ${JSON.stringify(decide.data)}`);
  }

  return { owner, acct };
}

// ---------------------------------------------------------------------------
// v42 item 1 — ?month=A returns ONLY month A, for both wallets.
// ---------------------------------------------------------------------------
test('wallet?month=A returns only month A collected/settled/balance (cash + card)', async () => {
  const { acct } = await seedTwoMonthWallet();

  const w = await api('GET', `/api/account/wallet?month=${MONTH_A}`, { token: acct.token });
  assert.equal(w.status, 200, `wallet should 200, got ${w.status} ${JSON.stringify(w.data)}`);

  // Collected = month A receipts only (month B's 2000/300 must not leak in).
  assert.equal(w.data.cash.collected, 5000, 'cash.collected = month A cash receipt');
  assert.equal(w.data.card.collected, 8000, 'card.collected = month A card receipt');
  // Settled = the two APPROVED settlements stamped month A; the 7777 pending one
  // and month B's legacy 500 are both excluded.
  assert.equal(w.data.cash.settled, 3000, 'cash.settled = approved month A cash settlement');
  assert.equal(w.data.card.settled, 1000, 'card.settled = approved month A card settlement');
  assert.equal(w.data.cash.balance, 2000, 'cash.balance = 5000 - 3000');
  assert.equal(w.data.card.balance, 7000, 'card.balance = 8000 - 1000');

  // Top-level fields still mirror the cash wallet under the month scope.
  assert.equal(w.data.collected, 5000, 'top-level collected = cash.collected');
  assert.equal(w.data.settled, 3000, 'top-level settled = cash.settled');
  assert.equal(w.data.balance, 2000, 'top-level balance = cash.balance');
});

// ---------------------------------------------------------------------------
// v42 item 1 — ?month=B returns B's own figures: the months are isolated, and
// the LEGACY settlement (no data.month) buckets by its requested_at prefix.
// ---------------------------------------------------------------------------
test('wallet?month=B is isolated from A; a legacy settlement buckets by requested_at', async () => {
  const { acct } = await seedTwoMonthWallet();

  const w = await api('GET', `/api/account/wallet?month=${MONTH_B}`, { token: acct.token });
  assert.equal(w.status, 200, `wallet should 200, got ${w.status} ${JSON.stringify(w.data)}`);

  assert.equal(w.data.cash.collected, 2000, 'cash.collected = month B cash receipt only');
  assert.equal(w.data.card.collected, 300, 'card.collected = month B card receipt only');
  // The 500 row carries NO data.month — it may only be found via substr(
  // requested_at,1,7) === MONTH_B, which is the pre-v40 behaviour preserved.
  assert.equal(w.data.cash.settled, 500, 'cash.settled = LEGACY settlement, bucketed by requested_at');
  // The month-A CARD settlement must not leak into B...
  assert.equal(w.data.card.settled, 0, 'card.settled = 0 (month A card settlement excluded)');
  assert.equal(w.data.cash.balance, 1500, 'cash.balance = 2000 - 500');
  assert.equal(w.data.card.balance, 300, 'card.balance = 300 - 0');

  // ...and the month-A CASH settlement was REQUESTED inside month B, so this is
  // also the proof that data.month (the tariff stamp) wins over requested_at:
  // were the stamp ignored, cash.settled here would be 3500, not 500.
  assert.notEqual(w.data.cash.settled, 3500, 'a stamped settlement must not fall back to requested_at');

  // A month with no records at all is all zeros — isolation, not aggregation.
  const empty = await api('GET', `/api/account/wallet?month=${EMPTY_MONTH}`, { token: acct.token });
  assert.equal(empty.status, 200, `empty-month wallet should 200, got ${empty.status}`);
  assert.deepEqual(empty.data.cash, { collected: 0, settled: 0, balance: 0 }, 'empty month cash wallet is zeroed');
  assert.deepEqual(empty.data.card, { collected: 0, settled: 0, balance: 0 }, 'empty month card wallet is zeroed');
});

// ---------------------------------------------------------------------------
// Back-compat — NO ?month keeps the all-time response every not-yet-updated
// device expects: exactly the sum of the per-month responses.
// ---------------------------------------------------------------------------
test('wallet with no month param is unchanged (all-time = sum of the months)', async () => {
  const { acct } = await seedTwoMonthWallet();

  const a = await api('GET', `/api/account/wallet?month=${MONTH_A}`, { token: acct.token });
  const b = await api('GET', `/api/account/wallet?month=${MONTH_B}`, { token: acct.token });
  const all = await api('GET', '/api/account/wallet', { token: acct.token });
  assert.equal(all.status, 200, `wallet should 200, got ${all.status} ${JSON.stringify(all.data)}`);

  for (const m of ['cash', 'card']) {
    assert.equal(
      all.data[m].collected,
      a.data[m].collected + b.data[m].collected,
      `all-time ${m}.collected = month A + month B`
    );
    assert.equal(
      all.data[m].settled,
      a.data[m].settled + b.data[m].settled,
      `all-time ${m}.settled = month A + month B`
    );
    assert.equal(all.data[m].balance, all.data[m].collected - all.data[m].settled, `${m}.balance = collected - settled`);
  }

  // Pinned literals too, so a regression in BOTH the month and the all-time path
  // could not cancel out and still pass the sum check above.
  assert.equal(all.data.cash.collected, 7000, 'all-time cash.collected = 5000 + 2000');
  assert.equal(all.data.card.collected, 8300, 'all-time card.collected = 8000 + 300');
  assert.equal(all.data.cash.settled, 3500, 'all-time cash.settled = 3000 + 500 (pending 7777 excluded)');
  assert.equal(all.data.card.settled, 1000, 'all-time card.settled = 1000');
  assert.equal(all.data.cash.balance, 3500, 'all-time cash.balance = 7000 - 3500');
  assert.equal(all.data.card.balance, 7300, 'all-time card.balance = 8300 - 1000');

  // The pre-v12 top-level fields are still the cash wallet, byte-for-byte.
  assert.equal(all.data.collected, 7000, 'top-level collected = cash.collected');
  assert.equal(all.data.settled, 3500, 'top-level settled = cash.settled');
  assert.equal(all.data.balance, 3500, 'top-level balance = cash.balance');
});

// ---------------------------------------------------------------------------
// A malformed month must degrade to all-time, never 400 — losing a wallet over a
// bad query string is worse than ignoring the filter.
// ---------------------------------------------------------------------------
test('a malformed month param does not error and falls back to all-time', async () => {
  const { acct } = await seedTwoMonthWallet();

  const all = await api('GET', '/api/account/wallet', { token: acct.token });
  assert.equal(all.status, 200);

  // Wrong shape, wrong type, empty, and an injection-shaped value.
  const bad = ['2031-1', 'not-a-month', '', '2031-02-05', '%7B%22%24ne%22%3Anull%7D'];
  for (const value of bad) {
    const w = await api('GET', `/api/account/wallet?month=${value}`, { token: acct.token });
    assert.equal(w.status, 200, `month='${value}' should 200, got ${w.status} ${JSON.stringify(w.data)}`);
    assert.deepEqual(w.data.cash, all.data.cash, `month='${value}' falls back to the all-time cash wallet`);
    assert.deepEqual(w.data.card, all.data.card, `month='${value}' falls back to the all-time card wallet`);
    assert.equal(w.data.collected, all.data.collected, `month='${value}' keeps the top-level collected`);
    assert.equal(w.data.settled, all.data.settled, `month='${value}' keeps the top-level settled`);
    assert.equal(w.data.balance, all.data.balance, `month='${value}' keeps the top-level balance`);
  }

  // A repeated param arrives as an ARRAY (not a string) — it must be ignored the
  // same way rather than throwing inside the query builder.
  const dup = await api('GET', `/api/account/wallet?month=${MONTH_A}&month=${MONTH_B}`, { token: acct.token });
  assert.equal(dup.status, 200, `duplicated month should 200, got ${dup.status} ${JSON.stringify(dup.data)}`);
  assert.deepEqual(dup.data.cash, all.data.cash, 'duplicated month falls back to the all-time cash wallet');
});
