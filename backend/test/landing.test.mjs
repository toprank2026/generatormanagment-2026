/**
 * Integration tests for Flash v15 landing features:
 *   - serializeSubscription.remainingDays (server-computed days left)
 *   - Admin banner CRUD (admin-auth required; image upload; enable/delete)
 *   - Promo video admin manage (singleton)
 *   - PUBLIC GET /api/public/landing (enabled banners + video provider detect)
 *
 * Boots a REAL Express server on an ephemeral port against an in-memory MongoDB
 * (USE_MEMORY_DB=true) with isolated temp BACKUP_DIR + UPLOADS_DIR, mirroring
 * the other suites (e.g. public_receipt.test.mjs).
 *
 *   cd backend && npm test
 *
 * IMPORTANT: process.env MUST be configured before any backend module is
 * required (src/config/env.js snapshots process.env at require time).
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

// ---------------------------------------------------------------------------
// Environment: configure BEFORE requiring the backend.
// ---------------------------------------------------------------------------
const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-landing-test-backups-'));
const TMP_UPLOADS_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-landing-test-uploads-'));

process.env.USE_MEMORY_DB = 'true';
process.env.NODE_ENV = 'test';
process.env.BACKUP_DIR = TMP_BACKUP_DIR;
process.env.UPLOADS_DIR = TMP_UPLOADS_DIR;
process.env.JWT_SECRET = 'test-secret';
process.env.ADMIN_USERNAME = 'admin';
process.env.ADMIN_PASSWORD = 'admin123';

const { buildApp } = require('../src/server');
const { connectDb, disconnectDb } = require('../src/config/db');
const { runSeed } = require('../src/bootstrap/seed');
const { serializeSubscription } = require('../src/utils/serialize');

// ---------------------------------------------------------------------------
// Shared state + helpers.
// ---------------------------------------------------------------------------
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
    osVersion: 'Android 13',
    ...overrides,
  };
}

let userCounter = 0;
function uniqueUsername(prefix = 'owner') {
  userCounter += 1;
  return `${prefix}${Date.now()}_${userCounter}`;
}

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
  if (ct.includes('application/json')) data = await res.json();
  return { status: res.status, data, res };
}

// A tiny valid 1x1 PNG as bytes (so multer's image fileFilter passes).
const PNG_1x1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64'
);

function bannerForm({ ratio, enabled, order, withImage = true } = {}) {
  const fd = new FormData();
  if (withImage) {
    fd.append('image', new Blob([PNG_1x1], { type: 'image/png' }), 'ad.png');
  }
  if (ratio !== undefined) fd.append('ratio', ratio);
  if (enabled !== undefined) fd.append('enabled', String(enabled));
  if (order !== undefined) fd.append('order', String(order));
  return fd;
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

async function registerOwner() {
  const username = uniqueUsername();
  const r = await api('POST', '/api/auth/register', {
    body: { name: 'Owner', phone: username, username, password: 'secret1', device: makeDevice() },
  });
  assert.equal(r.status, 201, `register should 201, got ${r.status} ${JSON.stringify(r.data)}`);
  return { token: r.data.token, account: r.data.account };
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
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  if (server) await new Promise((resolve) => server.close(resolve));
  await disconnectDb();
  for (const dir of [TMP_BACKUP_DIR, TMP_UPLOADS_DIR]) {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  }
});

// ===========================================================================
// TASK 1: serializeSubscription.remainingDays
// ===========================================================================
test('serializeSubscription: remainingDays null when no expiry', () => {
  const s = serializeSubscription({ planCode: 'monthly', status: 'pending' });
  assert.equal(s.remainingDays, null);
  // existing fields preserved
  assert.equal(s.planCode, 'monthly');
  assert.equal(s.status, 'pending');
  assert.equal(s.startedAt, null);
  assert.equal(s.expiresAt, null);
});

test('serializeSubscription: remainingDays counts whole days left (ceil)', () => {
  const exp = new Date(Date.now() + 10.2 * 86400000); // ~10.2 days out
  const s = serializeSubscription({ status: 'active', expiresAt: exp });
  assert.equal(s.remainingDays, 11); // ceil(10.2) => 11
  assert.equal(s.status, 'active');
});

test('serializeSubscription: remainingDays clamped to 0 once expired', () => {
  const exp = new Date(Date.now() - 5 * 86400000); // 5 days ago
  const s = serializeSubscription({ status: 'active', expiresAt: exp });
  assert.equal(s.remainingDays, 0);
  assert.equal(s.status, 'expired'); // active+past-expiry downgrades to expired
});

test('serializeSubscription: remainingDays null for unparseable expiry', () => {
  const s = serializeSubscription({ status: 'active', expiresAt: 'not-a-date' });
  assert.equal(s.remainingDays, null);
});

test('remainingDays flows through /auth/me + /api/subscription', async () => {
  const owner = await registerOwner();
  const me = await api('GET', '/api/auth/me', { token: owner.token });
  assert.equal(me.status, 200);
  assert.ok('remainingDays' in me.data.account.subscription);
  assert.equal(me.data.account.subscription.remainingDays, null); // fresh => no expiry

  const sub = await api('GET', '/api/subscription', { token: owner.token });
  assert.equal(sub.status, 200);
  assert.ok('remainingDays' in sub.data.subscription);
});

// ===========================================================================
// TASK 2/3: admin banner CRUD + video (auth required)
// ===========================================================================
test('banner endpoints require admin auth', async () => {
  const owner = await registerOwner();

  const noAuth = await api('GET', '/api/admin/banners');
  assert.equal(noAuth.status, 401);

  const asOwner = await api('GET', '/api/admin/banners', { token: owner.token });
  assert.equal(asOwner.status, 403); // owner is not admin
  assert.equal(asOwner.data.code, 'FORBIDDEN');

  const createNoAuth = await api('POST', '/api/admin/banners', { body: bannerForm() });
  assert.equal(createNoAuth.status, 401);
});

test('admin create + list + public read of a banner', async () => {
  const adminTok = await getAdminToken();

  const created = await api('POST', '/api/admin/banners', {
    token: adminTok,
    body: bannerForm({ ratio: '3:1', enabled: true, order: 1 }),
  });
  assert.equal(created.status, 201, JSON.stringify(created.data));
  const banner = created.data.banner;
  assert.ok(banner.id);
  assert.equal(banner.ratio, '3:1');
  assert.equal(banner.enabled, true);
  assert.equal(banner.order, 1);
  assert.ok(banner.imageUrl.startsWith('/uploads/'));

  // The uploaded file is served statically.
  const imgRes = await fetch(`${baseUrl}${banner.imageUrl}`);
  assert.equal(imgRes.status, 200);

  // Admin list contains it.
  const list = await api('GET', '/api/admin/banners', { token: adminTok });
  assert.equal(list.status, 200);
  assert.ok(list.data.banners.some((b) => b.id === banner.id));

  // Public landing exposes it (enabled) with the compact shape.
  const pub = await api('GET', '/api/public/landing');
  assert.equal(pub.status, 200);
  const pubBanner = pub.data.banners.find((b) => b.id === banner.id);
  assert.ok(pubBanner, 'enabled banner should appear in public landing');
  assert.equal(pubBanner.ratio, '3:1');
  assert.ok(pubBanner.imageUrl.startsWith('/uploads/'));
  // Public shape is whitelisted (no imagePath/createdAt).
  assert.deepEqual(Object.keys(pubBanner).sort(), ['id', 'imageUrl', 'order', 'ratio']);
});

test('create banner without an image -> 400 NO_FILE', async () => {
  const adminTok = await getAdminToken();
  const r = await api('POST', '/api/admin/banners', {
    token: adminTok,
    body: bannerForm({ withImage: false, ratio: '2:1' }),
  });
  assert.equal(r.status, 400);
  assert.equal(r.data.code, 'NO_FILE');
});

test('disabled banner is hidden from public but visible to admin', async () => {
  const adminTok = await getAdminToken();
  // Create then disable.
  const created = await api('POST', '/api/admin/banners', {
    token: adminTok,
    body: bannerForm({ ratio: '1:1', enabled: true }),
  });
  const id = created.data.banner.id;

  const upd = await api('PUT', `/api/admin/banners/${id}`, {
    token: adminTok,
    body: (() => {
      const fd = new FormData();
      fd.append('enabled', 'false');
      return fd;
    })(),
  });
  assert.equal(upd.status, 200);
  assert.equal(upd.data.banner.enabled, false);

  const pub = await api('GET', '/api/public/landing');
  assert.ok(!pub.data.banners.some((b) => b.id === id), 'disabled banner must not be public');

  const adminList = await api('GET', '/api/admin/banners', { token: adminTok });
  assert.ok(adminList.data.banners.some((b) => b.id === id), 'admin still sees disabled banner');
});

test('public banners are sorted by order ascending', async () => {
  const adminTok = await getAdminToken();
  const a = await api('POST', '/api/admin/banners', { token: adminTok, body: bannerForm({ order: 90, enabled: true }) });
  const b = await api('POST', '/api/admin/banners', { token: adminTok, body: bannerForm({ order: 5, enabled: true }) });
  const idLow = b.data.banner.id;
  const idHigh = a.data.banner.id;

  const pub = await api('GET', '/api/public/landing');
  const ids = pub.data.banners.map((x) => x.id);
  assert.ok(ids.indexOf(idLow) < ids.indexOf(idHigh), 'lower order should come first');
});

test('admin delete banner removes it from list + public', async () => {
  const adminTok = await getAdminToken();
  const created = await api('POST', '/api/admin/banners', { token: adminTok, body: bannerForm({ enabled: true }) });
  const id = created.data.banner.id;

  const del = await api('DELETE', `/api/admin/banners/${id}`, { token: adminTok });
  assert.equal(del.status, 200);
  assert.equal(del.data.ok, true);

  const list = await api('GET', '/api/admin/banners', { token: adminTok });
  assert.ok(!list.data.banners.some((x) => x.id === id));

  const del404 = await api('DELETE', `/api/admin/banners/${id}`, { token: adminTok });
  assert.equal(del404.status, 404);
  assert.equal(del404.data.code, 'BANNER_NOT_FOUND');
});

// ===========================================================================
// TASK 3: promo video singleton + provider detection
// ===========================================================================
test('landing video: admin set/get + public provider detection', async () => {
  const adminTok = await getAdminToken();

  // Default: disabled, empty url, null public video.
  const initial = await api('GET', '/api/admin/landing-video', { token: adminTok });
  assert.equal(initial.status, 200);
  assert.equal(initial.data.video.enabled, false);

  // Set a YouTube url.
  const setYt = await api('PUT', '/api/admin/landing-video', {
    token: adminTok,
    body: { url: 'https://youtu.be/abc123', enabled: true },
  });
  assert.equal(setYt.status, 200);
  assert.equal(setYt.data.video.url, 'https://youtu.be/abc123');
  assert.equal(setYt.data.video.enabled, true);

  let pub = await api('GET', '/api/public/landing');
  assert.equal(pub.data.video.provider, 'youtube');
  assert.equal(pub.data.video.url, 'https://youtu.be/abc123');

  // Vimeo.
  await api('PUT', '/api/admin/landing-video', { token: adminTok, body: { url: 'https://vimeo.com/76979871', enabled: true } });
  pub = await api('GET', '/api/public/landing');
  assert.equal(pub.data.video.provider, 'vimeo');

  // Direct file -> provider 'direct'.
  await api('PUT', '/api/admin/landing-video', { token: adminTok, body: { url: 'https://cdn.example.com/promo.mp4', enabled: true } });
  pub = await api('GET', '/api/public/landing');
  assert.equal(pub.data.video.provider, 'direct');

  // Empty url disables (public video => null).
  const cleared = await api('PUT', '/api/admin/landing-video', { token: adminTok, body: { url: '', enabled: true } });
  assert.equal(cleared.data.video.enabled, false);
  pub = await api('GET', '/api/public/landing');
  assert.equal(pub.data.video, null);
});

test('landing video endpoints require admin auth', async () => {
  const owner = await registerOwner();
  const noAuth = await api('GET', '/api/admin/landing-video');
  assert.equal(noAuth.status, 401);
  const asOwner = await api('PUT', '/api/admin/landing-video', { token: owner.token, body: { url: 'x', enabled: true } });
  assert.equal(asOwner.status, 403);
});

test('GET /api/public/landing is reachable without auth and well-shaped', async () => {
  const pub = await api('GET', '/api/public/landing');
  assert.equal(pub.status, 200);
  assert.ok(Array.isArray(pub.data.banners));
  assert.ok('video' in pub.data); // null or { url, provider }
});
