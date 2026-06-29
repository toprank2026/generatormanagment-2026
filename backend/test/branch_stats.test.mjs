/**
 * Integration test for Multi-Branch on the OWNER panel data path:
 *
 *   GET /api/account/stats?month=M&branchId=B
 *
 * proves the server dashboard honours full branch isolation — the same contract
 * the Flutter app enforces locally. One owner pushes a "main" branch and a
 * "branch-2", each with its own monthly price, subscribers and receipts; the
 * stats endpoint must report each branch's figures in isolation and the whole
 * account when no branchId is given (consolidated). Also asserts the new
 * `branches` entity is counted.
 *
 * Boots a REAL Express server on an ephemeral port against in-memory MongoDB,
 * mirroring backend/test/account_data.test.mjs.
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

const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-branch-stats-test-'));
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
let owner;

const MONTH = '2026-06';

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

function dash(body) {
  return body && body.dashboard;
}

const rec = (entity, localId, data) => ({
  entity,
  localId,
  deleted: false,
  updatedAt: new Date().toISOString(),
  data,
});

test.before(async () => {
  await connectDb();
  await runSeed();
  const app = buildApp();
  await new Promise((resolve) => {
    server = app.listen(0, '127.0.0.1', resolve);
  });
  baseUrl = `http://127.0.0.1:${server.address().port}`;

  const username = `branchowner_${Date.now()}`;
  const reg = await api('POST', '/api/auth/register', {
    body: {
      name: 'Branch Owner',
      phone: username,
      username,
      password: 'secret1',
      device: { installId: 'i-1', deviceId: 'd-1', platform: 'android', model: 'X', osVersion: 'A13' },
    },
  });
  assert.equal(reg.status, 201, `register -> ${reg.status} ${JSON.stringify(reg.data)}`);
  owner = { token: reg.data.token };

  // Push two fully-isolated branches. main: price 1000, m1 (10A) fully paid
  // (10000). branch-2: price 2000, t1 (10A) underpaid (5000 of 20000).
  const push = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [
        rec('branches', 'main', { id: 'main', name: 'Main Branch', is_main: 1, active: 1 }),
        rec('branches', 'branch-2', { id: 'branch-2', name: 'Second Branch', is_main: 0, active: 1 }),

        rec('monthly_prices', `${MONTH}|main`, { month: MONTH, price_per_amp: 1000, branch_id: 'main' }),
        rec('monthly_prices', `${MONTH}|branch-2`, { month: MONTH, price_per_amp: 2000, branch_id: 'branch-2' }),

        rec('boards', 'bd-main', { id: 'bd-main', name: 'Main BD', branch_id: 'main' }),
        rec('boards', 'bd-two', { id: 'bd-two', name: 'Two BD', branch_id: 'branch-2' }),

        rec('subscribers', 'm1', { id: 'm1', name: 'Main Sub', amps: 10, board_id: 'bd-main', circuit_id: 'c1', status: 'active', branch_id: 'main' }),
        rec('subscribers', 't1', { id: 't1', name: 'Two Sub', amps: 10, board_id: 'bd-two', circuit_id: 'c2', status: 'active', branch_id: 'branch-2' }),

        rec('receipts', 'm-r1', {
          uuid: 'm-r1', receipt_no: 1, subscriber_id: 'm1', month: MONTH,
          amps_snapshot: 10, price_snapshot: 1000, paid_amount: 10000,
          remaining_after: 0, branch_id: 'main', status: 'valid',
          issued_at: `${MONTH}-05T00:00:00.000Z`,
        }),
        rec('receipts', 't-r1', {
          uuid: 't-r1', receipt_no: 1, subscriber_id: 't1', month: MONTH,
          amps_snapshot: 10, price_snapshot: 2000, paid_amount: 5000,
          remaining_after: 15000, branch_id: 'branch-2', status: 'valid',
          issued_at: `${MONTH}-05T00:00:00.000Z`,
        }),

        rec('expenses', 'm-e1', { id: 'm-e1', category: 'fuel', amount: 3000, date: `${MONTH}-06`, branch_id: 'main' }),
        rec('expenses', 't-e1', { id: 't-e1', category: 'oil', amount: 1000, date: `${MONTH}-06`, branch_id: 'branch-2' }),
      ],
    },
  });
  assert.equal(push.status, 200, `push -> ${push.status} ${JSON.stringify(push.data)}`);
  assert.equal(push.data.count, 12);
});

test.after(async () => {
  if (server) await new Promise((resolve) => server.close(resolve));
  await disconnectDb();
  try { fs.rmSync(TMP_BACKUP_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
});

test('stats?branchId=main isolates the Main Branch', async () => {
  const r = await api('GET', `/api/account/stats?month=${MONTH}&branchId=main`, { token: owner.token });
  assert.equal(r.status, 200, `stats -> ${r.status} ${JSON.stringify(r.data)}`);
  const d = dash(r.data);
  assert.equal(Number(d.pricePerAmp), 1000, 'Main Branch price');
  assert.equal(Number(d.totalSubscribers), 1, 'only the main subscriber');
  assert.equal(Number(d.paidCount), 1, 'm1 paid 10000 >= 10*1000');
  assert.equal(Number(d.unpaidCount), 0);
  assert.equal(Number(d.collected), 10000, 'only main receipts');
  assert.equal(Number(d.expensesTotal), 3000, 'only main expense');
  assert.equal(Number(d.boards), 1, 'only main board');
});

test('stats?branchId=branch-2 isolates the Second Branch', async () => {
  const r = await api('GET', `/api/account/stats?month=${MONTH}&branchId=branch-2`, { token: owner.token });
  assert.equal(r.status, 200, `stats -> ${r.status} ${JSON.stringify(r.data)}`);
  const d = dash(r.data);
  assert.equal(Number(d.pricePerAmp), 2000, 'Second Branch has its OWN price');
  assert.equal(Number(d.totalSubscribers), 1, 'only the branch-2 subscriber');
  assert.equal(Number(d.paidCount), 0, 't1 paid 5000 < 10*2000');
  assert.equal(Number(d.unpaidCount), 1);
  assert.equal(Number(d.collected), 5000, 'only branch-2 receipts');
  assert.equal(Number(d.expensesTotal), 1000, 'only branch-2 expense');
  assert.equal(Number(d.boards), 1, 'only branch-2 board');
});

test('stats with no branchId is consolidated (whole account)', async () => {
  const r = await api('GET', `/api/account/stats?month=${MONTH}`, { token: owner.token });
  assert.equal(r.status, 200, `stats -> ${r.status} ${JSON.stringify(r.data)}`);
  const d = dash(r.data);
  // Branch-agnostic totals combine both branches.
  assert.equal(Number(d.totalSubscribers), 2, 'both branches');
  assert.equal(Number(d.collected), 15000, '10000 + 5000');
  assert.equal(Number(d.expensesTotal), 4000, '3000 + 1000');
  assert.equal(Number(d.boards), 2, 'both branches');

  // v18 item 3: counts.branches now reflects branch SUB-ACCOUNTS (User docs with
  // parentOwner == owner — the authoritative source the owner-panel switcher
  // uses), NOT the synced `branches` MIRROR rows. This owner pushed two LOCAL
  // branch definitions to the mirror but created NO branch sub-accounts, so the
  // count is 0. (See branch_accounts.test.mjs for the positive case.)
  const counts = r.data.counts;
  assert.equal(Number(counts.branches), 0, 'no branch sub-accounts created (mirror rows are not counted)');
});

test('data?entity=...&branchId scopes mirror lists to one branch (owner panel)', async () => {
  // Subscribers: only the active branch's rows (drives the panel-wide switcher).
  const mainSubs = await api('GET', `/api/account/data?entity=subscribers&branchId=main`, { token: owner.token });
  assert.equal(mainSubs.status, 200);
  assert.equal(mainSubs.data.total, 1, 'only the main branch subscriber');
  assert.equal(mainSubs.data.records[0].localId, 'm1');

  const twoSubs = await api('GET', `/api/account/data?entity=subscribers&branchId=branch-2`, { token: owner.token });
  assert.equal(twoSubs.data.total, 1, 'only the branch-2 subscriber');
  assert.equal(twoSubs.data.records[0].localId, 't1');

  // No branchId -> consolidated (both).
  const all = await api('GET', `/api/account/data?entity=subscribers`, { token: owner.token });
  assert.equal(all.data.total, 2, 'consolidated lists both branches');

  // The branches identity table itself is NOT branch-filtered (no-op).
  const branches = await api('GET', `/api/account/data?entity=branches&branchId=main`, { token: owner.token });
  assert.equal(branches.data.total, 2, 'branches table ignores branchId (identity, not branch-partitioned)');
});
