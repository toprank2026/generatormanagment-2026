/**
 * Flash v23 (§3.2, §3.3) — password-change authorization.
 *
 *  - PUT /api/account/profile : changing your OWN password requires the CURRENT
 *    password (401 WRONG_PASSWORD otherwise; old clients omitting it also 401).
 *  - PUT /api/account/accountants/:id : resetting an accountant's password
 *    requires the OWNER's OWN password (401 WRONG_PASSWORD otherwise).
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

const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-password-auth-test-'));
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

const device = (id) => ({ installId: `i-${id}`, deviceId: `d-${id}`, platform: 'android', model: 'X', osVersion: 'A13' });

async function registerOwner() {
  const username = `pwowner_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
  const reg = await api('POST', '/api/auth/register', {
    body: { name: 'PW Owner', phone: username, username, password: 'orig-pass', device: device('o1') },
  });
  assert.equal(reg.status, 201, `register -> ${reg.status} ${JSON.stringify(reg.data)}`);
  return { token: reg.data.token, username };
}

test.before(async () => {
  await connectDb();
  await runSeed();
  const app = buildApp();
  await new Promise((resolve) => {
    server = app.listen(0, '127.0.0.1', resolve);
  });
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  if (server) await new Promise((resolve) => server.close(resolve));
  await disconnectDb();
  try { fs.rmSync(TMP_BACKUP_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
});

// ------------------------------------------------------------- self profile ---

test('profile password change with WRONG current password -> 401 WRONG_PASSWORD', async () => {
  const owner = await registerOwner();
  const r = await api('PUT', '/api/account/profile', {
    token: owner.token,
    body: { password: 'new-pass', currentPassword: 'not-my-pass' },
  });
  assert.equal(r.status, 401, `expected 401, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.code, 'WRONG_PASSWORD');
  // The old password must still work (nothing changed).
  const login = await api('POST', '/api/auth/login', {
    body: { username: owner.username, password: 'orig-pass', device: device('o1') },
  });
  assert.equal(login.status, 200, 'old password still valid after a rejected change');
});

test('profile password change WITHOUT current password -> 401 (old clients)', async () => {
  const owner = await registerOwner();
  const r = await api('PUT', '/api/account/profile', {
    token: owner.token,
    body: { password: 'new-pass' },
  });
  assert.equal(r.status, 401, `expected 401, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.code, 'WRONG_PASSWORD');
});

test('profile password change with CORRECT current password -> 200 + new password works', async () => {
  const owner = await registerOwner();
  const r = await api('PUT', '/api/account/profile', {
    token: owner.token,
    body: { password: 'brand-new', currentPassword: 'orig-pass' },
  });
  assert.equal(r.status, 200, `expected 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.ok(r.data.token, 'a fresh token is returned so the session survives');
  // New password works; old one is rejected.
  const good = await api('POST', '/api/auth/login', {
    body: { username: owner.username, password: 'brand-new', device: device('o1') },
  });
  assert.equal(good.status, 200, 'new password logs in');
  const bad = await api('POST', '/api/auth/login', {
    body: { username: owner.username, password: 'orig-pass', device: device('o1') },
  });
  assert.equal(bad.status, 401, 'old password no longer works');
});

// ------------------------------------------------------ accountant password ---

async function createAccountant(owner) {
  const uname = `acct_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: { name: 'Acct', username: uname, password: 'acct-orig', permissions: ['receipts'], localId: `al-${uname}` },
  });
  assert.equal(created.status, 201, `create acct -> ${created.status} ${JSON.stringify(created.data)}`);
  return { id: created.data.accountant.localId || created.data.accountant.id, username: uname };
}

test('accountant password reset with WRONG owner password -> 401 WRONG_PASSWORD', async () => {
  const owner = await registerOwner();
  const acct = await createAccountant(owner);
  const r = await api('PUT', `/api/account/accountants/${acct.id}`, {
    token: owner.token,
    body: { password: 'reset-pass', ownerPassword: 'wrong-owner-pass' },
  });
  assert.equal(r.status, 401, `expected 401, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.code, 'WRONG_PASSWORD');
  // Accountant's original password still works.
  const login = await api('POST', '/api/auth/login', {
    body: { username: acct.username, password: 'acct-orig' },
  });
  assert.equal(login.status, 200, 'accountant original password intact');
});

test('accountant password reset with CORRECT owner password -> 200 + accountant new password works', async () => {
  const owner = await registerOwner();
  const acct = await createAccountant(owner);
  const r = await api('PUT', `/api/account/accountants/${acct.id}`, {
    token: owner.token,
    body: { password: 'acct-new', ownerPassword: 'orig-pass' },
  });
  assert.equal(r.status, 200, `expected 200, got ${r.status} ${JSON.stringify(r.data)}`);
  const good = await api('POST', '/api/auth/login', {
    body: { username: acct.username, password: 'acct-new' },
  });
  assert.equal(good.status, 200, 'accountant logs in with the new password');
});

test('accountant NON-password edit needs no owner password', async () => {
  const owner = await registerOwner();
  const acct = await createAccountant(owner);
  const r = await api('PUT', `/api/account/accountants/${acct.id}`, {
    token: owner.token,
    body: { name: 'Renamed', permissions: ['receipts', 'expenses'] },
  });
  assert.equal(r.status, 200, `name/permission edit needs no challenge, got ${r.status} ${JSON.stringify(r.data)}`);
});
