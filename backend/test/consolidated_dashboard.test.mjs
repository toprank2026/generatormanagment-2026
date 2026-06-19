/**
 * Phase-1 dashboard fix (WS-DASH #1): the CONSOLIDATED dashboard (no branchId)
 * must price each subscriber by its OWN branch + category, not collapse all
 * branches into a single category map.
 *
 * Setup: two branches with DIFFERENT standard prices for the same month.
 *   main:     price 1000, m1 (10A) fully paid (10000)
 *   branch-2: price 5000, t1 (10A) fully paid (50000)
 * Consolidated `expected` must be 10*1000 + 10*5000 = 60000 (per-branch prices).
 * The OLD (buggy) collapse used whichever monthly_prices row landed last for the
 * 'standard' category for BOTH subscribers, giving 10*P + 10*P (e.g. 20000 or
 * 100000) and a wrong paidCount. This test pins the correct per-branch math.
 *
 * Boots a REAL Express server on an ephemeral port against in-memory MongoDB,
 * mirroring backend/test/branch_stats.test.mjs.
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

const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-consolidated-dash-test-'));
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

const dash = (body) => body && body.dashboard;
const rec = (entity, localId, data) => ({ entity, localId, deleted: false, updatedAt: new Date().toISOString(), data });

test.before(async () => {
  await connectDb();
  await runSeed();
  const app = buildApp();
  await new Promise((resolve) => { server = app.listen(0, '127.0.0.1', resolve); });
  baseUrl = `http://127.0.0.1:${server.address().port}`;

  const username = `condash_${Date.now()}`;
  const reg = await api('POST', '/api/auth/register', {
    body: { name: 'Owner', phone: username, username, password: 'secret1', device: { installId: 'i-1', deviceId: 'd-1', platform: 'android', model: 'X', osVersion: 'A13' } },
  });
  assert.equal(reg.status, 201, `register -> ${reg.status} ${JSON.stringify(reg.data)}`);
  owner = { token: reg.data.token };

  const push = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [
        rec('branches', 'main', { id: 'main', name: 'Main', is_main: 1, active: 1 }),
        rec('branches', 'branch-2', { id: 'branch-2', name: 'Second', is_main: 0, active: 1 }),

        // Same month, same 'standard' category, DIFFERENT per-branch prices.
        rec('monthly_prices', `${MONTH}|main`, { month: MONTH, category: 'standard', price_per_amp: 1000, branch_id: 'main' }),
        rec('monthly_prices', `${MONTH}|branch-2`, { month: MONTH, category: 'standard', price_per_amp: 5000, branch_id: 'branch-2' }),

        rec('subscribers', 'm1', { id: 'm1', name: 'Main Sub', amps: 10, category: 'standard', status: 'active', branch_id: 'main' }),
        rec('subscribers', 't1', { id: 't1', name: 'Two Sub', amps: 10, category: 'standard', status: 'active', branch_id: 'branch-2' }),

        rec('receipts', 'm-r1', { uuid: 'm-r1', receipt_no: 1, subscriber_id: 'm1', month: MONTH, paid_amount: 10000, status: 'valid', branch_id: 'main', issued_at: `${MONTH}-05T00:00:00.000Z` }),
        rec('receipts', 't-r1', { uuid: 't-r1', receipt_no: 1, subscriber_id: 't1', month: MONTH, paid_amount: 50000, status: 'valid', branch_id: 'branch-2', issued_at: `${MONTH}-05T00:00:00.000Z` }),
      ],
    },
  });
  assert.equal(push.status, 200, `push -> ${push.status} ${JSON.stringify(push.data)}`);
});

test.after(async () => {
  if (server) await new Promise((resolve) => server.close(resolve));
  await disconnectDb();
  try { fs.rmSync(TMP_BACKUP_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
});

test('consolidated dashboard prices each subscriber by its OWN branch', async () => {
  const r = await api('GET', `/api/account/stats?month=${MONTH}`, { token: owner.token });
  assert.equal(r.status, 200, `stats -> ${r.status} ${JSON.stringify(r.data)}`);
  const d = dash(r.data);

  assert.equal(Number(d.totalSubscribers), 2);
  // expected = 10*1000 (main) + 10*5000 (branch-2) = 60000 — per-branch pricing.
  assert.equal(Number(d.totalDue) + Number(d.collected), 60000, 'expected uses per-branch prices (60000)');
  // collected = 10000 + 50000 = 60000 -> fully paid -> remaining 0.
  assert.equal(Number(d.collected), 60000);
  assert.equal(Number(d.totalDue), 0, 'remaining 0 (both fully paid at their own branch price)');
  assert.equal(Number(d.paidCount), 2, 'BOTH paid at their own branch price');
  assert.equal(Number(d.unpaidCount), 0);
});

test('single-branch dashboard is unchanged (each branch isolated)', async () => {
  const main = await api('GET', `/api/account/stats?month=${MONTH}&branchId=main`, { token: owner.token });
  assert.equal(Number(dash(main.data).pricePerAmp), 1000);
  assert.equal(Number(dash(main.data).paidCount), 1);
  assert.equal(Number(dash(main.data).collected), 10000);

  const two = await api('GET', `/api/account/stats?month=${MONTH}&branchId=branch-2`, { token: owner.token });
  assert.equal(Number(dash(two.data).pricePerAmp), 5000);
  assert.equal(Number(dash(two.data).paidCount), 1);
  assert.equal(Number(dash(two.data).collected), 50000);
});
