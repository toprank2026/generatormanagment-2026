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
