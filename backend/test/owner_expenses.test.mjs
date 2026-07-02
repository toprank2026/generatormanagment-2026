/**
 * Flash v23 (§7) — owner-panel expenses filtering via GET /api/account/data
 * (delegates to listUserData): month prefix filter, accountant filter incl.
 * `__none__` (owner-created expenses), and the aggregate `totalAmount`.
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

const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-owner-expenses-test-'));
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

const rec = (entity, localId, data) => ({
  entity, localId, deleted: false, updatedAt: new Date().toISOString(), data,
});

test.before(async () => {
  await connectDb();
  await runSeed();
  const app = buildApp();
  await new Promise((resolve) => { server = app.listen(0, '127.0.0.1', resolve); });
  baseUrl = `http://127.0.0.1:${server.address().port}`;

  const username = `expowner_${Date.now()}`;
  const reg = await api('POST', '/api/auth/register', {
    body: {
      name: 'Owner', phone: username, username, password: 'secret1',
      device: { installId: 'i-1', deviceId: 'd-1', platform: 'android', model: 'X', osVersion: 'A13' },
    },
  });
  assert.equal(reg.status, 201, `register -> ${reg.status} ${JSON.stringify(reg.data)}`);
  owner = { token: reg.data.token };

  // June: owner expense 10000 (accountant_id null), accountant A expense 20000.
  // July: accountant A expense 5000.
  const push = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [
        rec('expenses', 'e-owner-jun', { id: 'e-owner-jun', category: 'Fuel', amount: 10000, accountant_id: null, date: '2026-06-05T00:00:00.000Z' }),
        rec('expenses', 'e-a-jun', { id: 'e-a-jun', category: 'Oil', amount: 20000, accountant_id: 'acct-A', date: '2026-06-10T00:00:00.000Z' }),
        rec('expenses', 'e-a-jul', { id: 'e-a-jul', category: 'Other', amount: 5000, accountant_id: 'acct-A', date: '2026-07-02T00:00:00.000Z' }),
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

test('month filter returns only that month\'s expenses + a matching totalAmount', async () => {
  const r = await api('GET', '/api/account/data?entity=expenses&month=2026-06', { token: owner.token });
  assert.equal(r.status, 200, `-> ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.total, 2, 'June has two expenses');
  assert.equal(Number(r.data.totalAmount), 30000, 'totalAmount sums June (10000 + 20000)');
  const jul = await api('GET', '/api/account/data?entity=expenses&month=2026-07', { token: owner.token });
  assert.equal(jul.data.total, 1);
  assert.equal(Number(jul.data.totalAmount), 5000);
});

test('accountant filter (relValue) narrows to one collector', async () => {
  const r = await api('GET', '/api/account/data?entity=expenses&relField=accountant_id&relValue=acct-A', { token: owner.token });
  assert.equal(r.status, 200);
  assert.equal(r.data.total, 2, 'accountant A has two expenses (June + July)');
  assert.equal(Number(r.data.totalAmount), 25000);
});

test('relValue=__none__ selects only owner-created (null accountant) expenses', async () => {
  const r = await api('GET', '/api/account/data?entity=expenses&relField=accountant_id&relValue=__none__', { token: owner.token });
  assert.equal(r.status, 200);
  assert.equal(r.data.total, 1, 'only the owner expense has a null accountant');
  assert.equal(r.data.records[0].localId, 'e-owner-jun');
  assert.equal(Number(r.data.totalAmount), 10000);
});

test('month + accountant filters compose', async () => {
  const r = await api('GET', '/api/account/data?entity=expenses&month=2026-06&relField=accountant_id&relValue=acct-A', { token: owner.token });
  assert.equal(r.status, 200);
  assert.equal(r.data.total, 1, 'accountant A has one June expense');
  assert.equal(Number(r.data.totalAmount), 20000);
});

test('totalAmount over the whole (unfiltered) expenses set', async () => {
  const r = await api('GET', '/api/account/data?entity=expenses', { token: owner.token });
  assert.equal(Number(r.data.totalAmount), 35000, '10000 + 20000 + 5000');
});
