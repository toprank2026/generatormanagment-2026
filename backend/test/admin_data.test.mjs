/**
 * Integration tests for the admin per-entity "synced data" view:
 * server-side SEARCH + PAGINATION + DELETE on the read-only mirror.
 *
 * Mirrors backend/test/sync.test.mjs + api.test.mjs: boots a REAL Express
 * server on an ephemeral port against an in-memory MongoDB (USE_MEMORY_DB=true)
 * and an isolated temp BACKUP_DIR, so the suite is hermetic.
 *
 *   cd backend && npm test
 *
 * IMPORTANT: process.env MUST be configured before any backend module is
 * required, because src/config/env.js snapshots process.env at require time.
 *
 * Contract under test:
 *  - GET /api/admin/users/:id/data?entity=E&q=<text>&page=<1-based>&limit=<n>[&includeDeleted=true]
 *      -> { entity, records:[{localId,data,deleted,updatedAt}], total, page, limit }
 *      (q filters BEFORE pagination; total = matching count; sort updatedAt desc;
 *       page default 1, limit default 25 clamped to 1..200; excludes deleted)
 *  - DELETE /api/admin/users/:id/data/:entity/:localId -> { ok: true } (404 if missing)
 *  - Both routes are admin-only (owner -> 403 FORBIDDEN).
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';

// The backend is CommonJS; load it through createRequire from this ESM file.
const require = createRequire(import.meta.url);

// ---------------------------------------------------------------------------
// Environment: configure BEFORE requiring the backend (env.js caches on load).
// ---------------------------------------------------------------------------
const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-admindata-test-backups-'));

process.env.USE_MEMORY_DB = 'true';
process.env.NODE_ENV = 'test';
process.env.BACKUP_DIR = TMP_BACKUP_DIR;
process.env.JWT_SECRET = 'test-secret';
process.env.ADMIN_USERNAME = 'admin';
process.env.ADMIN_PASSWORD = 'admin123';

// Now safe to require the app + supporting modules.
const { buildApp } = require('../src/server');
const { connectDb, disconnectDb } = require('../src/config/db');
const { runSeed } = require('../src/bootstrap/seed');

// ---------------------------------------------------------------------------
// Shared state.
// ---------------------------------------------------------------------------
let server; // http.Server
let baseUrl; // e.g. http://127.0.0.1:54321

let deviceCounter = 0;
function makeDevice(overrides = {}) {
  deviceCounter += 1;
  return {
    installId: `install-${deviceCounter}`,
    deviceId: `device-${deviceCounter}`,
    platform: 'android',
    model: 'SM-TEST',
    brand: 'samsung',
    osVersion: 'Android 13 (SDK 33)',
    ...overrides,
  };
}

let userCounter = 0;
function uniqueUsername(prefix = 'owner') {
  userCounter += 1;
  return `${prefix}${Date.now()}_${userCounter}`;
}

// Small fetch wrapper that resolves the base URL + parses JSON when present.
async function api(method, urlPath, { token, body, headers } = {}) {
  const h = { ...(headers || {}) };
  if (token) h.Authorization = `Bearer ${token}`;
  let payload = body;
  if (body !== undefined && !(body instanceof FormData)) {
    h['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  const res = await fetch(`${baseUrl}${urlPath}`, { method, headers: h, body: payload });
  const ct = res.headers.get('content-type') || '';
  let data = null;
  if (ct.includes('application/json')) {
    data = await res.json();
  } else {
    data = await res.arrayBuffer();
  }
  return { status: res.status, data, res };
}

// Register a brand-new owner; returns { token, account, username, password, device }.
async function registerOwner(deviceOverrides) {
  const username = uniqueUsername();
  const password = 'secret1';
  const device = makeDevice(deviceOverrides);
  const r = await api('POST', '/api/auth/register', {
    body: { name: 'Owner Name', phone: '0770', username, password, device },
  });
  assert.equal(r.status, 201, `register should 201, got ${r.status} ${JSON.stringify(r.data)}`);
  return { token: r.data.token, account: r.data.account, username, password, device };
}

// Admin login (seeded admin). Cached after first call.
let adminToken = null;
async function getAdminToken() {
  if (adminToken) return adminToken;
  const r = await api('POST', '/api/auth/login', {
    body: { username: 'admin', password: 'admin123', device: makeDevice() },
  });
  assert.equal(r.status, 200, `admin login should 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.account.role, 'admin');
  adminToken = r.data.token;
  return adminToken;
}

// ---------------------------------------------------------------------------
// Seed data: ~30 subscriber records with varied names/phones.
// ---------------------------------------------------------------------------
const SUBSCRIBER_COUNT = 30;

// A spread of names; some share a common substring ("Ali") so q-filtering has
// a deterministic, > 1 expected match.
const NAMES = [
  'Ahmed Ali',
  'Mohamed Ali',
  'Ali Hassan',
  'Sara Mahmoud',
  'Omar Khaled',
  'Yousef Tarek',
  'Layla Nabil',
  'Hassan Adel',
  'Nour Samir',
  'Khaled Fathy',
  'Mariam Sayed',
  'Tarek Magdy',
  'Salma Ezz',
  'Mostafa Gamal',
  'Heba Fawzy',
  'Amr Diab',
  'Dina Lotfy',
  'Karim Wael',
  'Rana Sherif',
  'Sherif Helmy',
  'Mona Ashraf',
  'Ashraf Zaki',
  'Walid Saad',
  'Hoda Mansour',
  'Bassem Aziz',
  'Nada Ragab',
  'Fady Nashaat',
  'Ghada Sami',
  'Hany Labib',
  'Iman Shawky',
];

// Build the full push body (no tombstones — all live records).
function makeSubscriberRecords() {
  const base = Date.now();
  const records = [];
  for (let i = 0; i < SUBSCRIBER_COUNT; i += 1) {
    const localId = `sub-${i}`;
    records.push({
      entity: 'subscribers',
      localId,
      deleted: false,
      // Stagger updatedAt so the desc sort is deterministic (newest = highest i).
      updatedAt: new Date(base + i * 1000).toISOString(),
      data: {
        id: localId,
        name: NAMES[i],
        phone: `0770${String(100000 + i)}`,
        amps: 5 + (i % 10),
        board_id: 'board-1',
        circuit_id: 'circuit-1',
        status: 'active',
      },
    });
  }
  return records;
}

// Push the given records in one POST and assert success.
async function pushRecords(token, records) {
  const r = await api('POST', '/api/sync/push', { token, body: { records } });
  assert.equal(r.status, 200, `push should 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.ok, true);
  assert.equal(r.data.count, records.length);
  return r;
}

// Register a fresh owner and push the standard 30 subscribers.
async function seededOwner() {
  const owner = await registerOwner();
  await pushRecords(owner.token, makeSubscriberRecords());
  return owner;
}

// ---------------------------------------------------------------------------
// Boot / teardown.
// ---------------------------------------------------------------------------
test.before(async () => {
  await connectDb();
  await runSeed();
  const app = buildApp();
  await new Promise((resolve) => {
    server = app.listen(0, '127.0.0.1', resolve);
  });
  const { port } = server.address();
  baseUrl = `http://127.0.0.1:${port}`;
});

test.after(async () => {
  if (server) {
    await new Promise((resolve) => server.close(resolve));
  }
  await disconnectDb();
  try {
    fs.rmSync(TMP_BACKUP_DIR, { recursive: true, force: true });
  } catch {
    /* ignore */
  }
});

// ---------------------------------------------------------------------------
// Pagination
// ---------------------------------------------------------------------------
test('paginated data: page=1&limit=10 -> 10 records, total=30, page=1, limit=10', async () => {
  const owner = await seededOwner();
  const adminTok = await getAdminToken();

  const r = await api(
    'GET',
    `/api/admin/users/${owner.account.id}/data?entity=subscribers&page=1&limit=10`,
    { token: adminTok }
  );
  assert.equal(r.status, 200, `should 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.entity, 'subscribers');
  assert.ok(Array.isArray(r.data.records));
  assert.equal(r.data.records.length, 10);
  assert.equal(r.data.total, SUBSCRIBER_COUNT);
  assert.equal(r.data.page, 1);
  assert.equal(r.data.limit, 10);

  // Records carry the expected shape.
  const first = r.data.records[0];
  assert.equal(typeof first.localId, 'string');
  assert.equal(first.deleted, false);
  assert.equal(typeof first.updatedAt, 'string');
  assert.equal(typeof first.data.name, 'string');
});

test('pagination walks pages: page 1/2/3 are disjoint and cover all 30; page 4 is empty', async () => {
  const owner = await seededOwner();
  const adminTok = await getAdminToken();

  async function fetchPage(page) {
    const r = await api(
      'GET',
      `/api/admin/users/${owner.account.id}/data?entity=subscribers&page=${page}&limit=10`,
      { token: adminTok }
    );
    assert.equal(r.status, 200);
    assert.equal(r.data.total, SUBSCRIBER_COUNT);
    assert.equal(r.data.page, page);
    assert.equal(r.data.limit, 10);
    return r.data.records;
  }

  const p1 = await fetchPage(1);
  const p2 = await fetchPage(2);
  const p3 = await fetchPage(3);
  const p4 = await fetchPage(4);

  assert.equal(p1.length, 10);
  assert.equal(p2.length, 10);
  assert.equal(p3.length, 10);
  assert.equal(p4.length, 0, 'page 4 must be the empty remainder');

  // Pages must be disjoint and together cover every localId exactly once.
  const ids = [...p1, ...p2, ...p3].map((rec) => rec.localId);
  const uniq = new Set(ids);
  assert.equal(uniq.size, SUBSCRIBER_COUNT, 'pages 1-3 must cover 30 distinct records');

  // page 2 is the "next 10" after page 1 (no overlap).
  const p1Ids = new Set(p1.map((rec) => rec.localId));
  for (const rec of p2) {
    assert.ok(!p1Ids.has(rec.localId), `page 2 record ${rec.localId} must not appear on page 1`);
  }
});

test('sort is updatedAt desc (newest first)', async () => {
  const owner = await seededOwner();
  const adminTok = await getAdminToken();

  const r = await api(
    'GET',
    `/api/admin/users/${owner.account.id}/data?entity=subscribers&page=1&limit=30`,
    { token: adminTok }
  );
  assert.equal(r.status, 200);
  assert.equal(r.data.records.length, SUBSCRIBER_COUNT);

  const times = r.data.records.map((rec) => new Date(rec.updatedAt).getTime());
  for (let i = 1; i < times.length; i += 1) {
    assert.ok(times[i - 1] >= times[i], 'records must be sorted updatedAt descending');
  }
});

// ---------------------------------------------------------------------------
// Search (q)
// ---------------------------------------------------------------------------
test('q filters by name substring (case-insensitive); total reflects filtered count', async () => {
  const owner = await seededOwner();
  const adminTok = await getAdminToken();

  // "ali" is a substring of several seeded names (e.g. "Ali Hassan", "Walid Saad").
  const expectedMatches = NAMES.filter((n) => n.toLowerCase().includes('ali'));
  assert.ok(expectedMatches.length >= 3, 'sanity: seeded names contain "ali"');

  const r = await api(
    'GET',
    `/api/admin/users/${owner.account.id}/data?entity=subscribers&q=ali&page=1&limit=25`,
    { token: adminTok }
  );
  assert.equal(r.status, 200, `should 200, got ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.total, expectedMatches.length, 'total = count of records matching q');
  assert.equal(r.data.records.length, expectedMatches.length);

  // Every returned record actually matches q (case-insensitive) on name or phone.
  for (const rec of r.data.records) {
    const name = String(rec.data.name || '').toLowerCase();
    const phone = String(rec.data.phone || '').toLowerCase();
    assert.ok(
      name.includes('ali') || phone.includes('ali'),
      `record ${rec.localId} (${rec.data.name}) must match q="ali"`
    );
  }
});

test('q filters by phone substring', async () => {
  const owner = await seededOwner();
  const adminTok = await getAdminToken();

  // sub-7 has phone "0770100007"; "100007" is unique to it.
  const r = await api(
    'GET',
    `/api/admin/users/${owner.account.id}/data?entity=subscribers&q=100007`,
    { token: adminTok }
  );
  assert.equal(r.status, 200);
  assert.equal(r.data.total, 1, 'exactly one phone contains "100007"');
  assert.equal(r.data.records.length, 1);
  assert.equal(r.data.records[0].localId, 'sub-7');
  assert.equal(r.data.records[0].data.phone, '0770100007');
});

test('q applied BEFORE pagination: filtered set is paged, total is the filtered count', async () => {
  const owner = await seededOwner();
  const adminTok = await getAdminToken();

  // All seeded phones share the "0770" prefix -> q="0770" matches all 30.
  const page1 = await api(
    'GET',
    `/api/admin/users/${owner.account.id}/data?entity=subscribers&q=0770&page=1&limit=10`,
    { token: adminTok }
  );
  assert.equal(page1.status, 200);
  assert.equal(page1.data.total, SUBSCRIBER_COUNT, 'q="0770" matches all 30');
  assert.equal(page1.data.records.length, 10, 'filtered set is still paged to limit');
  assert.equal(page1.data.page, 1);
  assert.equal(page1.data.limit, 10);
});

test('q with no matches -> empty records, total 0', async () => {
  const owner = await seededOwner();
  const adminTok = await getAdminToken();

  const r = await api(
    'GET',
    `/api/admin/users/${owner.account.id}/data?entity=subscribers&q=zzzz-no-such-name`,
    { token: adminTok }
  );
  assert.equal(r.status, 200);
  assert.equal(r.data.total, 0);
  assert.equal(r.data.records.length, 0);
});

// ---------------------------------------------------------------------------
// Delete
// ---------------------------------------------------------------------------
test('DELETE one record -> { ok: true }; total drops by 1 and the localId is gone', async () => {
  const owner = await seededOwner();
  const adminTok = await getAdminToken();

  const targetId = 'sub-5';

  // Confirm it exists first.
  const before = await api(
    'GET',
    `/api/admin/users/${owner.account.id}/data?entity=subscribers&page=1&limit=200`,
    { token: adminTok }
  );
  assert.equal(before.status, 200);
  assert.equal(before.data.total, SUBSCRIBER_COUNT);
  assert.ok(before.data.records.some((rec) => rec.localId === targetId), 'target must exist pre-delete');

  // Delete it.
  const del = await api(
    'DELETE',
    `/api/admin/users/${owner.account.id}/data/subscribers/${targetId}`,
    { token: adminTok }
  );
  assert.equal(del.status, 200, `delete should 200, got ${del.status} ${JSON.stringify(del.data)}`);
  assert.equal(del.data.ok, true);

  // Total dropped by 1 and the localId is gone.
  const after = await api(
    'GET',
    `/api/admin/users/${owner.account.id}/data?entity=subscribers&page=1&limit=200`,
    { token: adminTok }
  );
  assert.equal(after.status, 200);
  assert.equal(after.data.total, SUBSCRIBER_COUNT - 1, 'total must decrease by exactly 1');
  assert.ok(!after.data.records.some((rec) => rec.localId === targetId), 'deleted localId must be gone');
});

test('DELETE a missing record -> 404', async () => {
  const owner = await seededOwner();
  const adminTok = await getAdminToken();

  const del = await api(
    'DELETE',
    `/api/admin/users/${owner.account.id}/data/subscribers/does-not-exist`,
    { token: adminTok }
  );
  assert.equal(del.status, 404, `missing record delete should 404, got ${del.status} ${JSON.stringify(del.data)}`);
});

// ---------------------------------------------------------------------------
// Authorization: owner (non-admin) is forbidden on both routes
// ---------------------------------------------------------------------------
test('owner hitting the admin data (GET) route -> 403 FORBIDDEN', async () => {
  const owner = await seededOwner();

  const r = await api(
    'GET',
    `/api/admin/users/${owner.account.id}/data?entity=subscribers&page=1&limit=10`,
    { token: owner.token }
  );
  assert.equal(r.status, 403);
  assert.equal(r.data.code, 'FORBIDDEN');
});

test('owner hitting the admin data DELETE route -> 403 FORBIDDEN (record survives)', async () => {
  const owner = await seededOwner();
  const adminTok = await getAdminToken();

  const targetId = 'sub-3';
  const del = await api(
    'DELETE',
    `/api/admin/users/${owner.account.id}/data/subscribers/${targetId}`,
    { token: owner.token }
  );
  assert.equal(del.status, 403);
  assert.equal(del.data.code, 'FORBIDDEN');

  // The record must still be there (admin verifies).
  const after = await api(
    'GET',
    `/api/admin/users/${owner.account.id}/data?entity=subscribers&page=1&limit=200`,
    { token: adminTok }
  );
  assert.equal(after.status, 200);
  assert.equal(after.data.total, SUBSCRIBER_COUNT, 'forbidden delete must not remove anything');
  assert.ok(after.data.records.some((rec) => rec.localId === targetId), 'target must survive a 403 delete');
});
