/**
 * Phase-1 sync-push hardening (WS-PUSHAUTHZ).
 *
 * Covers:
 *  - push rejects an UNKNOWN entity (400 BAD_ENTITY) — only the whitelisted
 *    synced tables may be mirrored.
 *  - an accountant pushing an entity their permissions do not grant -> 403
 *    (subscribers/boards/expenses/prices are permission-gated; branches/
 *    accountants are owner-only; receipts/refunds are always allowed).
 *  - a branch-confined accountant cannot write another branch (403) and has its
 *    data.branch_id / data.accountant_id server-stamped (client values ignored).
 *  - pull for a branch-confined accountant is scoped to its own branch (+ the
 *    branch-agnostic identity tables); owners see everything.
 *
 * Boots a REAL Express server on an ephemeral port against in-memory MongoDB,
 * mirroring backend/test/accountants.test.mjs.
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

const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-pushauthz-test-'));
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

let deviceCounter = 0;
function makeDevice(overrides = {}) {
  deviceCounter += 1;
  return { installId: `install-${deviceCounter}`, deviceId: `device-${deviceCounter}`, platform: 'android', model: 'X', osVersion: 'A13', ...overrides };
}

let userCounter = 0;
function uniqueUsername(prefix = 'owner') {
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
  const data = ct.includes('application/json') ? await res.json() : await res.arrayBuffer();
  return { status: res.status, data };
}

async function registerOwner() {
  const username = uniqueUsername();
  const password = 'secret1';
  const device = makeDevice();
  const r = await api('POST', '/api/auth/register', { body: { name: 'Owner', phone: username, username, password, device } });
  assert.equal(r.status, 201, `register -> ${r.status} ${JSON.stringify(r.data)}`);
  return { token: r.data.token, account: r.data.account, username, password, device };
}

// Create an accountant under `owner` (optionally branch-confined / with perms)
// and return its login token.
async function makeAccountant(owner, { branchId = null, permissions = [], localId = null } = {}) {
  const uname = uniqueUsername('acct');
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: { name: 'Acct', username: uname, password: 'secret1', branchId, permissions, localId },
  });
  assert.equal(created.status, 201, `create acct -> ${created.status} ${JSON.stringify(created.data)}`);
  const login = await api('POST', '/api/auth/login', { body: { username: uname, password: 'secret1' } });
  assert.equal(login.status, 200);
  return { token: login.data.token, account: login.data.account, id: created.data.accountant.id, localId };
}

const rec = (entity, localId, data, extra = {}) => ({ entity, localId, deleted: false, updatedAt: new Date().toISOString(), data, ...extra });

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

// ---------------------------------------------------------------------------
// Unknown entity whitelist.
// ---------------------------------------------------------------------------
test('push rejects an UNKNOWN entity -> 400 BAD_ENTITY', async () => {
  const owner = await registerOwner();
  const r = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: { records: [rec('evil_table', 'x1', { id: 'x1' })] },
  });
  assert.equal(r.status, 400, `expected 400, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.code, 'BAD_ENTITY');

  // A whitelisted entity still works for the owner.
  const ok = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: { records: [rec('subscribers', 's1', { id: 's1', name: 'S', amps: 1, status: 'active' })] },
  });
  assert.equal(ok.status, 200);
});

// ---------------------------------------------------------------------------
// Accountant permission gating per entity.
// ---------------------------------------------------------------------------
test('accountant cannot push an entity its permissions lack (subscribers) -> 403', async () => {
  const owner = await registerOwner();
  const acct = await makeAccountant(owner, { permissions: ['expenses'] }); // no 'subscribers'

  const denied = await api('POST', '/api/sync/push', {
    token: acct.token,
    body: { records: [rec('subscribers', 'a-s1', { id: 'a-s1', name: 'X', amps: 1, status: 'active' })] },
  });
  assert.equal(denied.status, 403, `expected 403, got ${denied.status} ${JSON.stringify(denied.data)}`);
  assert.equal(denied.data.code, 'PERMISSION_DENIED');

  // receipts are always allowed even with no matching permission.
  const receiptOk = await api('POST', '/api/sync/push', {
    token: acct.token,
    body: { records: [rec('receipts', 'a-r1', { uuid: 'a-r1', receipt_no: 1, subscriber_id: 'a-s1', month: '2026-06', paid_amount: 10, status: 'valid' })] },
  });
  assert.equal(receiptOk.status, 200, `receipts must be allowed, got ${receiptOk.status} ${JSON.stringify(receiptOk.data)}`);

  // expenses (granted) are allowed.
  const expenseOk = await api('POST', '/api/sync/push', {
    token: acct.token,
    body: { records: [rec('expenses', 'a-e1', { id: 'a-e1', amount: 5, date: '2026-06-01' })] },
  });
  assert.equal(expenseOk.status, 200);
});

test('accountant can NEVER push owner-only identity tables (branches/accountants) -> 403', async () => {
  const owner = await registerOwner();
  const acct = await makeAccountant(owner, { permissions: ['subscribers', 'boards', 'expenses', 'prices'] });

  const branches = await api('POST', '/api/sync/push', {
    token: acct.token,
    body: { records: [rec('branches', 'b-x', { id: 'b-x', name: 'X' })] },
  });
  assert.equal(branches.status, 403);
  assert.equal(branches.data.code, 'ENTITY_FORBIDDEN');

  const accountants = await api('POST', '/api/sync/push', {
    token: acct.token,
    body: { records: [rec('accountants', 'acc-x', { id: 'acc-x' })] },
  });
  assert.equal(accountants.status, 403);
  assert.equal(accountants.data.code, 'ENTITY_FORBIDDEN');
});

// ---------------------------------------------------------------------------
// Branch confinement: cross-branch write rejected; own-branch stamped.
// ---------------------------------------------------------------------------
test('branch-confined accountant cannot write ANOTHER branch -> 403 BRANCH_FORBIDDEN', async () => {
  const owner = await registerOwner();
  const acct = await makeAccountant(owner, { branchId: 'branch-A', permissions: ['subscribers'] });

  const cross = await api('POST', '/api/sync/push', {
    token: acct.token,
    body: { records: [rec('subscribers', 'x-sub', { id: 'x-sub', name: 'Hijack', amps: 1, status: 'active', branch_id: 'branch-B' })] },
  });
  assert.equal(cross.status, 403, `expected 403, got ${cross.status} ${JSON.stringify(cross.data)}`);
  assert.equal(cross.data.code, 'BRANCH_FORBIDDEN');
});

test('branch-confined accountant push is server-stamped (branch_id + accountant_id forced)', async () => {
  const owner = await registerOwner();
  // Give the accountant a localId — the APP-side accountant UUID that every
  // business row's accountant_id must carry for the on-device attribution
  // round-trip. The server must stamp THIS, not the Mongo _id.
  const acct = await makeAccountant(owner, { branchId: 'branch-A', permissions: ['subscribers'], localId: 'acct-local-A' });

  // Client sends NO branch_id and a forged accountant_id; server overwrites both.
  const push = await api('POST', '/api/sync/push', {
    token: acct.token,
    body: { records: [rec('subscribers', 's-stamp', { id: 's-stamp', name: 'Stamped', amps: 2, status: 'active', accountant_id: 'forged-id' })] },
  });
  assert.equal(push.status, 200, `push -> ${push.status} ${JSON.stringify(push.data)}`);

  // The owner pulls and sees the stamped values.
  const ownerPull = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z', { token: owner.token });
  const row = ownerPull.data.records.find((r) => r.localId === 's-stamp');
  assert.ok(row, 'owner sees the accountant row');
  assert.equal(row.data.branch_id, 'branch-A', 'branch_id server-stamped to the accountant branch');
  assert.equal(row.data.accountant_id, 'acct-local-A', 'accountant_id server-stamped to the localId (forged value ignored)');
});

// ---------------------------------------------------------------------------
// Pull scoping for a branch-confined accountant.
// ---------------------------------------------------------------------------
test('branch-confined accountant pull is scoped to its own branch (+ identity tables)', async () => {
  const owner = await registerOwner();

  // Owner seeds two branches of data + a branch identity row.
  const seed = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [
        rec('branches', 'branch-A', { id: 'branch-A', name: 'A' }),
        rec('branches', 'branch-B', { id: 'branch-B', name: 'B' }),
        rec('subscribers', 'A-sub', { id: 'A-sub', name: 'A sub', amps: 1, status: 'active', branch_id: 'branch-A' }),
        rec('subscribers', 'B-sub', { id: 'B-sub', name: 'B sub', amps: 1, status: 'active', branch_id: 'branch-B' }),
        rec('subscribers', 'legacy-sub', { id: 'legacy-sub', name: 'Legacy', amps: 1, status: 'active' }), // no branch_id
      ],
    },
  });
  assert.equal(seed.status, 200);

  const acct = await makeAccountant(owner, { branchId: 'branch-A', permissions: ['subscribers'] });

  const pull = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z', { token: acct.token });
  assert.equal(pull.status, 200);
  const ids = new Set(pull.data.records.map((r) => r.localId));

  assert.ok(ids.has('A-sub'), 'sees its own branch subscriber');
  assert.ok(!ids.has('B-sub'), 'does NOT see another branch subscriber');
  assert.ok(ids.has('legacy-sub'), 'sees legacy (no branch_id) rows');
  assert.ok(ids.has('branch-A') && ids.has('branch-B'), 'sees the branch identity table (branch-agnostic)');

  // The OWNER still sees everything (unaffected by accountant scoping).
  const ownerPull = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z', { token: owner.token });
  const ownerIds = new Set(ownerPull.data.records.map((r) => r.localId));
  assert.ok(ownerIds.has('A-sub') && ownerIds.has('B-sub'), 'owner sees both branches');
});
