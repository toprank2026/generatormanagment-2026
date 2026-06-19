/**
 * Phase-2 conflict resolution: server-side last-EDIT-wins + sticky tombstones
 * on POST /api/sync/push (ITEM 1).
 *
 * The client stamps each business row's REAL edit time into data.updated_at.
 * push() now:
 *  (a) SKIPS a stale upsert (older data.updated_at) so it cannot clobber a newer
 *      stored row — but still counts it as applied so the device drains its outbox;
 *  (b) APPLIES a newer upsert (overwrites);
 *  (c) STICKY TOMBSTONE: after a delete, a stale-edit upsert stays deleted but a
 *      newer-edit upsert revives the row;
 *  (d) BACK-COMP: rows with NO data.updated_at still apply (old behavior).
 *
 * Boots a REAL Express server on an ephemeral port against in-memory MongoDB,
 * mirroring backend/test/sync.test.mjs.
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

const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-lww-test-'));
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

// Push one subscriber upsert carrying a per-row edit time (data.updated_at).
async function pushUpsert(token, localId, name, editIso) {
  return api('POST', '/api/sync/push', {
    token,
    body: {
      records: [
        {
          entity: 'subscribers',
          localId,
          deleted: false,
          updatedAt: new Date().toISOString(),
          data: { id: localId, name, amps: 10, status: 'active', updated_at: editIso },
        },
      ],
    },
  });
}

// A delete carries no data; its tombstone edit time is taken from the envelope
// updatedAt. Pass `deleteIso` so the sticky-tombstone comparison is deterministic.
async function pushDelete(token, localId, deleteIso) {
  return api('POST', '/api/sync/push', {
    token,
    body: {
      records: [{ entity: 'subscribers', localId, deleted: true, updatedAt: deleteIso || new Date().toISOString() }],
    },
  });
}

async function pullRow(token, localId) {
  const r = await api('GET', '/api/sync/pull?since=1970-01-01T00:00:00.000Z', { token });
  return r.data.records.find((rec) => rec.localId === localId);
}

const T_OLD = '2026-01-01T00:00:00.000Z';
const T_MID = '2026-06-01T00:00:00.000Z';
const T_NEW = '2026-12-01T00:00:00.000Z';

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

// (a) stale upsert does NOT overwrite a newer stored row.
test('stale upsert (older data.updated_at) does NOT overwrite a newer stored row', async () => {
  const owner = await registerOwner();

  // Store the NEW edit first.
  let r = await pushUpsert(owner.token, 'lww-a', 'New Name', T_NEW);
  assert.equal(r.status, 200);

  // A stale device pushes an OLDER edit for the same row.
  r = await pushUpsert(owner.token, 'lww-a', 'Stale Name', T_OLD);
  assert.equal(r.status, 200);
  assert.equal(r.data.count, 1, 'stale skip is still counted so the device drains its outbox');

  const row = await pullRow(owner.token, 'lww-a');
  assert.ok(row, 'row exists');
  assert.equal(row.data.name, 'New Name', 'stale edit must NOT clobber the newer stored value');
});

// (b) newer upsert DOES overwrite.
test('newer upsert (newer data.updated_at) DOES overwrite the stored row', async () => {
  const owner = await registerOwner();

  let r = await pushUpsert(owner.token, 'lww-b', 'Old Name', T_OLD);
  assert.equal(r.status, 200);

  r = await pushUpsert(owner.token, 'lww-b', 'Newer Name', T_NEW);
  assert.equal(r.status, 200);

  const row = await pullRow(owner.token, 'lww-b');
  assert.equal(row.data.name, 'Newer Name', 'newer edit overwrites');
});

// (c) sticky tombstone: stale edit stays deleted, newer edit revives.
test('after a delete, a STALE-edit upsert stays deleted; a NEWER-edit upsert revives', async () => {
  const owner = await registerOwner();

  // Seed, then delete at a known tombstone time (T_MID).
  let r = await pushUpsert(owner.token, 'lww-c', 'Seed', T_OLD);
  assert.equal(r.status, 200);
  r = await pushDelete(owner.token, 'lww-c', T_MID);
  assert.equal(r.status, 200);

  let row = await pullRow(owner.token, 'lww-c');
  assert.equal(row.deleted, true, 'row is tombstoned after delete');

  // A device that missed the delete pushes a STALE edit -> must stay deleted.
  r = await pushUpsert(owner.token, 'lww-c', 'Resurrect Stale', T_OLD);
  assert.equal(r.status, 200);
  assert.equal(r.data.count, 1, 'sticky-tombstone skip is still counted');
  row = await pullRow(owner.token, 'lww-c');
  assert.equal(row.deleted, true, 'stale edit must NOT resurrect a deleted row (sticky tombstone)');

  // A genuinely NEWER edit (after the delete time) revives the row.
  r = await pushUpsert(owner.token, 'lww-c', 'Revived', T_NEW);
  assert.equal(r.status, 200);
  row = await pullRow(owner.token, 'lww-c');
  assert.equal(row.deleted, false, 'a newer edit revives the row');
  assert.equal(row.data.name, 'Revived');
});

// (d) back-comp: rows with NO data.updated_at still apply.
test('rows with NO data.updated_at still apply (backward compatible)', async () => {
  const owner = await registerOwner();

  // First push WITHOUT any updated_at.
  let r = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: { records: [{ entity: 'subscribers', localId: 'lww-d', deleted: false, updatedAt: new Date().toISOString(), data: { id: 'lww-d', name: 'First', amps: 1, status: 'active' } }] },
  });
  assert.equal(r.status, 200);

  // Second push WITHOUT updated_at -> apply-always (old behavior).
  r = await api('POST', '/api/sync/push', {
    token: owner.token,
    body: { records: [{ entity: 'subscribers', localId: 'lww-d', deleted: false, updatedAt: new Date().toISOString(), data: { id: 'lww-d', name: 'Second', amps: 2, status: 'active' } }] },
  });
  assert.equal(r.status, 200);

  let row = await pullRow(owner.token, 'lww-d');
  assert.equal(row.data.name, 'Second', 'untimestamped rows still apply (last write wins by push order)');

  // Mixed: a stored row WITHOUT updated_at, incoming WITH updated_at -> applies
  // (back-comp: when either side lacks an edit time we fall through and apply).
  r = await pushUpsert(owner.token, 'lww-d', 'Third', T_OLD);
  assert.equal(r.status, 200);
  row = await pullRow(owner.token, 'lww-d');
  assert.equal(row.data.name, 'Third', 'incoming with edit time applies over a stored row that had none');
});
