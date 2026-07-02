/**
 * Flash v23 (§10.2) — admin panel delete is now a TOMBSTONE, not a hard delete.
 * Proves: after delete the record is `deleted:true` with a fresh data.updated_at,
 * a pull carries the tombstone, and a STALE re-push (older data.updated_at) does
 * NOT resurrect it (last-EDIT-wins). A genuinely newer edit still revives it.
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

const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-tombstone-test-'));
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
let ownerId;
let adminTok;

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

const OLD = '2020-01-01T00:00:00.000Z'; // deliberately stale updated_at

test.before(async () => {
  await connectDb();
  await runSeed();
  const app = buildApp();
  await new Promise((resolve) => { server = app.listen(0, '127.0.0.1', resolve); });
  baseUrl = `http://127.0.0.1:${server.address().port}`;

  const username = `tombowner_${Date.now()}`;
  const reg = await api('POST', '/api/auth/register', {
    body: {
      name: 'Owner', phone: username, username, password: 'secret1',
      device: { installId: 'i-1', deviceId: 'd-1', platform: 'android', model: 'X', osVersion: 'A13' },
    },
  });
  assert.equal(reg.status, 201);
  owner = { token: reg.data.token };
  ownerId = reg.data.account.id;

  const adm = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'admin123' } });
  assert.equal(adm.status, 200);
  adminTok = adm.data.token;

  // Push a subscriber with a STALE updated_at.
  const push = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [{
        entity: 'subscribers', localId: 'sub-t', deleted: false, updatedAt: OLD,
        data: { id: 'sub-t', name: 'Target', amps: 5, category: 'standard', status: 'active', updated_at: OLD },
      }],
    },
  });
  assert.equal(push.status, 200);
});

test.after(async () => {
  if (server) await new Promise((resolve) => server.close(resolve));
  await disconnectDb();
  try { fs.rmSync(TMP_BACKUP_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
});

test('admin delete tombstones (deleted:true) instead of hard-deleting', async () => {
  const del = await api('DELETE', `/api/admin/users/${ownerId}/data/subscribers/sub-t`, { token: adminTok });
  assert.equal(del.status, 200, `-> ${del.status} ${JSON.stringify(del.data)}`);

  // Default list excludes it; includeDeleted shows it flagged deleted.
  const plain = await api('GET', `/api/admin/users/${ownerId}/data?entity=subscribers`, { token: adminTok });
  assert.ok(!plain.data.records.some((r) => r.localId === 'sub-t'), 'tombstone hidden from default list');
  const withDel = await api('GET', `/api/admin/users/${ownerId}/data?entity=subscribers&includeDeleted=true`, { token: adminTok });
  const row = withDel.data.records.find((r) => r.localId === 'sub-t');
  assert.ok(row, 'record still exists (not hard-deleted)');
  assert.equal(row.deleted, true, 'record is tombstoned');
});

test('a pull carries the tombstone so devices delete their local row', async () => {
  const pull = await api('GET', '/api/sync/pull', { token: owner.token });
  assert.equal(pull.status, 200, `-> ${pull.status} ${JSON.stringify(pull.data)}`);
  const recs = pull.data.records || pull.data;
  const row = (Array.isArray(recs) ? recs : []).find((r) => r.localId === 'sub-t' && r.entity === 'subscribers');
  assert.ok(row, 'tombstone present in the pull');
  assert.equal(row.deleted, true, 'pulled as a tombstone');
});

test('a STALE re-push does NOT resurrect the tombstoned record', async () => {
  const push = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [{
        entity: 'subscribers', localId: 'sub-t', deleted: false, updatedAt: OLD,
        data: { id: 'sub-t', name: 'Target', amps: 5, category: 'standard', status: 'active', updated_at: OLD },
      }],
    },
  });
  assert.equal(push.status, 200, 'push accepted (record counted, but skipped by LWW)');
  const withDel = await api('GET', `/api/admin/users/${ownerId}/data?entity=subscribers&includeDeleted=true`, { token: adminTok });
  const row = withDel.data.records.find((r) => r.localId === 'sub-t');
  assert.equal(row.deleted, true, 'stale edit loses to the newer tombstone — still deleted');
});

test('a genuinely NEWER edit does revive the record', async () => {
  const future = new Date(Date.now() + 60_000).toISOString();
  const push = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: {
      records: [{
        entity: 'subscribers', localId: 'sub-t', deleted: false, updatedAt: future,
        data: { id: 'sub-t', name: 'Target v2', amps: 6, category: 'standard', status: 'active', updated_at: future },
      }],
    },
  });
  assert.equal(push.status, 200);
  const plain = await api('GET', `/api/admin/users/${ownerId}/data?entity=subscribers`, { token: adminTok });
  const row = plain.data.records.find((r) => r.localId === 'sub-t');
  assert.ok(row, 'a newer edit revives the record');
  assert.equal(row.deleted, false);
  assert.equal(row.data.name, 'Target v2');
});
