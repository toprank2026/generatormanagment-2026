/**
 * Integration tests for the SAME-DEVICE (reinstall-safe) login fix.
 *
 * Mirrors backend/test/sync.test.mjs: boots a REAL Express server on an
 * ephemeral port against an in-memory MongoDB (USE_MEMORY_DB=true) and an
 * isolated temp BACKUP_DIR, so the suite is hermetic.
 *
 *   cd backend && npm test
 *
 * IMPORTANT: process.env MUST be configured before any backend module is
 * required, because src/config/env.js snapshots process.env at require time.
 *
 * Behaviour under test (utils/devices.js `sameDevice`), exercised via the
 * public HTTP API only:
 *  - The OS-stable `deviceId` identifies a physical handset. A reinstall /
 *    data-clear changes the app-generated `installId` but keeps `deviceId`, so
 *    logging in again with the SAME `deviceId` + a DIFFERENT `installId` is the
 *    SAME device (refresh the binding) — it must NOT trip DEVICE_LIMIT and must
 *    NOT add a second device.
 *  - A genuinely DIFFERENT `deviceId` is a new handset and, on the default
 *    (no active plan => maxDevices 1) limit, must be rejected 403 DEVICE_LIMIT.
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
const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-device-test-backups-'));

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
// Same-device (reinstall-safe) login — utils/devices.js sameDevice()
// ---------------------------------------------------------------------------
test('reinstall on the same handset (same deviceId, new installId) -> 200 and stays at 1 device', async () => {
  const username = uniqueUsername();
  const password = 'secret1';

  // Register on a handset 'dev-A' (no active plan => maxDevices 1).
  const reg = await api('POST', '/api/auth/register', {
    body: {
      name: 'Owner Name',
      phone: username,
      username,
      password,
      device: { deviceId: 'dev-A', installId: 'install-1', platform: 'android' },
    },
  });
  assert.equal(reg.status, 201, `register should 201, got ${reg.status} ${JSON.stringify(reg.data)}`);
  assert.ok(Array.isArray(reg.data.account.devices));
  assert.equal(reg.data.account.devices.length, 1, 'register binds exactly one device');

  // Reinstall / data-clear: SAME deviceId, DIFFERENT installId.
  const login = await api('POST', '/api/auth/login', {
    body: {
      username,
      password,
      device: { deviceId: 'dev-A', installId: 'install-2', platform: 'android' },
    },
  });
  assert.equal(
    login.status,
    200,
    `same-handset reinstall login should 200, got ${login.status} ${JSON.stringify(login.data)}`
  );

  // Still exactly one device — recognised as the same handset, binding refreshed.
  const devices = login.data.account.devices;
  assert.ok(Array.isArray(devices));
  assert.equal(devices.length, 1, 'same handset must NOT add a second device on reinstall');

  // The single device keeps deviceId 'dev-A' and its installId is refreshed.
  const dev = devices.find((d) => d.deviceId === 'dev-A');
  assert.ok(dev, 'the bound device must still be dev-A');
  assert.equal(dev.installId, 'install-2', 'reinstall refreshes the installId on the same handset');
});

test('GET /api/device?current=<id> marks the caller\'s own device (v23 §4.3)', async () => {
  const username = uniqueUsername();
  const reg = await api('POST', '/api/auth/register', {
    body: {
      name: 'Owner Name',
      phone: username,
      username,
      password: 'secret1',
      device: { deviceId: 'dev-A', installId: 'install-1', platform: 'android' },
    },
  });
  assert.equal(reg.status, 201, `register -> ${reg.status} ${JSON.stringify(reg.data)}`);
  const token = reg.data.token;

  // With current=dev-A the row is flagged current.
  const withCurrent = await api('GET', '/api/device?current=dev-A', { token });
  assert.equal(withCurrent.status, 200);
  const devA = withCurrent.data.devices.find((d) => d.deviceId === 'dev-A');
  assert.ok(devA, 'dev-A present');
  assert.equal(devA.current, true, 'dev-A is flagged current when it matches ?current');

  // With a non-matching current (or none) the row is NOT current (old behavior).
  const otherCurrent = await api('GET', '/api/device?current=dev-Z', { token });
  assert.equal(otherCurrent.data.devices.find((d) => d.deviceId === 'dev-A').current, false);
  const noCurrent = await api('GET', '/api/device', { token });
  assert.equal(noCurrent.data.devices.find((d) => d.deviceId === 'dev-A').current, false);
});

test('login from a DIFFERENT handset (new deviceId) -> 403 DEVICE_LIMIT', async () => {
  const username = uniqueUsername();
  const password = 'secret1';

  const reg = await api('POST', '/api/auth/register', {
    body: {
      name: 'Owner Name',
      phone: username,
      username,
      password,
      device: { deviceId: 'dev-A', installId: 'install-1', platform: 'android' },
    },
  });
  assert.equal(reg.status, 201, `register should 201, got ${reg.status} ${JSON.stringify(reg.data)}`);
  assert.equal(reg.data.account.devices.length, 1);

  // A genuinely different handset: different deviceId AND installId. With the
  // default (no active plan => 1) limit this is a second device -> rejected.
  const login = await api('POST', '/api/auth/login', {
    body: {
      username,
      password,
      device: { deviceId: 'dev-B', installId: 'install-3', platform: 'android' },
    },
  });
  assert.equal(
    login.status,
    403,
    `different handset should 403, got ${login.status} ${JSON.stringify(login.data)}`
  );
  assert.equal(login.data.code, 'DEVICE_LIMIT');
});
