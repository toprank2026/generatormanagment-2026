/**
 * Phase-2 maxDevices self-service recovery (ITEM 3).
 *
 * POST /api/auth/recover-device { username, password, device } (public,
 * rate-limited like login). For a maxDevices-locked OWNER who lost / replaced
 * their device: validates credentials, evicts the least-recently-seen device to
 * make room, binds the new one, and returns { token, account } like login.
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

const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-recover-test-'));
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

// Register a brand-new owner; with no active plan maxDevices defaults to 1, so a
// just-registered owner is already AT the limit with its single bound device.
async function registerOwner() {
  const username = uniqueUsername();
  const password = 'secret1';
  const device = makeDevice();
  const r = await api('POST', '/api/auth/register', { body: { name: 'Owner', phone: username, username, password, device } });
  assert.equal(r.status, 201, `register -> ${r.status} ${JSON.stringify(r.data)}`);
  return { token: r.data.token, account: r.data.account, username, password, device };
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

test('a maxDevices=1 owner AT the limit can recover-device with a NEW device -> 200 + working token', async () => {
  const owner = await registerOwner();

  // Sanity: a plain login with a NEW device would trip DEVICE_LIMIT (owner is
  // already at maxDevices=1 with the registered device).
  const newDevice = makeDevice();
  const blocked = await api('POST', '/api/auth/login', {
    body: { username: owner.username, password: owner.password, device: newDevice },
  });
  assert.equal(blocked.status, 403, `login with a new device should be DEVICE_LIMIT, got ${blocked.status} ${JSON.stringify(blocked.data)}`);
  assert.equal(blocked.data.code, 'DEVICE_LIMIT');

  // recover-device with the SAME new device evicts the old one and succeeds.
  const recover = await api('POST', '/api/auth/recover-device', {
    body: { username: owner.username, password: owner.password, device: newDevice },
  });
  assert.equal(recover.status, 200, `recover -> ${recover.status} ${JSON.stringify(recover.data)}`);
  assert.ok(recover.data.token, 'returns a token');
  assert.equal(recover.data.account.role, 'owner');
  // Old device evicted, new one bound: exactly one device, the new one, current.
  assert.equal(recover.data.account.devices.length, 1, 'least-recently-seen device evicted');
  assert.equal(recover.data.account.devices[0].deviceId, newDevice.deviceId);

  // The returned token works.
  const me = await api('GET', '/api/auth/me', { token: recover.data.token });
  assert.equal(me.status, 200, `recovered token must work, got ${me.status} ${JSON.stringify(me.data)}`);
});

test('recover-device with a BAD password -> 401', async () => {
  const owner = await registerOwner();
  const r = await api('POST', '/api/auth/recover-device', {
    body: { username: owner.username, password: 'wrong-password', device: makeDevice() },
  });
  assert.equal(r.status, 401, `bad password must be 401, got ${r.status} ${JSON.stringify(r.data)}`);
});
