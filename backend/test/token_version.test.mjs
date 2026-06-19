/**
 * Phase-2 token invalidation on password change (ITEM 2).
 *
 * A JWT carries the tokenVersion (tv) it was minted with. A password change
 * bumps user.tokenVersion, so every token issued before it is rejected by
 * requireAuth with 401 + code 'TOKEN_STALE'. A freshly issued token works.
 *
 * Exercised via the accountant password-change path (owner PUT
 * /api/account/accountants/:id with a new password), which is the live
 * password-CHANGE path in the backend.
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

const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-tokenver-test-'));
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
  return { token: r.data.token, account: r.data.account };
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

test('a freshly issued token works (baseline)', async () => {
  const owner = await registerOwner();
  const me = await api('GET', '/api/auth/me', { token: owner.token });
  assert.equal(me.status, 200, `me -> ${me.status} ${JSON.stringify(me.data)}`);
});

test('changing a password invalidates the previously-issued token (401 TOKEN_STALE), a new login works', async () => {
  const owner = await registerOwner();

  // Create an accountant and log it in to obtain a token.
  const uname = uniqueUsername('acct');
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: { name: 'Acct', username: uname, password: 'secret1', permissions: ['subscribers'] },
  });
  assert.equal(created.status, 201, `create acct -> ${created.status} ${JSON.stringify(created.data)}`);
  const acctId = created.data.accountant.id;

  const login1 = await api('POST', '/api/auth/login', { body: { username: uname, password: 'secret1' } });
  assert.equal(login1.status, 200);
  const oldToken = login1.data.token;

  // The old token works right now.
  let me = await api('GET', '/api/auth/me', { token: oldToken });
  assert.equal(me.status, 200, 'old token works before the password change');

  // Owner changes the accountant's password -> bumps tokenVersion.
  const upd = await api('PUT', `/api/account/accountants/${acctId}`, {
    token: owner.token,
    body: { password: 'newsecret2' },
  });
  assert.equal(upd.status, 200, `update -> ${upd.status} ${JSON.stringify(upd.data)}`);

  // The OLD token is now stale -> 401 TOKEN_STALE.
  me = await api('GET', '/api/auth/me', { token: oldToken });
  assert.equal(me.status, 401, `old token must be rejected, got ${me.status} ${JSON.stringify(me.data)}`);
  assert.equal(me.data.code, 'TOKEN_STALE');

  // A fresh login with the NEW password yields a working token.
  const login2 = await api('POST', '/api/auth/login', { body: { username: uname, password: 'newsecret2' } });
  assert.equal(login2.status, 200, `re-login -> ${login2.status} ${JSON.stringify(login2.data)}`);
  const me2 = await api('GET', '/api/auth/me', { token: login2.data.token });
  assert.equal(me2.status, 200, 'a freshly issued token works');
});
