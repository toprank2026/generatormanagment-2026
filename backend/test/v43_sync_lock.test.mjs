/**
 * Flash v43 — POST /api/sync/push and the DELIBERATE ABSENCE of a business
 * lock on that path.
 *
 * v43 first re-evaluated the invoice/settlement lock here, against the owner
 * mirror, so a hand-crafted push could not slip a locked-month change past the
 * app. Adversarial review showed that gate is NET-DESTRUCTIVE and it was
 * removed. These tests exist to keep it removed, because the failure it caused
 * is silent and only surfaces months later:
 *
 *   🚨 THE MIRROR IS PUSH-ONLY AND THE DEVICE IS THE SOURCE OF TRUTH. 🚨
 *   `pull()` is a FULL RESTORE (INSERT OR REPLACE) run on a new device, after
 *   delete-local-data, and on EVERY branch switch. So a row the server refuses
 *   is a permanent divergence, and that divergence becomes DATA LOSS at the
 *   next restore: the device's real value is overwritten by the stale mirror.
 *   The server also cannot reproduce the app's rules — a `subscribers` row
 *   carries no month, so a server lock could only ask "was this subscriber
 *   EVER invoiced", which refused ordinary edits aimed at an OPEN month.
 *   And this is a LIVE, MIXED-VERSION fleet: a v42 device has no client-side
 *   v43 guard at all, so a new server refusal breaks a workflow that works
 *   today. Accepting is never worse than yesterday; refusing is.
 *
 * v43 therefore enforces its rules where enforcement cannot diverge: in the app
 * (repository + controller choke points) and on the direct admin REST surface.
 *
 * What is asserted here:
 *  - a subscriber edit in an invoiced month IS mirrored — the anti-regression
 *    guard for the divergence described above (read back through the admin
 *    synced-data endpoint, the record the owner and the panel actually read);
 *  - a receipt reversal in a settled month IS mirrored, for the same reason;
 *  - a re-price of an invoiced month IS mirrored;
 *  - THE WEDGE: a batch whose first and last rows are money rows still applies
 *    every row, 200s, and counts them all so the outbox drains;
 *  - the ONE refusal kept on this path is forgery no app version produces (an
 *    accountant pushing an already-decided settlement), and it is
 *    skip-and-counted and reported in `rejected[]` — never thrown;
 *  - `corrections` / `financial_adjustments` are accepted by push, an
 *    ACCOUNTANT may file a correction but can never mint an adjustment, and a
 *    correction's `accountant_id` (a WALLET TARGET, not the writer's identity)
 *    survives the push unstamped;
 *  - an unknown entity still 400s — unchanged behaviour.
 *
 * Boots a REAL Express server on an ephemeral port against in-memory MongoDB,
 * mirroring backend/test/push_authz.test.mjs and v42_password_reset.test.mjs.
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

// Environment first: src/config/env.js snapshots process.env at require time.
const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-v43-synclock-test-'));
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

// ---------------------------------------------------------------------------
// Harness.
// ---------------------------------------------------------------------------

let deviceCounter = 0;
function makeDevice(overrides = {}) {
  deviceCounter += 1;
  return {
    installId: `install-${deviceCounter}`,
    deviceId: `device-${deviceCounter}`,
    platform: 'android',
    model: 'SM-TEST',
    osVersion: 'Android 13 (SDK 33)',
    ...overrides,
  };
}

let userCounter = 0;
function uniqueUsername(prefix = 'lockowner') {
  userCounter += 1;
  return `${prefix}${Date.now()}_${userCounter}`;
}

async function api(method, urlPath, { token, body } = {}) {
  const h = {};
  if (token) h.Authorization = `Bearer ${token}`;
  let payload = body;
  if (body !== undefined) {
    h['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  const res = await fetch(`${baseUrl}${urlPath}`, { method, headers: h, body: payload });
  const ct = res.headers.get('content-type') || '';
  const data = ct.includes('application/json') ? await res.json() : null;
  return { status: res.status, data };
}

async function registerOwner() {
  const username = uniqueUsername();
  const password = 'secret1';
  const r = await api('POST', '/api/auth/register', {
    body: { name: 'Lock Owner', generatorName: 'Lock Gen', phone: username, username, password, device: makeDevice() },
  });
  assert.equal(r.status, 201, `register -> ${r.status} ${JSON.stringify(r.data)}`);
  return { token: r.data.token, id: r.data.account.id, username, password };
}

// Admin login (seeded super admin). Cached after the first call.
let adminToken = null;
async function getAdminToken() {
  if (adminToken) return adminToken;
  const r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'admin123' } });
  assert.equal(r.status, 200, `admin login -> ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.account.role, 'admin');
  adminToken = r.data.token;
  return adminToken;
}

/** An accountant under `owner`, already logged in. */
async function makeAccountant(owner, { branchId = null, permissions = [], localId = null } = {}) {
  const uname = uniqueUsername('lockacct');
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: { name: 'Acct', username: uname, password: 'secret1', branchId, permissions, localId },
  });
  assert.equal(created.status, 201, `create acct -> ${created.status} ${JSON.stringify(created.data)}`);
  const login = await api('POST', '/api/auth/login', { body: { username: uname, password: 'secret1' } });
  assert.equal(login.status, 200, `acct login -> ${login.status} ${JSON.stringify(login.data)}`);
  return { token: login.data.token, branchId, localId };
}

const pushAs = (token, records) => api('POST', '/api/sync/push', { token, body: { records } });

/**
 * The mirror as the OWNER AND THE PANEL SEE IT — deliberately read back through
 * the admin synced-data endpoint rather than the Mongo model, because that
 * endpoint is the record v43 is protecting.
 */
async function mirrorRow(ownerId, entity, localId) {
  const url =
    `/api/admin/users/${ownerId}/data?entity=${encodeURIComponent(entity)}` +
    `&localId=${encodeURIComponent(localId)}&page=1&limit=5`;
  const r = await api('GET', url, { token: await getAdminToken() });
  assert.equal(r.status, 200, `admin data -> ${r.status} ${JSON.stringify(r.data)}`);
  return r.data.records.find((x) => x.localId === localId) || null;
}

// ---------------------------------------------------------------------------
// Record builders. A monotonic clock keeps every push strictly newer than the
// stored row, so nothing is skipped by the last-EDIT-wins guard — a stale-edit
// skip would look like a lock rejection while proving nothing.
// ---------------------------------------------------------------------------

let clockMs = Date.UTC(2026, 0, 1, 0, 0, 0);
function ts() {
  clockMs += 60000;
  return new Date(clockMs).toISOString();
}

function rec(entity, localId, data) {
  const stamp = ts();
  return { entity, localId, deleted: false, updatedAt: stamp, data: { updated_at: stamp, ...data } };
}

const subscriber = (localId, { amps, category = 'standard', name = 'Sub', branchId = null }) =>
  rec('subscribers', localId, {
    id: localId,
    name,
    phone: '07700000000',
    amps,
    category,
    status: 'active',
    branch_id: branchId,
    created_at: '2026-01-01 00:00:00',
  });

/** A legacy-shaped receipt (no branch_id / category_snapshot) — the broadest
 *  invoice lock, and the shape most rows in a real mirror still have. */
const receipt = (localId, { subscriberId, month, paid, no, status = 'valid' }) =>
  rec('receipts', localId, {
    uuid: localId,
    receipt_no: no,
    subscriber_id: subscriberId,
    month,
    paid_amount: paid,
    status,
    amps_snapshot: 10,
    price_snapshot: 10,
    branch_id: null,
    category_snapshot: null,
  });

/** `monthly_prices` PK is the synthetic "<month>|<branchId>|<category>". */
const price = (month, { amount, branchId = 'main', category = 'standard' }) =>
  rec('monthly_prices', `${month}|${branchId}|${category}`, {
    id: `${month}|${branchId}|${category}`,
    month,
    branch_id: branchId,
    category,
    price_per_amp: amount,
  });

const settlement = (localId, { month, amount, status = 'pending', requestedAt = '2026-03-20 10:00:00' }) =>
  rec('settlements', localId, {
    id: localId,
    accountant_id: 'acct-1',
    amount,
    method: 'cash',
    status,
    month,
    requested_at: requestedAt,
  });

const correction = (localId, over = {}) =>
  rec('corrections', localId, {
    id: localId,
    subscriber_id: 'sub-x',
    month: '2026-05',
    branch_id: null,
    accountant_id: null,
    receipt_uuid: null,
    settlement_id: null,
    reason: 'amps read wrong at installation',
    old_amps: 10,
    new_amps: 12,
    old_due: 100,
    new_due: 120,
    difference: 20,
    status: 'pending',
    requested_by: 'acct-1',
    requested_at: '2026-06-01 09:00:00',
    decided_by: null,
    decided_at: null,
    decision_note: null,
    refund_paid_at: null,
    refund_paid_by: null,
    created_at: '2026-06-01 09:00:00',
    ...over,
  });

const adjustment = (localId, over = {}) =>
  rec('financial_adjustments', localId, {
    id: localId,
    correction_id: 'corr-x',
    subscriber_id: 'sub-x',
    month: '2026-05',
    branch_id: null,
    accountant_id: 'acct-1',
    kind: 'correction_increase',
    amount: 20,
    method: 'cash',
    created_at: '2026-06-02 09:00:00',
    created_by: 'owner-1',
    ...over,
  });

/** Every localId in `records` must be readable back from the mirror. */
async function assertMirrored(ownerId, records) {
  for (const r of records) {
    // eslint-disable-next-line no-await-in-loop
    const row = await mirrorRow(ownerId, r.entity, r.localId);
    assert.ok(row, `${r.entity}/${r.localId} must be in the mirror`);
  }
}

test.before(async () => {
  await connectDb();
  await runSeed();
  const app = buildApp();
  await new Promise((resolve) => { server = app.listen(0, '127.0.0.1', resolve); });
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  if (server) await new Promise((resolve) => server.close(resolve));
  await disconnectDb();
  try { fs.rmSync(TMP_BACKUP_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
});

// ------------------------------------------------------- the invoice lock ---

test('a subscriber edit in an INVOICED month IS mirrored (no silent divergence)', async () => {
  const owner = await registerOwner();

  const seeded = [
    subscriber('s1', { amps: 10, name: 'Original Name' }),
    receipt('r1', { subscriberId: 's1', month: '2026-05', paid: 100, no: 1 }),
  ];
  const seed = await pushAs(owner.token, seeded);
  assert.equal(seed.status, 200, `seed -> ${seed.status} ${JSON.stringify(seed.data)}`);
  assert.equal(seed.data.count, 2);
  assert.deepEqual(seed.data.rejected, [], 'nothing is rejected on the push path');

  const before = await mirrorRow(owner.id, 'subscribers', 's1');
  assert.ok(before, 'the subscriber is mirrored');
  assert.equal(before.data.amps, 10);

  // An amps edit on an already-invoiced subscriber. The APP decides whether
  // this is allowed (month-scoped, correction-mediated); the SERVER must not
  // second-guess it, because it cannot see which month the edit was aimed at.
  const attempt = await pushAs(owner.token, [subscriber('s1', { amps: 25, name: 'Original Name' })]);
  assert.equal(attempt.status, 200, `push -> ${attempt.status} ${JSON.stringify(attempt.data)}`);
  assert.equal(attempt.data.ok, true);
  assert.equal(attempt.data.count, 1);
  assert.deepEqual(
    attempt.data.rejected,
    [],
    'the push path applies no business lock — refusing here would diverge the mirror'
  );

  // THE assertion: the mirror tracks the device. If this ever regresses to a
  // refusal, the device's real amps is silently reverted at the next FULL pull
  // (new device / delete-local-data / branch switch).
  const after = await mirrorRow(owner.id, 'subscribers', 's1');
  assert.ok(after);
  assert.equal(after.data.amps, 25, 'the mirror follows the device — the edit is NOT dropped');
});

test('a receipt REVERSAL in a settled month IS mirrored (the app owns that rule)', async () => {
  const owner = await registerOwner();
  await pushAs(owner.token, [
    subscriber('s1', { amps: 10 }),
    receipt('r1', { subscriberId: 's1', month: '2026-05', paid: 100, no: 1 }),
    settlement('set1', { month: '2026-05', amount: 100, status: 'approved' }),
  ]);

  // The app's reversal rule is per-accountant, per-method and issue-time based;
  // the server could only ask "does this month carry an active settlement",
  // which is strictly stricter and would refuse a reversal the app permits.
  const reversal = await pushAs(owner.token, [
    receipt('r1', { subscriberId: 's1', month: '2026-05', paid: 0, no: 1, status: 'refunded' }),
  ]);
  assert.equal(reversal.status, 200);
  assert.deepEqual(reversal.data.rejected, [], 'a permitted reversal is never refused by the mirror');

  const row = await mirrorRow(owner.id, 'receipts', 'r1');
  assert.equal(row.data.status, 'refunded', 'the reversal reached the mirror');
  assert.equal(
    Number(row.data.paid_amount),
    0,
    'the reversed cash is not resurrected as collected by a stale mirror row'
  );
});

test('a RE-PRICE of an invoiced month IS mirrored (enforced in the app, not here)', async () => {
  const owner = await registerOwner();
  await pushAs(owner.token, [
    subscriber('s1', { amps: 10 }),
    price('2026-05', { amount: 1000 }),
    receipt('r1', { subscriberId: 's1', month: '2026-05', paid: 100, no: 1 }),
  ]);

  const reprice = await pushAs(owner.token, [price('2026-05', { amount: 1500 })]);
  assert.equal(reprice.status, 200);
  assert.deepEqual(reprice.data.rejected, [], 'the tariff lock lives in MonthlyPriceRepository.insertGuarded');

  const rows = await mirrorRow(owner.id, 'monthly_prices', '2026-05|main|standard');
  assert.ok(rows, 'the tariff row is mirrored under its synthetic PK');
  assert.equal(Number(rows.data.price_per_amp), 1500, 'the mirror follows the device');
});

test('the lock is FIELD-scoped: a name/phone edit on an invoiced subscriber still applies', async () => {
  const owner = await registerOwner();
  await pushAs(owner.token, [
    subscriber('s1', { amps: 10, name: 'Old Name' }),
    receipt('r1', { subscriberId: 's1', month: '2026-05', paid: 100, no: 1 }),
  ]);

  const rename = await pushAs(owner.token, [subscriber('s1', { amps: 10, name: 'New Name' })]);
  assert.equal(rename.status, 200);
  assert.deepEqual(rename.data.rejected, [], 'a non-billing edit is not a lock violation');

  const row = await mirrorRow(owner.id, 'subscribers', 's1');
  assert.equal(row.data.name, 'New Name', 'name/phone stay freely editable, as today');
  assert.equal(row.data.amps, 10, 'and the money basis is untouched');
});

// --------------------------------------------------------------- THE WEDGE ---

test('THE WEDGE: a batch of money rows still applies every row and never fails', async () => {
  const owner = await registerOwner();

  const seed = await pushAs(owner.token, [
    subscriber('s1', { amps: 10 }),
    receipt('r1', { subscriberId: 's1', month: '2026-05', paid: 100, no: 1 }),
  ]);
  assert.equal(seed.status, 200);

  // The legal work an ordinary device pushes alongside the offending row: a new
  // board, a circuit, an expense, a brand-new subscriber, that subscriber's
  // receipt in a DIFFERENT month, and a tariff for a not-yet-invoiced month.
  const legal = [
    rec('boards', 'b1', { id: 'b1', name: 'Board 1', status: 'active' }),
    rec('circuits', 'c1', { id: 'c1', board_id: 'b1', name: 'Circuit 1' }),
    rec('expenses', 'e1', { id: 'e1', amount: 5000, date: '2026-06-03', note: 'diesel' }),
    subscriber('s2', { amps: 7, name: 'Brand New' }),
    receipt('r2', { subscriberId: 's2', month: '2026-06', paid: 70, no: 2 }),
    price('2026-07', { amount: 12 }),
  ];
  // …bracketed by two lock violations, so neither position can be the one the
  // guard happens to survive: an invoiced subscriber's amps, and a re-price of
  // an already-invoiced month.
  const batch = [
    subscriber('s1', { amps: 99 }),
    ...legal,
    price('2026-05', { amount: 999 }),
  ];

  const r = await pushAs(owner.token, batch);
  assert.equal(r.status, 200, `the batch must NOT fail, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.ok, true);
  assert.equal(r.data.count, batch.length, 'EVERY record counted — the outbox drains completely');
  assert.deepEqual(r.data.rejected, [], 'the push path refuses no ordinary money row');

  // The point of the test: everything legal landed.
  await assertMirrored(owner.id, legal);

  // …and so did both money rows — the mirror tracks the device.
  const s1 = await mirrorRow(owner.id, 'subscribers', 's1');
  assert.equal(s1.data.amps, 99, 'the amps edit reached the mirror');
  const invoicedPrice = await mirrorRow(owner.id, 'monthly_prices', '2026-05|main|standard');
  assert.ok(invoicedPrice, 'the re-price reached the mirror');
  assert.equal(Number(invoicedPrice.data.price_per_amp), 999);

  // A second push of the same batch behaves identically — the device that keeps
  // retrying is never wedged.
  const again = await pushAs(owner.token, batch);
  assert.equal(again.status, 200);
  assert.equal(again.data.count, batch.length);
  assert.deepEqual(again.data.rejected, []);
});

// ------------------------------------------------ brand-new is never locked ---

test('a brand-new subscriber is always mirrored, even when a receipt already references it', async () => {
  const owner = await registerOwner();

  // A device can push the receipt before the subscriber row (out-of-order
  // outbox drain / a receipt restored ahead of its subscriber). The subscriber's
  // FIRST arrival must still be mirrored: there is no previous billing basis to
  // protect, and refusing it would leave the mirror without the subscriber at all.
  const early = await pushAs(owner.token, [receipt('r1', { subscriberId: 's-new', month: '2026-05', paid: 100, no: 1 })]);
  assert.equal(early.status, 200);
  assert.deepEqual(early.data.rejected, []);

  const first = await pushAs(owner.token, [subscriber('s-new', { amps: 12 })]);
  assert.equal(first.status, 200);
  assert.deepEqual(first.data.rejected, [], 'a first-time subscriber row is never a lock violation');
  const created = await mirrorRow(owner.id, 'subscribers', 's-new');
  assert.ok(created, 'the brand-new subscriber is mirrored');
  assert.equal(created.data.amps, 12);

  // A plain new subscriber with no receipts anywhere is likewise free.
  const plain = await pushAs(owner.token, [subscriber('s-fresh', { amps: 3 })]);
  assert.equal(plain.status, 200);
  assert.deepEqual(plain.data.rejected, []);
  assert.ok(await mirrorRow(owner.id, 'subscribers', 's-fresh'));

  // A later edit is likewise mirrored — the push path never second-guesses the
  // device, so the mirror cannot drift away from it.
  const edit = await pushAs(owner.token, [subscriber('s-new', { amps: 20 })]);
  assert.equal(edit.status, 200);
  assert.equal(edit.data.count, 1);
  assert.deepEqual(edit.data.rejected, []);
  assert.equal((await mirrorRow(owner.id, 'subscribers', 's-new')).data.amps, 20, 'the mirror follows the device');
});

// --------------------------------------------------- month isolation (§1) ---

test('a settled month does not drop its receipts from the mirror', async () => {
  const owner = await registerOwner();

  const seed = await pushAs(owner.token, [
    subscriber('s1', { amps: 10 }),
    receipt('rA', { subscriberId: 's1', month: '2026-03', paid: 100, no: 1 }),
    receipt('rB', { subscriberId: 's1', month: '2026-04', paid: 100, no: 2 }),
  ]);
  assert.equal(seed.status, 200);
  assert.deepEqual(seed.data.rejected, []);

  // March is closed by a pending settlement (pending|approved both close it).
  const settle = await pushAs(owner.token, [settlement('st1', { month: '2026-03', amount: 100 })]);
  assert.equal(settle.status, 200);

  // The SAME edit, in the two months, in one batch.
  const edits = await pushAs(owner.token, [
    receipt('rA', { subscriberId: 's1', month: '2026-03', paid: 500, no: 1 }),
    receipt('rB', { subscriberId: 's1', month: '2026-04', paid: 500, no: 2 }),
  ]);
  assert.equal(edits.status, 200);
  assert.equal(edits.data.count, 2, 'both counted — the outbox drains completely');
  assert.deepEqual(edits.data.rejected, [], 'neither month is refused on the push path');

  // Both reach the mirror. Month ISOLATION is still real, but it is enforced in
  // the app and by the month-bucketed queries — never by dropping a row here,
  // which would revert the device at the next full restore.
  assert.equal((await mirrorRow(owner.id, 'receipts', 'rA')).data.paid_amount, 500);
  assert.equal((await mirrorRow(owner.id, 'receipts', 'rB')).data.paid_amount, 500);
});

// ------------------------------------------------------- the v43 entities ---

test('corrections + financial_adjustments are accepted by push and are NOT lock-gated', async () => {
  const owner = await registerOwner();

  // A subscriber-month that IS locked: the correction is precisely the escape
  // hatch for it, so both ledger entities must sail straight through.
  await pushAs(owner.token, [
    subscriber('sub-x', { amps: 10 }),
    receipt('r1', { subscriberId: 'sub-x', month: '2026-05', paid: 100, no: 1 }),
    settlement('st1', { month: '2026-05', amount: 100, status: 'approved' }),
  ]);

  const rows = [
    correction('corr-1', { subscriber_id: 'sub-x', receipt_uuid: 'r1', settlement_id: 'st1' }),
    adjustment('adj-1', { correction_id: 'corr-1' }),
  ];
  const r = await pushAs(owner.token, rows);
  assert.equal(r.status, 200, `push -> ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.count, 2);
  assert.deepEqual(r.data.rejected, [], 'the correction ledger is never blocked by the month lock it documents');

  const corr = await mirrorRow(owner.id, 'corrections', 'corr-1');
  assert.ok(corr, 'the correction reaches the mirror the panel decides on');
  assert.equal(corr.data.status, 'pending');
  assert.equal(corr.data.month, '2026-05');
  assert.equal(corr.data.difference, 20);
  assert.equal(corr.data.receipt_uuid, 'r1');

  const adj = await mirrorRow(owner.id, 'financial_adjustments', 'adj-1');
  assert.ok(adj, 'the immutable ledger row reaches the mirror');
  assert.equal(adj.data.kind, 'correction_increase');
  assert.equal(adj.data.amount, 20);
  assert.equal(adj.data.correction_id, 'corr-1');

  // The original invoice is untouched by any of it.
  assert.equal((await mirrorRow(owner.id, 'receipts', 'r1')).data.paid_amount, 100);
});

test('an accountant may push a CORRECTION request, but never a financial_adjustments row', async () => {
  const owner = await registerOwner();
  // No permissions at all: requesting a correction is core accountant work and
  // must not be gated on `subscribers` — that permission is exactly what the
  // accountant lacks when they need the correction flow.
  const acct = await makeAccountant(owner, { branchId: 'branch-A', permissions: [], localId: 'acct-local-A' });

  const req = await pushAs(acct.token, [correction('corr-acct', { branch_id: null, accountant_id: null })]);
  assert.equal(req.status, 200, `acct correction -> ${req.status} ${JSON.stringify(req.data)}`);
  assert.equal(req.data.count, 1);
  assert.deepEqual(req.data.rejected, []);

  const corr = await mirrorRow(owner.id, 'corrections', 'corr-acct');
  assert.ok(corr, "the accountant's correction request reaches the OWNER's mirror for approval");
  assert.equal(corr.data.branch_id, 'branch-A', 'branch_id is server-stamped, never trusted');
  // v43 review fix: on the CORRECTION entities `accountant_id` is a WALLET
  // TARGET the app resolves to whoever COLLECTED that month — often not the
  // filer. Server-stamping it re-attributed another accountant's credit, so it
  // must survive the push exactly as the app sent it.
  assert.equal(
    corr.data.accountant_id,
    null,
    'accountant_id on a correction is a wallet target and is NOT server-stamped'
  );

  // …while it IS still stamped on an ordinary business row.
  const rcp = await pushAs(acct.token, [receipt('r-acct', { subscriberId: 's1', month: '2026-05', paid: 10, no: 9 })]);
  assert.equal(rcp.status, 200);
  const rcpRow = await mirrorRow(owner.id, 'receipts', 'r-acct');
  assert.equal(rcpRow.data.accountant_id, 'acct-local-A', 'ordinary rows keep the server stamp');

  // Minting wallet credit is owner/admin only. Skipped + counted (so the device
  // drains) but NEVER mirrored.
  const forge = await pushAs(acct.token, [adjustment('adj-forged', { amount: 1000000 })]);
  assert.equal(forge.status, 200, `must not 4xx (that wedges the device), got ${forge.status} ${JSON.stringify(forge.data)}`);
  assert.equal(forge.data.count, 1, 'counted so the outbox drains');
  assert.equal(await mirrorRow(owner.id, 'financial_adjustments', 'adj-forged'), null, 'an accountant can never mint their own wallet credit');

  // Mixed batch, forbidden row first: the correction behind it still lands.
  const mixed = await pushAs(acct.token, [
    adjustment('adj-forged-2', { amount: 42 }),
    correction('corr-acct-2', { branch_id: null, accountant_id: null }),
  ]);
  assert.equal(mixed.status, 200);
  assert.equal(mixed.data.count, 2, 'both counted so the device outbox drains');
  assert.equal(await mirrorRow(owner.id, 'financial_adjustments', 'adj-forged-2'), null);
  assert.ok(await mirrorRow(owner.id, 'corrections', 'corr-acct-2'), 'the legal row behind the forbidden one still lands');
});

// ------------------------------------------------------------ regressions ---

test('an unknown entity still 400s BAD_ENTITY — and both v43 entities are known', async () => {
  const owner = await registerOwner();

  const evil = await pushAs(owner.token, [rec('evil_table', 'x1', { id: 'x1' })]);
  assert.equal(evil.status, 400, `unknown entity -> ${evil.status} ${JSON.stringify(evil.data)}`);
  assert.equal(evil.data.code, 'BAD_ENTITY');

  // The deploy-order guarantee (spec §4): a v43 APK pushing these two must not
  // meet that same 400, which would wedge the device's outbox permanently.
  const known = await pushAs(owner.token, [correction('corr-known'), adjustment('adj-known')]);
  assert.equal(known.status, 200, `v43 entities must be registered, got ${known.status} ${JSON.stringify(known.data)}`);
  assert.equal(known.data.count, 2);
});

test('a push with nothing locked answers exactly as before, plus an empty rejected[]', async () => {
  const owner = await registerOwner();
  const rows = [
    subscriber('s1', { amps: 10 }),
    rec('boards', 'b1', { id: 'b1', name: 'B', status: 'active' }),
    price('2026-09', { amount: 11 }),
  ];
  const r = await pushAs(owner.token, rows);
  assert.equal(r.status, 200);
  assert.equal(r.data.ok, true);
  assert.equal(r.data.count, 3);
  assert.deepEqual(r.data.rejected, []);
  assert.ok(r.data.serverTime, 'the response shape is unchanged for a client that ignores `rejected`');
  await assertMirrored(owner.id, rows);
});

test('v44 review: an accountant may push a PENDING correction but a DECIDED one is forgery — skipped, counted, reported', async () => {
  const owner = await registerOwner();
  const acct = await makeAccountant(owner, { branchId: 'branch-A', permissions: [], localId: 'acct-local-B' });

  // The ordinary request path: pending -> accepted.
  const ok = await pushAs(acct.token, [correction('corr-ok', { branch_id: null, accountant_id: null, status: 'pending' })]);
  assert.equal(ok.status, 200);
  assert.deepEqual(ok.data.rejected, []);
  assert.ok(await mirrorRow(owner.id, 'corrections', 'corr-ok'));

  // Forgery: an accountant pushing an already-decided row would re-price every
  // device on a forged old_amps. Skipped + counted (the outbox drains), never a
  // batch 4xx, and reported in rejected[].
  for (const status of ['approved', 'refund_due', 'completed', 'carried_forward', 'rejected']) {
    const forged = await pushAs(acct.token, [correction('corr-' + status, { branch_id: null, accountant_id: null, status })]);
    assert.equal(forged.status, 200, `forged ${status} -> ${forged.status}`);
    assert.equal(forged.data.count, 1, 'counted so the device drains');
    assert.equal(forged.data.rejected.length, 1);
    assert.equal(forged.data.rejected[0].reason, 'CORRECTION_DECISION_FORBIDDEN');
    assert.equal(await mirrorRow(owner.id, 'corrections', 'corr-' + status), null, `${status} never entered the mirror`);
  }

  // The OWNER's decision still flows normally.
  const decided = await pushAs(owner.token, [correction('corr-owner', { status: 'approved' })]);
  assert.equal(decided.status, 200);
  assert.deepEqual(decided.data.rejected, []);
  assert.equal((await mirrorRow(owner.id, 'corrections', 'corr-owner')).data.status, 'approved');
});

