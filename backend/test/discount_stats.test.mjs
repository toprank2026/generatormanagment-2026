/**
 * Integration test for the receipt DISCOUNT on the OWNER panel dashboard:
 *
 *   GET /api/account/stats?month=M
 *
 * proves buildDashboard folds the waived discount into the DUE side (coverage =
 * paid_amount + discount_value drives paid/unpaid; remaining subtracts the
 * discount) WITHOUT ever adding it to `collected`/revenue/profit, exactly like
 * the Flutter app. Also asserts the per-tariff `categoryPrices` map is returned.
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

const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-discount-stats-test-'));
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

  const username = `discountowner_${Date.now()}`;
  const reg = await api('POST', '/api/auth/register', {
    body: {
      name: 'Discount Owner',
      phone: username,
      username,
      password: 'secret1',
      device: { installId: 'i-1', deviceId: 'd-1', platform: 'android', model: 'X', osVersion: 'A13' },
    },
  });
  assert.equal(reg.status, 201, `register -> ${reg.status} ${JSON.stringify(reg.data)}`);
  owner = { token: reg.data.token };

  // Three tariff prices for the month (gold/standard/commercial).
  // sub-disc (standard, 10A, due 50000): paid 30000 CASH + discount_value 20000
  //   WAIVED -> coverage 50000 >= due -> PAID, but collected counts only 30000.
  // sub-plain (standard, 10A, due 50000): paid 50000 -> PAID, no discount.
  // sub-unpaid (standard, 10A, due 50000): paid 10000 -> UNPAID.
  const push = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [
        rec('monthly_prices', `${MONTH}|gold`, { month: MONTH, category: 'gold', price_per_amp: 7000 }),
        rec('monthly_prices', `${MONTH}|standard`, { month: MONTH, category: 'standard', price_per_amp: 5000 }),
        rec('monthly_prices', `${MONTH}|commercial`, { month: MONTH, category: 'commercial', price_per_amp: 6000 }),

        rec('subscribers', 'sub-disc', { id: 'sub-disc', name: 'Discounted', amps: 10, category: 'standard', status: 'active' }),
        rec('subscribers', 'sub-plain', { id: 'sub-plain', name: 'Plain', amps: 10, category: 'standard', status: 'active' }),
        rec('subscribers', 'sub-unpaid', { id: 'sub-unpaid', name: 'Unpaid', amps: 10, category: 'standard', status: 'active' }),

        rec('receipts', 'r-disc', {
          uuid: 'r-disc', receipt_no: 1, subscriber_id: 'sub-disc', month: MONTH,
          amps_snapshot: 10, price_snapshot: 5000, category_snapshot: 'standard',
          paid_amount: 30000, discount_type: 'value', discount_value: 20000, discount_amps: null,
          remaining_after: 0, status: 'valid', issued_at: `${MONTH}-05T00:00:00.000Z`,
        }),
        rec('receipts', 'r-plain', {
          uuid: 'r-plain', receipt_no: 2, subscriber_id: 'sub-plain', month: MONTH,
          amps_snapshot: 10, price_snapshot: 5000, category_snapshot: 'standard',
          paid_amount: 50000, discount_type: 'none', discount_value: 0,
          remaining_after: 0, status: 'valid', issued_at: `${MONTH}-05T00:00:00.000Z`,
        }),
        rec('receipts', 'r-unpaid', {
          uuid: 'r-unpaid', receipt_no: 3, subscriber_id: 'sub-unpaid', month: MONTH,
          amps_snapshot: 10, price_snapshot: 5000, category_snapshot: 'standard',
          paid_amount: 10000,
          remaining_after: 40000, status: 'valid', issued_at: `${MONTH}-05T00:00:00.000Z`,
        }),
      ],
    },
  });
  assert.equal(push.status, 200, `push -> ${push.status} ${JSON.stringify(push.data)}`);
  assert.equal(push.data.count, 9);
});

test.after(async () => {
  if (server) await new Promise((resolve) => server.close(resolve));
  await disconnectDb();
  try { fs.rmSync(TMP_BACKUP_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
});

test('discount folds into coverage (paid+discount) for paid/unpaid', async () => {
  const r = await api('GET', `/api/account/stats?month=${MONTH}`, { token: owner.token });
  assert.equal(r.status, 200, `stats -> ${r.status} ${JSON.stringify(r.data)}`);
  const d = dash(r.data);
  // sub-disc (30000 cash + 20000 waived = 50000 >= 50000) and sub-plain are PAID.
  assert.equal(Number(d.paidCount), 2, 'discounted full payment + plain full payment count as paid');
  assert.equal(Number(d.unpaidCount), 1, 'only sub-unpaid (10000 < 50000) is unpaid');
});

test('collected stays Σ paid_amount — the waived discount is NOT collected', async () => {
  const r = await api('GET', `/api/account/stats?month=${MONTH}`, { token: owner.token });
  const d = dash(r.data);
  // 30000 + 50000 + 10000 = 90000. The 20000 discount is WAIVED, never collected.
  assert.equal(Number(d.collected), 90000, 'collected excludes the waived discount');
  assert.equal(Number(d.monthlyRevenue), 90000, 'revenue == collected (no discount)');
  // expected = 3 subs * 10A * 5000 = 150000; remaining = 150000 - 90000 - 20000.
  assert.equal(Number(d.totalDue), 40000, 'remaining subtracts collected AND the waived discount');
});

test('categoryPrices returns all three tariffs (gold/standard/commercial)', async () => {
  const r = await api('GET', `/api/account/stats?month=${MONTH}`, { token: owner.token });
  const d = dash(r.data);
  assert.ok(d.categoryPrices && typeof d.categoryPrices === 'object', 'categoryPrices present');
  assert.equal(Number(d.categoryPrices.gold), 7000);
  assert.equal(Number(d.categoryPrices.standard), 5000);
  assert.equal(Number(d.categoryPrices.commercial), 6000);
  // Back-compat single price still echoes the standard tariff.
  assert.equal(Number(d.pricePerAmp), 5000, 'pricePerAmp back-compat (standard)');
});
