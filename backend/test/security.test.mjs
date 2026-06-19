/**
 * Phase-1 security audit fixes (WS-SEC).
 *
 * Covers:
 *  - env.validateSecrets(): production boot FAILS FAST on a missing/placeholder
 *    JWT_SECRET or a missing/default ADMIN_PASSWORD; non-production only warns.
 *  - isSubscriptionActive / serializeSubscription: an 'active' subscription past
 *    its expiresAt is reported as 'expired' and stops granting plan features.
 *  - login is device-OPTIONAL (the browser web panel logs in without a device,
 *    so a missing device must not 400); when a device is sent, maxDevices is
 *    enforced. Accountants stay device-exempt.
 *  - an EXPIRED owner plan is reported inactive end-to-end via /api/auth/me and
 *    its sync feature is no longer forced on (features fall back to all-true,
 *    i.e. the plan's restrictions stop applying once expired).
 *
 * Boots a REAL Express server on an ephemeral port against in-memory MongoDB,
 * mirroring backend/test/api.test.mjs.
 *
 *   cd backend && npm test
 *
 * IMPORTANT: process.env MUST be configured before any backend module is
 * required, because src/config/env.js snapshots process.env at require time.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-security-test-'));
process.env.USE_MEMORY_DB = 'true';
process.env.NODE_ENV = 'test';
process.env.BACKUP_DIR = TMP_BACKUP_DIR;
process.env.JWT_SECRET = 'test-secret';
process.env.ADMIN_USERNAME = 'admin';
process.env.ADMIN_PASSWORD = 'admin123';

const { buildApp } = require('../src/server');
const { connectDb, disconnectDb } = require('../src/config/db');
const { runSeed } = require('../src/bootstrap/seed');
const env = require('../src/config/env');
const { isSubscriptionActive, serializeSubscription } = require('../src/utils/serialize');
const { featuresForUser } = require('../src/utils/planFeatures');
const User = require('../src/models/User');
const Plan = require('../src/models/Plan');

let server;
let baseUrl;

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
  const r = await api('POST', '/api/auth/register', {
    body: { name: 'Owner Name', phone: username, username, password, device },
  });
  assert.equal(r.status, 201, `register -> ${r.status} ${JSON.stringify(r.data)}`);
  return { token: r.data.token, account: r.data.account, username, password, device };
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

// ---------------------------------------------------------------------------
// env.validateSecrets() — production fail-fast.
// ---------------------------------------------------------------------------
test('validateSecrets THROWS in production with a placeholder JWT_SECRET / default admin pw', () => {
  const orig = { NODE_ENV: process.env.NODE_ENV, JWT_SECRET: process.env.JWT_SECRET, ADMIN_PASSWORD: process.env.ADMIN_PASSWORD };
  try {
    process.env.NODE_ENV = 'production';

    // Placeholder JWT secret + default admin pw -> throws.
    process.env.JWT_SECRET = env.DEFAULT_JWT_SECRET;
    process.env.ADMIN_PASSWORD = env.DEFAULT_ADMIN_PASSWORD;
    assert.throws(() => env.validateSecrets(), /production/i, 'must fail fast in production');

    // Missing JWT secret also throws.
    process.env.JWT_SECRET = '';
    process.env.ADMIN_PASSWORD = 'a-strong-admin-password';
    assert.throws(() => env.validateSecrets(), /JWT_SECRET/i, 'missing JWT_SECRET must throw');

    // Missing admin password also throws.
    process.env.JWT_SECRET = 'a-strong-unique-jwt-secret';
    process.env.ADMIN_PASSWORD = '';
    assert.throws(() => env.validateSecrets(), /ADMIN_PASSWORD/i, 'missing ADMIN_PASSWORD must throw');

    // Default admin pw alone still throws.
    process.env.ADMIN_PASSWORD = env.DEFAULT_ADMIN_PASSWORD;
    assert.throws(() => env.validateSecrets(), /ADMIN_PASSWORD/i);

    // Strong values -> no throw, no problems.
    process.env.JWT_SECRET = 'a-strong-unique-jwt-secret';
    process.env.ADMIN_PASSWORD = 'a-strong-admin-password';
    assert.deepEqual(env.validateSecrets(), [], 'strong secrets must pass');
  } finally {
    Object.assign(process.env, orig);
  }
});

test('validateSecrets only WARNS (never throws) outside production', () => {
  const orig = { NODE_ENV: process.env.NODE_ENV, JWT_SECRET: process.env.JWT_SECRET, ADMIN_PASSWORD: process.env.ADMIN_PASSWORD };
  try {
    process.env.NODE_ENV = 'development';
    process.env.JWT_SECRET = env.DEFAULT_JWT_SECRET;
    process.env.ADMIN_PASSWORD = env.DEFAULT_ADMIN_PASSWORD;
    let problems;
    assert.doesNotThrow(() => { problems = env.validateSecrets(); }, 'must not throw outside production');
    assert.equal(problems.length, 2, 'both insecure defaults are reported');
  } finally {
    Object.assign(process.env, orig);
  }
});

// ---------------------------------------------------------------------------
// Subscription expiry helper + serializer.
// ---------------------------------------------------------------------------
test('isSubscriptionActive enforces expiry; serializeSubscription downgrades to expired', () => {
  const past = new Date(Date.now() - 60_000);
  const future = new Date(Date.now() + 60_000);

  assert.equal(isSubscriptionActive({ status: 'active', expiresAt: future }), true);
  assert.equal(isSubscriptionActive({ status: 'active', expiresAt: past }), false, 'past expiry -> inactive');
  assert.equal(isSubscriptionActive({ status: 'active', expiresAt: null }), true, 'no expiry -> active');
  assert.equal(isSubscriptionActive({ status: 'pending', expiresAt: future }), false, 'non-active stays inactive');

  // Serializer reports 'expired' for an active-but-past plan, 'active' otherwise.
  assert.equal(serializeSubscription({ status: 'active', planCode: 'monthly', expiresAt: past }).status, 'expired');
  assert.equal(serializeSubscription({ status: 'active', planCode: 'monthly', expiresAt: future }).status, 'active');
  assert.equal(serializeSubscription({ status: 'pending', planCode: 'monthly', expiresAt: null }).status, 'pending');
});

test('featuresForUser stops applying an EXPIRED plan (restrictions lift -> all true)', async () => {
  await Plan.findOneAndUpdate(
    { code: 'sec-lite' },
    { code: 'sec-lite', name: 'Sec Lite', maxDevices: 1, syncEnabled: false, backupEnabled: false, ownerPanelEnabled: false },
    { upsert: true }
  );
  const past = new Date(Date.now() - 60_000);
  const future = new Date(Date.now() + 60_000);

  // Active + not expired -> the plan's restrictions apply (sync disabled).
  const activeFeatures = await featuresForUser({ subscription: { status: 'active', planCode: 'sec-lite', expiresAt: future } });
  assert.equal(activeFeatures.sync, false, 'live restricted plan disables sync');

  // Active + expired -> treated as no active plan, so every flag defaults true.
  const expiredFeatures = await featuresForUser({ subscription: { status: 'active', planCode: 'sec-lite', expiresAt: past } });
  assert.deepEqual(expiredFeatures, { sync: true, backup: true, ownerPanel: true, multiBranch: false });
});

// ---------------------------------------------------------------------------
// Login is device-OPTIONAL: the browser admin/owner web panel logs in without a
// device, so a missing device must NOT 400 (regression guard). When a device IS
// sent (the mobile app), it binds and maxDevices is enforced.
// ---------------------------------------------------------------------------
test('owner login WITHOUT a device -> 200 (web panel path), and WITH a device -> 200 + binds', async () => {
  const owner = await registerOwner();
  const noDev = await api('POST', '/api/auth/login', {
    body: { username: owner.username, password: owner.password }, // no device (web panel)
  });
  assert.equal(noDev.status, 200, `expected 200, got ${noDev.status} ${JSON.stringify(noDev.data)}`);
  assert.ok(noDev.data.token);

  const ok = await api('POST', '/api/auth/login', {
    body: { username: owner.username, password: owner.password, device: owner.device },
  });
  assert.equal(ok.status, 200);
});

test('admin login WITHOUT a device -> 200 (admin web panel must work)', async () => {
  const noDev = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'admin123' } });
  assert.equal(noDev.status, 200, `admin web login must not require a device, got ${noDev.status} ${JSON.stringify(noDev.data)}`);
  assert.equal(noDev.data.account.role, 'admin');
});

// ---------------------------------------------------------------------------
// Expired subscription is reported inactive end-to-end (/api/auth/me).
// ---------------------------------------------------------------------------
test('an EXPIRED owner plan is reported as "expired" via /api/auth/me', async () => {
  const owner = await registerOwner();

  // Force an active-but-expired subscription directly on the stored user.
  await User.findByIdAndUpdate(owner.account.id, {
    subscription: { status: 'active', planCode: 'monthly', startedAt: new Date(Date.now() - 86_400_000), expiresAt: new Date(Date.now() - 60_000) },
  });

  const me = await api('GET', '/api/auth/me', { token: owner.token });
  assert.equal(me.status, 200);
  assert.equal(me.data.account.subscription.status, 'expired', 'server downgrades the expired plan');
  // Features fall back to all-true once the plan is no longer in force.
  assert.equal(me.data.account.subscription.features.sync, true);
});
