/**
 * Flash v23 (§2.1, §2.2) — owner-panel dashboard `expected` + unpriced-month rule.
 *
 *   GET /api/account/stats?month=M  (buildDashboard)
 *
 * Proves:
 *  1. The payload now returns a CATEGORY-AWARE `expected` (Σ amps × price[cat]),
 *     which differs from the old totalAmps × pricePerAmp(standard) on a
 *     mixed-tariff account — so the panel's "expected" card is correct.
 *  2. A month with NO price rows counts every subscriber UNPAID (paidCount === 0),
 *     matching the app (previously the backend counted them PAID because due=0).
 *
 * Boots a REAL Express server on an ephemeral port against in-memory MongoDB,
 * mirroring backend/test/discount_stats.test.mjs.
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

const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-report-expected-test-'));
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

const MONTH = '2026-06'; // priced (mixed tariffs)
const UNPRICED = '2026-07'; // no price rows at all

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

  const username = `expowner_${Date.now()}`;
  const reg = await api('POST', '/api/auth/register', {
    body: {
      name: 'Expected Owner',
      phone: username,
      username,
      password: 'secret1',
      device: { installId: 'i-1', deviceId: 'd-1', platform: 'android', model: 'X', osVersion: 'A13' },
    },
  });
  assert.equal(reg.status, 201, `register -> ${reg.status} ${JSON.stringify(reg.data)}`);
  owner = { token: reg.data.token };

  // MONTH prices: gold 7000, standard 5000, commercial 6000 (all differ).
  // Subscribers: gold 10A, standard 20A, commercial 5A.
  //   category-aware expected = 10*7000 + 20*5000 + 5*6000 = 200000.
  //   naive totalAmps(35) * pricePerAmp(standard 5000) = 175000  (WRONG).
  const push = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [
        rec('monthly_prices', `${MONTH}|gold`, { month: MONTH, category: 'gold', price_per_amp: 7000 }),
        rec('monthly_prices', `${MONTH}|standard`, { month: MONTH, category: 'standard', price_per_amp: 5000 }),
        rec('monthly_prices', `${MONTH}|commercial`, { month: MONTH, category: 'commercial', price_per_amp: 6000 }),

        rec('subscribers', 'sub-g', { id: 'sub-g', name: 'Gold', amps: 10, category: 'gold', status: 'active' }),
        rec('subscribers', 'sub-s', { id: 'sub-s', name: 'Std', amps: 20, category: 'standard', status: 'active' }),
        rec('subscribers', 'sub-c', { id: 'sub-c', name: 'Com', amps: 5, category: 'commercial', status: 'active' }),
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

test('payload returns a category-aware `expected` (mixed tariffs)', async () => {
  const r = await api('GET', `/api/account/stats?month=${MONTH}`, { token: owner.token });
  assert.equal(r.status, 200, `stats -> ${r.status} ${JSON.stringify(r.data)}`);
  const d = dash(r.data);
  assert.equal(Number(d.expected), 200000, 'expected = Σ amps × price[category]');
  // The old naive computation the SPA used to do would be wrong here:
  assert.notEqual(
    Number(d.totalAmps) * Number(d.pricePerAmp),
    Number(d.expected),
    'category-aware expected differs from totalAmps × standard price',
  );
});

test('unpriced month counts every subscriber UNPAID (paidCount === 0)', async () => {
  const r = await api('GET', `/api/account/stats?month=${UNPRICED}`, { token: owner.token });
  assert.equal(r.status, 200, `stats -> ${r.status} ${JSON.stringify(r.data)}`);
  const d = dash(r.data);
  assert.equal(Number(d.paidCount), 0, 'no price rows → nobody counts paid');
  assert.equal(Number(d.unpaidCount), 3, 'all subscribers count unpaid');
  assert.equal(Number(d.expected), 0, 'no prices → expected is 0');
});
