/**
 * Flash v43 — the ADMIN side of "corrections after invoicing".
 *
 * An accountant may no longer silently rewrite the billing basis of a month that
 * is already invoiced or settled: they file a `corrections` row, it reaches the
 * owner's mirror through /api/sync/push like any other business row, and the
 * super admin decides it here. The whole point of the design is that a decision
 * NEVER edits an existing row — it appends ONE immutable `financial_adjustments`
 * record beside the untouched invoice — so these tests assert the negative side
 * as hard as the positive one:
 *
 *  - approving an increase leaves the original receipt AND the original
 *    settlement byte-for-byte identical (every field re-fetched and compared),
 *    consumes no `receipt_no`, and creates no `receipts` row;
 *  - approving a DECREASE writes nothing that reduces the wallet — it parks the
 *    correction at `refund_due`, because the wallet must never be driven
 *    negative by a historical correction;
 *  - the physical cash return is a SEPARATE, separately-recorded operation, and
 *    a second call to it can never append a second refund;
 *  - every decision route is idempotent: a decided correction is a 409 no-op,
 *    never a double credit to an append-only ledger that can never be un-written;
 *  - the money lands in `GET /api/account/wallet` in exactly one month, in
 *    exactly one wallet (cash/card), for exactly the right accountant;
 *  - the API-level bypass is closed: the admin synced-data DELETE refuses (409)
 *    to remove a receipt out of a month an active settlement has closed;
 *  - and the pre-existing settlement `decide` idempotency hole is shut — an
 *    already-approved settlement cannot be re-decided or re-amounted.
 *
 * Surfaces under test (backend/API_CONTRACT.md):
 *  - GET  /api/admin/corrections                     -> 200 { items, total, page, limit }
 *  - POST /api/admin/corrections/:id/approve         -> 200 { ok, correction, adjustment }
 *  - POST /api/admin/corrections/:id/reject          -> 200 { ok, correction }
 *  - POST /api/admin/corrections/:id/refund-paid     -> 200 { ok, correction, adjustment }
 *  - DELETE /api/admin/users/:id/data/:entity/:localId  -> 409 on a settled month
 *  - POST /api/account/settlements/:localId/decision -> 409 when already decided
 *  - GET  /api/account/wallet[?month=YYYY-MM]        -> folds the ledger in
 *
 * Boots a REAL Express server on an ephemeral port against in-memory MongoDB,
 * mirroring backend/test/v42_wallet_month.test.mjs. The mirror itself is read
 * back through the SyncRecord model for the things no HTTP surface can express
 * — proving an untouched row is untouched, and that a refused call appended
 * nothing — the same idiom backend/test/v42_password_reset.test.mjs uses.
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
const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-v43-corrections-test-'));
process.env.USE_MEMORY_DB = 'true';
process.env.NODE_ENV = 'test';
process.env.BACKUP_DIR = TMP_BACKUP_DIR;
process.env.JWT_SECRET = 'test-secret';
process.env.ADMIN_USERNAME = 'admin';
process.env.ADMIN_PASSWORD = 'admin123';

const { buildApp } = require('../src/server');
const { connectDb, disconnectDb } = require('../src/config/db');
const { runSeed } = require('../src/bootstrap/seed');
const SyncRecord = require('../src/models/SyncRecord');

let server;
let baseUrl;

// Two accounting months far from any wall-clock month, so nothing another test
// file could seed can collide with them. Every test also uses its OWN freshly
// registered owner, so the rows below are the only ones in scope for its mirror.
const MONTH_A = '2034-05';
const MONTH_B = '2034-06';

const IN_A = `${MONTH_A}-09T10:00:00.000Z`;
const IN_B = `${MONTH_B}-04T10:00:00.000Z`;

let counter = 0;
const uid = (prefix) => {
  counter += 1;
  return `v43c-${prefix}-${Date.now()}-${counter}`;
};

function makeDevice() {
  const n = uid('dev');
  return {
    installId: `install-${n}`,
    deviceId: `device-${n}`,
    platform: 'android',
    model: 'SM-TEST',
    osVersion: 'Android 13 (SDK 33)',
  };
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
  const raw = ct.includes('application/json') ? await res.text() : '';
  return { status: res.status, data: raw ? JSON.parse(raw) : null, raw };
}

/** A fresh owner account (its own isolated mirror) + its first device. */
async function registerOwner() {
  const username = uid('owner');
  const r = await api('POST', '/api/auth/register', {
    body: {
      name: 'Owner Name',
      generatorName: 'V43 Generator',
      phone: username,
      username,
      password: 'secret1',
      device: makeDevice(),
    },
  });
  assert.equal(r.status, 201, `register -> ${r.status} ${JSON.stringify(r.data)}`);
  return { token: r.data.token, id: r.data.account.id, username };
}

/** An accountant of [owner], logged in — the wallet these corrections land in. */
async function makeAccountant(owner) {
  const phone = uid('acct');
  const localId = `${phone}-local`;
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: { name: 'Acct One', phone, password: 'secret1', permissions: [], localId },
  });
  assert.equal(created.status, 201, `create accountant -> ${created.status} ${JSON.stringify(created.data)}`);
  const login = await api('POST', '/api/auth/login', { body: { username: phone, password: 'secret1' } });
  assert.equal(login.status, 200, `accountant login -> ${login.status} ${JSON.stringify(login.data)}`);
  return { token: login.data.token, localId, phone };
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

/**
 * Pushes fixture rows into the owner's mirror as the OWNER (unrestricted), so
 * the fixtures carry exactly the accountant_id / branch_id they declare instead
 * of the server-stamped ones a branch-confined accountant would get.
 *
 * Asserts `rejected` is EMPTY: a fixture row silently refused by the v43
 * push-loop month lock would make every later assertion meaningless.
 */
async function seedRows(owner, records) {
  const r = await api('POST', '/api/sync/push', { token: owner.token, body: { records } });
  assert.equal(r.status, 200, `push -> ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.count, records.length, 'every fixture row is accepted');
  assert.deepEqual(r.data.rejected, [], 'no fixture row was refused by the month lock');
  return r.data;
}

// ---------------------------------------------------------------- fixtures ---

function subscriberRow({ id, name, amps = 5, category = 'standard' }) {
  return {
    entity: 'subscribers',
    localId: id,
    deleted: false,
    updatedAt: IN_A,
    data: {
      id,
      name,
      phone: '07700000000',
      amps,
      category,
      board_id: null,
      circuit_id: null,
      branch_id: null,
      created_at: IN_A,
      updated_at: IN_A,
    },
  };
}

function receiptRow({ id, no, subscriberId, month, amount, method = 'cash', acctId }) {
  return {
    entity: 'receipts',
    localId: id,
    deleted: false,
    updatedAt: IN_A,
    data: {
      uuid: id,
      receipt_no: no,
      subscriber_id: subscriberId,
      month,
      amps_snapshot: 5,
      price_snapshot: 10000,
      paid_amount: amount,
      payment_method: method,
      accountant_id: acctId,
      status: 'valid',
      issued_at: `${month}-10T09:00:00.000Z`,
      updated_at: `${month}-10T09:00:00.000Z`,
    },
  };
}

function settlementRow({ id, month, amount, method = 'cash', acctId, status = 'pending' }) {
  return {
    entity: 'settlements',
    localId: id,
    deleted: false,
    updatedAt: IN_B,
    data: {
      id,
      accountant_id: acctId,
      amount,
      method,
      status,
      month,
      requested_at: IN_B,
      updated_at: IN_B,
    },
  };
}

/**
 * A correction request exactly as the device files it: the month it corrects,
 * the invoice + settlement that locked that month, and the signed `difference`
 * (new_due − old_due) that is the ONLY number the money path reads.
 */
function correctionRow({
  id,
  subscriberId,
  month,
  acctId,
  receiptUuid = null,
  settlementId = null,
  reason,
  oldAmps = 5,
  newAmps = 6,
  oldDue = 50000,
  newDue = 60000,
  status = 'pending',
  requestedAt = IN_B,
}) {
  return {
    entity: 'corrections',
    localId: id,
    deleted: false,
    updatedAt: requestedAt,
    data: {
      id,
      subscriber_id: subscriberId,
      month,
      branch_id: null,
      accountant_id: acctId,
      receipt_uuid: receiptUuid,
      settlement_id: settlementId,
      reason,
      old_amps: oldAmps,
      new_amps: newAmps,
      old_due: oldDue,
      new_due: newDue,
      difference: newDue - oldDue,
      status,
      requested_by: acctId,
      requested_at: requestedAt,
      created_at: requestedAt,
      updated_at: requestedAt,
    },
  };
}

// ------------------------------------------------------------ mirror reads ---

const mirrorRow = (userId, entity, localId) =>
  SyncRecord.findOne({ user: userId, entity, localId }).lean();

const mirrorRows = (userId, entity) =>
  SyncRecord.find({ user: userId, entity }).sort({ localId: 1 }).lean();

/**
 * A stable, fully-expanded snapshot of a mirror document: ObjectIds become
 * strings and Dates ISO strings, so two reads taken around an admin call can be
 * compared FIELD BY FIELD (`deepEqual` under node:assert/strict) instead of
 * spot-checking the handful of fields we happen to remember.
 */
const snapshot = (doc) => JSON.parse(JSON.stringify(doc));

/**
 * Snapshot of one mirror row that ASSERTS THE ROW EXISTS first. Without this,
 * a lookup that silently missed would make every "untouched" comparison below
 * pass vacuously (`deepEqual(null, null)`) — i.e. the strongest guarantees in
 * this file would be the easiest ones to break by accident.
 */
async function snapshotOf(userId, entity, localId) {
  const doc = await mirrorRow(userId, entity, localId);
  assert.ok(doc, `expected a mirrored ${entity} row ${localId}`);
  return snapshot(doc);
}

/** The mirror record's Mongo id for a correction — what the decision routes take. */
async function correctionApiId(ownerId, localId) {
  const list = await api('GET', `/api/admin/corrections?userId=${ownerId}&limit=200`, {
    token: await getAdminToken(),
  });
  assert.equal(list.status, 200, `list -> ${list.status} ${JSON.stringify(list.data)}`);
  const item = list.data.items.find((i) => i.localId === localId);
  assert.ok(item, `the correction ${localId} is listed for its owner`);
  return item.id;
}

const approveCorrection = async (id, note) =>
  api('POST', `/api/admin/corrections/${id}/approve`, {
    token: await getAdminToken(),
    body: note === undefined ? {} : { note },
  });

const rejectCorrection = async (id, note) =>
  api('POST', `/api/admin/corrections/${id}/reject`, {
    token: await getAdminToken(),
    body: note === undefined ? {} : { note },
  });

// Deliberately sent with NO body — the contract documents this call as payloadless.
const refundPaid = async (id) =>
  api('POST', `/api/admin/corrections/${id}/refund-paid`, { token: await getAdminToken() });

const walletOf = (token, month) =>
  api('GET', `/api/account/wallet${month ? `?month=${month}` : ''}`, { token });

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

/**
 * One invoiced, settlement-closed month with a single correction filed against
 * it. `difference` decides the branch under test: > 0 increase, < 0 decrease.
 *
 *   subscriber (5 A) → receipt #(paid) in MONTH_A → pending settlement for
 *   MONTH_A → correction for MONTH_A quoting both.
 */
async function seedCorrection({ difference, method = 'cash', paid = 50000 }) {
  const owner = await registerOwner();
  const acct = await makeAccountant(owner);
  const ids = {
    sub: uid('sub'),
    receipt: uid('rec'),
    settlement: uid('set'),
    correction: uid('cor'),
  };

  await seedRows(owner, [
    subscriberRow({ id: ids.sub, name: `Target ${ids.sub}` }),
    receiptRow({
      id: ids.receipt,
      no: 41,
      subscriberId: ids.sub,
      month: MONTH_A,
      amount: paid,
      method,
      acctId: acct.localId,
    }),
    settlementRow({ id: ids.settlement, month: MONTH_A, amount: 20000, acctId: acct.localId }),
    correctionRow({
      id: ids.correction,
      subscriberId: ids.sub,
      month: MONTH_A,
      acctId: acct.localId,
      receiptUuid: ids.receipt,
      settlementId: ids.settlement,
      reason: 'meter was misread',
      oldDue: 50000,
      newDue: 50000 + difference,
    }),
  ]);

  return { owner, acct, ids, paid, apiId: await correctionApiId(owner.id, ids.correction) };
}

// ------------------------------------------------------------------- queue ---

test('the queue lists corrections with the documented envelope, filtered by status/month/q and paginated', async () => {
  const owner = await registerOwner();
  const acct = await makeAccountant(owner);

  const subA = uid('sub');
  const subB = uid('sub');
  const nameA = `Alpha ${subA}`;
  const nameB = `Beta ${subB}`;
  const cPending = uid('cor');
  const cOther = uid('cor');
  const cRejected = uid('cor');

  await seedRows(owner, [
    subscriberRow({ id: subA, name: nameA }),
    subscriberRow({ id: subB, name: nameB }),
    correctionRow({
      id: cPending, subscriberId: subA, month: MONTH_A, acctId: acct.localId,
      reason: 'meter was misread', requestedAt: `${MONTH_B}-02T08:00:00.000Z`,
    }),
    correctionRow({
      id: cOther, subscriberId: subB, month: MONTH_B, acctId: acct.localId,
      reason: 'wrong tariff applied', requestedAt: `${MONTH_B}-03T08:00:00.000Z`,
    }),
    correctionRow({
      id: cRejected, subscriberId: subA, month: MONTH_A, acctId: acct.localId,
      reason: 'double counted amps', requestedAt: `${MONTH_B}-04T08:00:00.000Z`,
    }),
  ]);

  // Give the queue one DECIDED row so the status filter has something to exclude.
  const rejected = await rejectCorrection(await correctionApiId(owner.id, cRejected), 'reading was right');
  assert.equal(rejected.status, 200, `reject -> ${rejected.status} ${JSON.stringify(rejected.data)}`);

  const all = await api('GET', `/api/admin/corrections?userId=${owner.id}`, { token: await getAdminToken() });
  assert.equal(all.status, 200, `list -> ${all.status} ${JSON.stringify(all.data)}`);
  // The documented envelope, exactly — the panel pages off total/page/limit.
  assert.deepEqual(Object.keys(all.data).sort(), ['items', 'limit', 'page', 'total']);
  assert.equal(all.data.total, 3, 'all three corrections of this owner');
  assert.equal(all.data.page, 1);
  assert.equal(all.data.limit, 25, 'the default page size');
  assert.equal(all.data.items.length, 3);

  // PENDING FIRST — the decided row sinks below both open requests however
  // recently it was touched, so the admin's queue is the work still to do.
  assert.deepEqual(
    all.data.items.map((i) => i.localId),
    // cOther was requested a day after cPending; cRejected is the NEWEST of the
    // three and still sinks below both, because it is no longer work to do.
    [cOther, cPending, cRejected],
    'pending first, then newest requested_at first'
  );

  // The row the panel renders, field by field.
  const item = all.data.items.find((i) => i.localId === cPending);
  assert.ok(/^[a-f0-9]{24}$/.test(item.id), 'id is the mirror record id the decision routes take');
  assert.equal(item.userId, owner.id);
  assert.equal(item.ownerName, 'Owner Name');
  assert.equal(item.generatorName, 'V43 Generator');
  assert.equal(item.subscriberId, subA);
  assert.equal(item.subscriberName, nameA, 'the subscriber name is resolved through the id');
  assert.equal(item.month, MONTH_A);
  assert.equal(item.reason, 'meter was misread');
  assert.equal(item.oldAmps, 5);
  assert.equal(item.newAmps, 6);
  assert.equal(item.oldDue, 50000);
  assert.equal(item.newDue, 60000);
  assert.equal(item.difference, 10000);
  assert.equal(item.status, 'pending');
  assert.equal(item.requestedBy, acct.localId);
  assert.equal(item.decidedAt, null, 'nothing has been decided on this one');
  assert.equal(item.decidedBy, null);
  assert.equal(item.refundPaidAt, null);
  assert.equal(item.deleted, false);
  assert.ok(item.requestedAt && item.updatedAt);

  // Filters.
  const byStatus = await api('GET', `/api/admin/corrections?userId=${owner.id}&status=rejected`, {
    token: await getAdminToken(),
  });
  assert.equal(byStatus.data.total, 1, 'status filters before paginating');
  assert.equal(byStatus.data.items[0].localId, cRejected);
  assert.equal(byStatus.data.items[0].decisionNote, 'reading was right');

  const pendingOnly = await api('GET', `/api/admin/corrections?userId=${owner.id}&status=pending`, {
    token: await getAdminToken(),
  });
  assert.equal(pendingOnly.data.total, 2);

  const byMonth = await api('GET', `/api/admin/corrections?userId=${owner.id}&month=${MONTH_B}`, {
    token: await getAdminToken(),
  });
  assert.equal(byMonth.data.total, 1, 'the month filter is exact — a correction belongs to ONE month');
  assert.equal(byMonth.data.items[0].localId, cOther);

  const byReason = await api(
    'GET',
    `/api/admin/corrections?userId=${owner.id}&q=${encodeURIComponent('wrong tariff')}`,
    { token: await getAdminToken() }
  );
  assert.equal(byReason.data.total, 1, 'q matches the reason text');
  assert.equal(byReason.data.items[0].localId, cOther);

  // …and the search reaches THROUGH the subscriber id to the subscriber's name,
  // which a plain regex on the correction row cannot do.
  const byName = await api('GET', `/api/admin/corrections?userId=${owner.id}&q=${encodeURIComponent(nameA)}`, {
    token: await getAdminToken(),
  });
  assert.equal(byName.data.total, 2, "q matches the SUBSCRIBER's name");
  assert.deepEqual(byName.data.items.map((i) => i.localId).sort(), [cPending, cRejected].sort());

  // Pagination: two pages, no overlap, total unchanged by the slice.
  const p1 = await api('GET', `/api/admin/corrections?userId=${owner.id}&limit=2&page=1`, {
    token: await getAdminToken(),
  });
  const p2 = await api('GET', `/api/admin/corrections?userId=${owner.id}&limit=2&page=2`, {
    token: await getAdminToken(),
  });
  assert.equal(p1.data.items.length, 2);
  assert.equal(p1.data.limit, 2);
  assert.equal(p2.data.items.length, 1);
  assert.equal(p2.data.page, 2);
  assert.equal(p2.data.total, 3, 'total counts the matches, not the page');
  const ids1 = p1.data.items.map((i) => i.id);
  assert.equal(ids1.includes(p2.data.items[0].id), false, 'the pages do not overlap');

  // A junk status is IGNORED (200 + the full queue), never a 400 that would hide
  // the queue from a panel sending a stale filter value.
  const junk = await api('GET', `/api/admin/corrections?userId=${owner.id}&status=banana`, {
    token: await getAdminToken(),
  });
  assert.equal(junk.status, 200);
  assert.equal(junk.data.total, 3);

  // The queue is super-admin only — an owner cannot read (or decide) it.
  const asOwner = await api('GET', '/api/admin/corrections', { token: owner.token });
  assert.equal(asOwner.status, 403, `owner must not read the queue, got ${asOwner.status}`);
  assert.equal(asOwner.data.code, 'FORBIDDEN');
});

// ---------------------------------------------------------------- increase ---

test('approving an INCREASE appends one correction_increase and leaves the invoice and settlement byte-identical', async () => {
  const { owner, acct, ids, apiId } = await seedCorrection({ difference: 10000 });

  // Exactly what the month looked like before the decision.
  const receiptBefore = await snapshotOf(owner.id, 'receipts', ids.receipt);
  const settlementBefore = await snapshotOf(owner.id, 'settlements', ids.settlement);
  const subscriberBefore = await snapshotOf(owner.id, 'subscribers', ids.sub);
  const receiptIdsBefore = (await mirrorRows(owner.id, 'receipts')).map((r) => r.localId);
  assert.equal((await mirrorRows(owner.id, 'financial_adjustments')).length, 0, 'no ledger row yet');

  const dec = await approveCorrection(apiId, 'verified against the meter log');
  assert.equal(dec.status, 200, `approve -> ${dec.status} ${JSON.stringify(dec.data)}`);
  assert.equal(dec.data.ok, true);
  assert.equal(dec.data.correction.status, 'approved');
  assert.equal(dec.data.correction.localId, ids.correction);
  assert.equal(dec.data.correction.decisionNote, 'verified against the meter log');
  assert.ok(dec.data.correction.decidedAt, 'the decision is timestamped');
  assert.ok(dec.data.correction.decidedBy, 'the deciding admin is recorded');
  assert.equal(dec.data.correction.refundPaidAt, null, 'an increase returns no cash');

  // THE MONEY: one immutable ledger row, in the corrected month, for the
  // accountant whose wallet must rise — and never a receipt.
  const adj = dec.data.adjustment;
  assert.ok(adj, 'an increase books an adjustment');
  assert.equal(adj.kind, 'correction_increase');
  assert.equal(adj.amount, 10000, 'exactly the difference, no rounding, no sign flip');
  assert.equal(adj.month, MONTH_A, 'the SAME accounting month as the invoice it corrects');
  assert.equal(adj.correction_id, ids.correction);
  assert.equal(adj.subscriber_id, ids.sub);
  assert.equal(adj.accountant_id, acct.localId);
  assert.equal(adj.method, 'cash', "the corrected invoice's wallet");
  assert.ok(adj.created_by && adj.created_at);
  assert.equal(Object.prototype.hasOwnProperty.call(adj, 'receipt_no'), false, 'never a receipt number');

  const ledger = await mirrorRows(owner.id, 'financial_adjustments');
  assert.equal(ledger.length, 1, 'exactly ONE ledger row was appended');
  assert.equal(ledger[0].localId, adj.id, 'the ledger row is keyed by the adjustment id');
  assert.equal(ledger[0].deleted, false);
  assert.deepEqual(ledger[0].data, adj, 'the mirrored row IS what the API reported');

  // …and the correction itself carries the decision for the device's next pull.
  const correctionAfter = await mirrorRow(owner.id, 'corrections', ids.correction);
  assert.equal(correctionAfter.data.status, 'approved');
  assert.notEqual(correctionAfter.data.updated_at, IN_B, 'the per-row edit time was re-stamped');
  assert.equal(
    correctionAfter.data.updated_at,
    correctionAfter.data.decided_at,
    'data.updated_at is re-stamped at the decision so last-EDIT-wins carries it to the device'
  );

  // THE GUARANTEE: not one existing row moved. Every field, re-fetched.
  assert.deepEqual(
    await snapshotOf(owner.id, 'receipts', ids.receipt),
    receiptBefore,
    'the ORIGINAL INVOICE is untouched — an invoice is a historical document'
  );
  assert.deepEqual(
    await snapshotOf(owner.id, 'settlements', ids.settlement),
    settlementBefore,
    'the ORIGINAL SETTLEMENT is untouched'
  );
  assert.deepEqual(
    await snapshotOf(owner.id, 'subscribers', ids.sub),
    subscriberBefore,
    'the subscriber row is untouched — the correction does not rewrite the billing basis'
  );
  assert.deepEqual(
    (await mirrorRows(owner.id, 'receipts')).map((r) => r.localId),
    receiptIdsBefore,
    'no phantom receipt was created (a correction never consumes a receipt_no)'
  );
});

// -------------------------------------------------------------- the wallet ---

test('the approved increase lands in the wallet — with ?month= and without — and never in another month', async () => {
  const { owner, acct, apiId, paid } = await seedCorrection({ difference: 10000 });

  const before = await walletOf(acct.token, MONTH_A);
  assert.equal(before.status, 200, `wallet -> ${before.status} ${JSON.stringify(before.data)}`);
  assert.equal(before.data.cash.collected, paid, 'before the decision the month is just its invoice');

  assert.equal((await approveCorrection(apiId)).status, 200);

  const scoped = await walletOf(acct.token, MONTH_A);
  assert.equal(scoped.data.cash.collected, paid + 10000, 'the delta is folded into collected');
  assert.equal(scoped.data.card.collected, 0, 'a cash correction never touches the card wallet');
  assert.equal(scoped.data.cash.settled, 0, 'the settlement is still only PENDING');
  assert.equal(scoped.data.cash.balance, paid + 10000, 'balance = collected − settled');

  // The lifetime figure agrees (or the v42 lifetime cap would under-report).
  const lifetime = await walletOf(acct.token, null);
  assert.equal(lifetime.data.cash.collected, paid + 10000, 'the all-time wallet folds it in too');
  assert.equal(lifetime.data.collected, paid + 10000, 'the pre-v12 top-level alias still mirrors cash');

  // GOLDEN RULE: a correction can never affect another accounting month.
  const other = await walletOf(acct.token, MONTH_B);
  assert.equal(other.data.cash.collected, 0, 'month B saw nothing');
  assert.equal(other.data.card.collected, 0);
});

test('a CARD invoice corrects into the card wallet, never the cash one', async () => {
  const { acct, apiId, paid } = await seedCorrection({ difference: 7000, method: 'card' });

  assert.equal((await approveCorrection(apiId)).status, 200);

  const w = await walletOf(acct.token, MONTH_A);
  assert.equal(w.data.card.collected, paid + 7000, 'the delta follows the corrected invoice’s method');
  assert.equal(w.data.cash.collected, 0, 'the cash wallet is untouched');
});

// ---------------------------------------------------------------- decrease ---

test('approving a DECREASE parks it at refund_due and writes NOTHING that reduces the wallet', async () => {
  const { owner, acct, ids, apiId, paid } = await seedCorrection({ difference: -8000 });

  const receiptBefore = await snapshotOf(owner.id, 'receipts', ids.receipt);
  const settlementBefore = await snapshotOf(owner.id, 'settlements', ids.settlement);

  const dec = await approveCorrection(apiId, 'over-billed by one amp');
  assert.equal(dec.status, 200, `approve -> ${dec.status} ${JSON.stringify(dec.data)}`);
  assert.equal(
    dec.data.correction.status,
    'refund_due',
    'a decrease is NOT "approved and done" — the cash still has to be handed back'
  );
  assert.equal(dec.data.correction.refundPaidAt, null, 'approval never asserts that money moved');

  // The audit row exists, is POSITIVE, and is deliberately inert.
  const adj = dec.data.adjustment;
  assert.equal(adj.kind, 'correction_decrease');
  assert.equal(adj.amount, 8000, 'stored as a positive magnitude — the KIND decides the effect');
  assert.equal(adj.month, MONTH_A);
  assert.equal(adj.accountant_id, acct.localId);

  const ledger = await mirrorRows(owner.id, 'financial_adjustments');
  assert.equal(ledger.length, 1, 'exactly one row — and it is an audit row, not a debit');
  assert.equal(
    ledger.filter((r) => r.data.kind === 'refund_return').length,
    0,
    'no refund_return exists until the cash is physically returned'
  );

  // THE WALLET IS NOT REDUCED. This is the rule that keeps it from going
  // negative on a historical correction.
  const acctWallet = await walletOf(acct.token, MONTH_A);
  assert.equal(acctWallet.data.cash.collected, paid, 'a correction_decrease contributes EXACTLY 0');
  const ownerWallet = await walletOf(owner.token, MONTH_A);
  assert.equal(ownerWallet.data.cash.collected, paid, 'and 0 in the unscoped owner view as well');
  assert.equal((await walletOf(acct.token, null)).data.cash.collected, paid, 'all-time unchanged too');

  // Originals still untouched on this branch as well.
  assert.deepEqual(await snapshotOf(owner.id, 'receipts', ids.receipt), receiptBefore);
  assert.deepEqual(await snapshotOf(owner.id, 'settlements', ids.settlement), settlementBefore);
});

test('refund-paid closes the decrease with ONE refund_return, and a second call is a 409 that appends nothing', async () => {
  const { owner, acct, ids, apiId, paid } = await seedCorrection({ difference: -8000 });
  assert.equal((await approveCorrection(apiId)).status, 200);

  const done = await refundPaid(apiId);
  assert.equal(done.status, 200, `refund-paid -> ${done.status} ${JSON.stringify(done.data)}`);
  assert.equal(done.data.ok, true);
  assert.equal(done.data.correction.status, 'completed');
  assert.ok(done.data.correction.refundPaidAt, 'the physical return is timestamped');
  assert.ok(done.data.correction.refundPaidBy, 'and attributed');

  const ret = done.data.adjustment;
  assert.equal(ret.kind, 'refund_return');
  assert.equal(ret.amount, -8000, 'NEGATIVE: cash physically left the business');
  assert.equal(ret.month, MONTH_A, 'in the corrected month, never today’s');
  assert.equal(ret.correction_id, ids.correction);
  assert.equal(
    ret.accountant_id,
    null,
    'the OWNER returns the cash — a null accountant keeps every accountant wallet non-negative'
  );

  const ledger = await mirrorRows(owner.id, 'financial_adjustments');
  assert.equal(ledger.length, 2, 'the audit decrease plus the return — nothing overwritten');
  assert.deepEqual(
    ledger.map((r) => r.data.kind).sort(),
    ['correction_decrease', 'refund_return'],
    'append-only: the decrease row was not rewritten into the return'
  );

  // The money rule, both sides of it.
  assert.equal(
    (await walletOf(acct.token, MONTH_A)).data.cash.collected,
    paid,
    "the accountant's wallet is untouched by a return the owner made"
  );
  assert.equal(
    (await walletOf(owner.token, MONTH_A)).data.cash.collected,
    paid - 8000,
    'the business collected less: the return is visible in the unscoped view'
  );

  // A double-tap can never hand the money back twice.
  const correctionAfter = await snapshotOf(owner.id, 'corrections', ids.correction);
  const again = await refundPaid(apiId);
  assert.equal(again.status, 409, `second refund-paid -> ${again.status} ${JSON.stringify(again.data)}`);
  assert.equal(again.data.code, 'CORRECTION_NOT_REFUND_DUE');
  assert.equal((await mirrorRows(owner.id, 'financial_adjustments')).length, 2, 'no third ledger row');
  assert.deepEqual(
    await snapshotOf(owner.id, 'corrections', ids.correction),
    correctionAfter,
    'the refused call changed nothing at all'
  );
  assert.equal((await walletOf(owner.token, MONTH_A)).data.cash.collected, paid - 8000, 'and moved no money');
});

// ------------------------------------------------------------- idempotency ---

test('a decided correction can never be decided again — approve/reject/refund-paid are 409 no-ops', async () => {
  const { owner, ids, apiId, paid, acct } = await seedCorrection({ difference: 10000 });

  assert.equal((await approveCorrection(apiId, 'first and only')).status, 200);
  const afterFirst = await snapshotOf(owner.id, 'corrections', ids.correction);
  const ledgerAfterFirst = snapshot(await mirrorRows(owner.id, 'financial_adjustments'));
  assert.equal(ledgerAfterFirst.length, 1);

  // Approving twice would DOUBLE-CREDIT an append-only ledger whose surplus row
  // could never be deleted.
  const twice = await approveCorrection(apiId, 'second thoughts');
  assert.equal(twice.status, 409, `second approve -> ${twice.status} ${JSON.stringify(twice.data)}`);
  assert.equal(twice.data.code, 'CORRECTION_NOT_PENDING');

  // …and neither can a late rejection un-book it.
  const late = await rejectCorrection(apiId, 'changed my mind');
  assert.equal(late.status, 409, `reject after approve -> ${late.status} ${JSON.stringify(late.data)}`);
  assert.equal(late.data.code, 'CORRECTION_NOT_PENDING');

  // An INCREASE was never a refund obligation, so the cash-return route refuses it.
  const notDue = await refundPaid(apiId);
  assert.equal(notDue.status, 409, `refund-paid on an increase -> ${notDue.status}`);
  assert.equal(notDue.data.code, 'CORRECTION_NOT_REFUND_DUE');

  assert.deepEqual(
    await snapshotOf(owner.id, 'corrections', ids.correction),
    afterFirst,
    'three refused calls left the correction exactly as the first decision made it'
  );
  assert.deepEqual(
    snapshot(await mirrorRows(owner.id, 'financial_adjustments')),
    ledgerAfterFirst,
    'and appended nothing'
  );
  assert.equal(
    (await walletOf(acct.token, MONTH_A)).data.cash.collected,
    paid + 10000,
    'the wallet was credited exactly once'
  );
});

test('rejecting moves no money at all, and a rejected correction can never be approved later', async () => {
  const { owner, acct, ids, apiId, paid } = await seedCorrection({ difference: 10000 });

  const receiptBefore = await snapshotOf(owner.id, 'receipts', ids.receipt);

  const dec = await rejectCorrection(apiId, 'the meter reading was right');
  assert.equal(dec.status, 200, `reject -> ${dec.status} ${JSON.stringify(dec.data)}`);
  assert.equal(dec.data.ok, true);
  assert.equal(dec.data.correction.status, 'rejected');
  assert.equal(dec.data.correction.decisionNote, 'the meter reading was right');
  assert.ok(dec.data.correction.decidedAt);
  assert.equal(
    Object.prototype.hasOwnProperty.call(dec.data, 'adjustment'),
    false,
    'a rejection returns no adjustment because it writes none'
  );

  assert.equal((await mirrorRows(owner.id, 'financial_adjustments')).length, 0, 'the ledger stayed empty');
  assert.equal((await walletOf(acct.token, MONTH_A)).data.cash.collected, paid, 'the month keeps its figures');
  assert.deepEqual(await snapshotOf(owner.id, 'receipts', ids.receipt), receiptBefore);

  const late = await approveCorrection(apiId);
  assert.equal(late.status, 409, `approve after reject -> ${late.status} ${JSON.stringify(late.data)}`);
  assert.equal(late.data.code, 'CORRECTION_NOT_PENDING');
  assert.equal((await mirrorRows(owner.id, 'financial_adjustments')).length, 0, 'still nothing booked');
});

test('an unknown correction id is a 404, and the device UUID addresses the same row as the mirror id', async () => {
  const { owner, ids, apiId } = await seedCorrection({ difference: 5000 });

  const missing = await approveCorrection('v43c-no-such-correction');
  assert.equal(missing.status, 404, `unknown id -> ${missing.status} ${JSON.stringify(missing.data)}`);
  assert.equal(missing.data.code, 'CORRECTION_NOT_FOUND');
  assert.equal((await mirrorRows(owner.id, 'financial_adjustments')).length, 0);

  // The routes also accept the app's own UUID, so a caller holding only the
  // device id can act — and it resolves to the SAME record as the mirror id.
  const byLocalId = await approveCorrection(ids.correction);
  assert.equal(byLocalId.status, 200, `approve by localId -> ${byLocalId.status} ${JSON.stringify(byLocalId.data)}`);
  assert.equal(byLocalId.data.correction.id, apiId, 'same record, addressed either way');
  assert.equal((await mirrorRows(owner.id, 'financial_adjustments')).length, 1, 'and booked once');
});

// ------------------------------------------------------- API-level bypass ----

test('API BYPASS: the admin synced-data DELETE refuses to remove a receipt out of a settled month', async () => {
  const owner = await registerOwner();
  const acct = await makeAccountant(owner);
  const sub = uid('sub');
  const recLocked = uid('rec');
  const recFree = uid('rec');
  const set = uid('set');

  await seedRows(owner, [
    subscriberRow({ id: sub, name: `Locked ${sub}` }),
    receiptRow({ id: recLocked, no: 61, subscriberId: sub, month: MONTH_A, amount: 50000, acctId: acct.localId }),
    receiptRow({ id: recFree, no: 62, subscriberId: sub, month: MONTH_B, amount: 30000, acctId: acct.localId }),
    // Closes MONTH_A only — pending already counts as active.
    settlementRow({ id: set, month: MONTH_A, amount: 20000, acctId: acct.localId }),
  ]);

  const adminTok = await getAdminToken();
  const del = (entity, localId) =>
    api('DELETE', `/api/admin/users/${owner.id}/data/${entity}/${localId}`, { token: adminTok });

  const lockedBefore = await snapshotOf(owner.id, 'receipts', recLocked);

  const refused = await del('receipts', recLocked);
  assert.equal(refused.status, 409, `delete a settled receipt -> ${refused.status} ${JSON.stringify(refused.data)}`);
  assert.equal(refused.data.code, 'RECEIPT_MONTH_LOCKED');
  assert.deepEqual(
    await snapshotOf(owner.id, 'receipts', recLocked),
    lockedBefore,
    'the refusal did not tombstone, touch or re-time the row'
  );
  assert.equal(
    (await walletOf(acct.token, MONTH_A)).data.cash.collected,
    50000,
    'and moved no money out of the settled month'
  );

  // An ACTIVE settlement also locks its own month, so it cannot be made to
  // vanish either — it must be decided, which leaves a record.
  const setRefused = await del('settlements', set);
  assert.equal(setRefused.status, 409, `delete an active settlement -> ${setRefused.status}`);
  assert.equal(setRefused.data.code, 'SETTLEMENT_MONTH_LOCKED');

  // The guard is TARGETED, not a blanket refusal: an unsettled month still
  // deletes exactly as it does today.
  const ok = await del('receipts', recFree);
  assert.equal(ok.status, 200, `delete an unsettled receipt -> ${ok.status} ${JSON.stringify(ok.data)}`);
  assert.equal(ok.data.ok, true);
  assert.equal((await mirrorRow(owner.id, 'receipts', recFree)).deleted, true, 'tombstoned as before');

  // And the lock is DERIVED, not sticky: reject the settlement and the month
  // re-opens (the rejection itself is the record that it happened).
  const rejected = await api('POST', `/api/account/settlements/${set}/decision`, {
    token: owner.token,
    body: { status: 'rejected' },
  });
  assert.equal(rejected.status, 200, `reject settlement -> ${rejected.status} ${JSON.stringify(rejected.data)}`);
  const nowOk = await del('receipts', recLocked);
  assert.equal(nowOk.status, 200, 'with no active settlement the month is open again');
});

// -------------------------------------------- settlement decide idempotency ---

test('deciding an already-approved settlement is a 409 that changes neither the status nor the amount', async () => {
  const owner = await registerOwner();
  const acct = await makeAccountant(owner);
  const sub = uid('sub');
  const rec = uid('rec');
  const set = uid('set');

  await seedRows(owner, [
    subscriberRow({ id: sub, name: `Settle ${sub}` }),
    receiptRow({ id: rec, no: 71, subscriberId: sub, month: MONTH_A, amount: 50000, acctId: acct.localId }),
    settlementRow({ id: set, month: MONTH_A, amount: 30000, acctId: acct.localId }),
  ]);

  const decide = (body) =>
    api('POST', `/api/account/settlements/${set}/decision`, { token: owner.token, body });

  const first = await decide({ status: 'approved' });
  assert.equal(first.status, 200, `approve -> ${first.status} ${JSON.stringify(first.data)}`);
  assert.equal(first.data.settlement.status, 'approved');
  assert.equal(first.data.settlement.amount, 30000);
  const afterFirst = await snapshotOf(owner.id, 'settlements', set);

  // Pre-v43 this filter carried no status condition, so a stale panel tab could
  // re-approve at ANY amount and silently move the derived wallet.
  const reAmount = await decide({ status: 'approved', amount: 99999 });
  assert.equal(reAmount.status, 409, `re-approve -> ${reAmount.status} ${JSON.stringify(reAmount.data)}`);
  assert.equal(reAmount.data.code, 'SETTLEMENT_NOT_PENDING');

  const flip = await decide({ status: 'rejected', note: 'actually no' });
  assert.equal(flip.status, 409, `flip approved -> rejected -> ${flip.status} ${JSON.stringify(flip.data)}`);
  assert.equal(flip.data.code, 'SETTLEMENT_NOT_PENDING');

  assert.deepEqual(
    await snapshotOf(owner.id, 'settlements', set),
    afterFirst,
    'neither refused decision changed the stored amount, status or decision stamp'
  );
  const w = await walletOf(acct.token, MONTH_A);
  assert.equal(w.data.cash.settled, 30000, 'the wallet still subtracts the amount that was actually approved');
  assert.equal(w.data.cash.balance, 20000);

  // A settlement that does not exist in this mirror is still a plain 404, so
  // "wrong account" stays distinguishable from "already handled".
  const missing = await api('POST', '/api/account/settlements/v43c-no-such-settlement/decision', {
    token: owner.token,
    body: { status: 'approved' },
  });
  assert.equal(missing.status, 404, `unknown settlement -> ${missing.status} ${JSON.stringify(missing.data)}`);
  assert.equal(missing.data.code, 'SETTLEMENT_NOT_FOUND');
});

// ------------------------------------------- v43 adversarial-review fixes ---

test('the append-only ledger can NEVER be deleted through the admin synced-data DELETE', async () => {
  const { owner, acct, ids, apiId } = await seedCorrection({ difference: 5000 });
  const correctionLocalId = ids.correction;

  const adminTok = await getAdminToken();
  const approved = await api('POST', `/api/admin/corrections/${apiId}/approve`, { token: adminTok });
  assert.equal(approved.status, 200, `approve -> ${approved.status} ${JSON.stringify(approved.data)}`);

  const adjustments = await mirrorRows(owner.id, 'financial_adjustments');
  assert.equal(adjustments.length, 1, 'the approval appended exactly one adjustment');
  const adj = adjustments[0];
  const before = await snapshotOf(owner.id, 'financial_adjustments', adj.localId);
  const walletBefore = (await walletOf(acct.token, MONTH_A)).data.cash.collected;

  const del = (entity, localId) =>
    api('DELETE', `/api/admin/users/${owner.id}/data/${entity}/${localId}`, { token: adminTok });

  // A tombstone here would not just hide a panel row: it PROPAGATES to every
  // device on the next pull and silently moves the accountant's wallet. The
  // whole v43 design rests on "approval never edits or deletes an original".
  const refusedAdj = await del('financial_adjustments', adj.localId);
  assert.equal(refusedAdj.status, 409, `delete an adjustment -> ${refusedAdj.status} ${JSON.stringify(refusedAdj.data)}`);
  assert.equal(refusedAdj.data.code, 'ADJUSTMENT_IMMUTABLE');

  const refusedCorr = await del('corrections', correctionLocalId);
  assert.equal(refusedCorr.status, 409, `delete a correction -> ${refusedCorr.status}`);
  assert.equal(refusedCorr.data.code, 'CORRECTION_IMMUTABLE');

  // Nothing moved.
  assert.deepEqual(
    await snapshotOf(owner.id, 'financial_adjustments', adj.localId),
    before,
    'the refusal did not tombstone, touch or re-time the ledger row'
  );
  assert.equal((await mirrorRow(owner.id, 'corrections', correctionLocalId)).deleted, false);
  assert.equal(
    (await walletOf(acct.token, MONTH_A)).data.cash.collected,
    walletBefore,
    'and the wallet is exactly where the approval left it'
  );
});

test('the owner DASHBOARD folds approved corrections into collected, like the app does', async () => {
  const { owner, acct, apiId } = await seedCorrection({ difference: 5000, paid: 50000 });

  const stats = (month) =>
    api('GET', `/api/account/stats?month=${month}`, { token: owner.token });

  const before = await stats(MONTH_A);
  assert.equal(before.status, 200, `stats -> ${before.status} ${JSON.stringify(before.data)}`);
  const collectedBefore = before.data.dashboard.collected;
  assert.equal(collectedBefore, 50000, 'the invoice cash only, before any correction');

  const adminTok = await getAdminToken();
  const approved = await api('POST', `/api/admin/corrections/${apiId}/approve`, { token: adminTok });
  assert.equal(approved.status, 200);

  // The app's getCollectedSum folds the ledger in; if the dashboard does not,
  // /api/account/stats and the owner panel report a DIFFERENT monthly revenue
  // and net profit than the device for the very same month.
  const after = await stats(MONTH_A);
  assert.equal(after.status, 200);
  assert.equal(after.data.dashboard.collected, 55000, 'the +5,000 correction is collected');
  assert.equal(after.data.dashboard.monthlyRevenue, 55000, 'revenue tracks collected');
  assert.equal(
    after.data.dashboard.collected,
    (await walletOf(acct.token, MONTH_A)).data.cash.collected,
    'the dashboard and the wallet agree on the same month'
  );

  // …and no OTHER month moved.
  const other = await stats(MONTH_B);
  assert.equal(other.status, 200);
  assert.equal(other.data.dashboard.collected, 0, 'a correction never leaks across months');
});
