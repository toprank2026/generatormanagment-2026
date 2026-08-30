/**
 * Flash v42 item 4 — super-admin-approved "forgot password" for a generator owner.
 *
 * The whole point of the flow is that NOTHING changes on the account until a
 * super admin approves it in the panel, so these tests assert the negative side
 * as hard as the positive one: while a request is pending the OLD password must
 * still log in, a rejected/expired/superseded request must never be applied, and
 * an approve can never run twice over a password set after it.
 *
 * Surfaces under test (backend/API_CONTRACT.md):
 *  - POST /api/auth/forgot-password              -> 201 { requestId, code, status, expiresAt }
 *  - GET  /api/auth/forgot-password/status       -> 200 { status, decidedAt, expiresAt }
 *  - GET  /api/admin/password-resets             -> 200 { items, total, page, limit }  (admin)
 *  - POST /api/admin/password-resets/:id/approve -> 200 { ok, request }                (admin)
 *  - POST /api/admin/password-resets/:id/reject  -> 200 { ok, request }                (admin)
 *
 * Boots a REAL Express server on an ephemeral port against in-memory MongoDB,
 * mirroring backend/test/password_auth.test.mjs.
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

// Environment first: src/config/env.js snapshots process.env at require time.
const TMP_BACKUP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'moldati-v42-passwordreset-test-'));
process.env.USE_MEMORY_DB = 'true';
process.env.NODE_ENV = 'test';
process.env.BACKUP_DIR = TMP_BACKUP_DIR;
process.env.JWT_SECRET = 'test-secret';
process.env.ADMIN_USERNAME = 'admin';
process.env.ADMIN_PASSWORD = 'admin123';

const { buildApp } = require('../src/server');
const { connectDb, disconnectDb } = require('../src/config/db');
const { runSeed } = require('../src/bootstrap/seed');
// The model is used directly for the two things no HTTP surface can express:
// reading the stored hash back (to prove it is never serialized) and ageing a
// request past its 24 h window. Same idiom as backend/test/security.test.mjs.
const PasswordResetRequest = require('../src/models/PasswordResetRequest');
const User = require('../src/models/User');

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
    osVersion: 'Android 13 (SDK 33)',
    ...overrides,
  };
}

let userCounter = 0;
function uniqueUsername(prefix = 'fpowner') {
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
  const raw = ct.includes('application/json') ? await res.text() : '';
  return { status: res.status, data: raw ? JSON.parse(raw) : null, raw };
}

/**
 * A fresh owner with a DISTINCT username and phone, so a test that submits the
 * wrong phone is really testing the identity check (and not just a coincidence
 * of the app's username == phone convention).
 */
async function registerOwner(password = 'orig-pass') {
  const username = uniqueUsername();
  const phone = `0770${String(userCounter).padStart(7, '0')}`;
  const r = await api('POST', '/api/auth/register', {
    body: { name: 'FP Owner', generatorName: 'FP Generator', phone, username, password, device: makeDevice() },
  });
  assert.equal(r.status, 201, `register -> ${r.status} ${JSON.stringify(r.data)}`);
  return { token: r.data.token, id: r.data.account.id, username, phone, password };
}

// Admin login (seeded super admin). Cached after the first call.
let adminToken = null;
async function getAdminToken() {
  if (adminToken) return adminToken;
  const r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'admin123' } });
  assert.equal(r.status, 200, `admin login -> ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.account.role, 'admin');
  adminToken = r.data.token;
  return adminToken;
}

/** Login with no device: device binding is irrelevant here and maxDevices is 1 without a plan. */
const login = (username, password) => api('POST', '/api/auth/login', { body: { username, password } });

const requestReset = (username, phone, newPassword) =>
  api('POST', '/api/auth/forgot-password', { body: { username, phone, newPassword } });

const statusOf = (requestId, code) =>
  api('GET', `/api/auth/forgot-password/status?requestId=${encodeURIComponent(requestId)}&code=${encodeURIComponent(code)}`);

const approve = async (id) => api('POST', `/api/admin/password-resets/${id}/approve`, { token: await getAdminToken() });
const reject = async (id, note) =>
  api('POST', `/api/admin/password-resets/${id}/reject`, { token: await getAdminToken(), body: { note } });

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

// --------------------------------------------------------------- request ---

test('request with a matching username+phone -> 201 pending + 6-digit code, and the password is UNCHANGED while pending', async () => {
  const owner = await registerOwner();

  const r = await requestReset(owner.username, owner.phone, 'wanted-pass');
  assert.equal(r.status, 201, `forgot-password -> ${r.status} ${JSON.stringify(r.data)}`);
  assert.ok(r.data.requestId, 'a requestId is returned as the reference');
  assert.match(String(r.data.code), /^\d{6}$/, 'the verification code is exactly 6 digits');
  assert.equal(r.data.status, 'pending');
  const expiresAt = Date.parse(r.data.expiresAt);
  assert.ok(Number.isFinite(expiresAt) && expiresAt > Date.now(), 'expiresAt is a future timestamp');

  // THE guarantee: a pending request has not touched the account.
  const old = await login(owner.username, owner.password);
  assert.equal(old.status, 200, 'the OLD password still logs in while the request is pending');
  const early = await login(owner.username, 'wanted-pass');
  assert.equal(early.status, 401, 'the REQUESTED password does not work before approval');

  // …and the poll the app runs says so.
  const st = await statusOf(r.data.requestId, r.data.code);
  assert.equal(st.status, 200, `status -> ${st.status} ${JSON.stringify(st.data)}`);
  assert.equal(st.data.status, 'pending');
  assert.equal(st.data.decidedAt, null, 'nothing has been decided yet');
});

test('wrong phone and unknown username answer the SAME 404 ACCOUNT_NOT_FOUND (no enumeration)', async () => {
  const owner = await registerOwner();

  const wrongPhone = await requestReset(owner.username, '07000000000', 'wanted-pass');
  assert.equal(wrongPhone.status, 404, `wrong phone -> ${wrongPhone.status} ${JSON.stringify(wrongPhone.data)}`);
  assert.equal(wrongPhone.data.code, 'ACCOUNT_NOT_FOUND');

  const unknownUser = await requestReset(uniqueUsername('nobody'), owner.phone, 'wanted-pass');
  assert.equal(unknownUser.status, 404, `unknown username -> ${unknownUser.status} ${JSON.stringify(unknownUser.data)}`);
  assert.equal(unknownUser.data.code, 'ACCOUNT_NOT_FOUND');

  // Byte-identical bodies: nothing distinguishes "that account exists but the
  // phone is wrong" from "no such account".
  assert.deepEqual(wrongPhone.data, unknownUser.data, 'the two rejections must be indistinguishable');

  // A rejected identity check must not park a request for that account either.
  const parked = await PasswordResetRequest.countDocuments({ user: owner.id });
  assert.equal(parked, 0, 'a failed identity check creates no request row');
});

test('an accountant password is not recoverable here -> the same 404 ACCOUNT_NOT_FOUND', async () => {
  const owner = await registerOwner();
  const acctPhone = `0771${String(userCounter).padStart(7, '0')}`;
  const created = await api('POST', '/api/account/accountants', {
    token: owner.token,
    body: { name: 'Acct', phone: acctPhone, password: 'secret1', permissions: ['subscribers'] },
  });
  assert.equal(created.status, 201, `create accountant -> ${created.status} ${JSON.stringify(created.data)}`);

  // Username == phone for a v-current accountant, so the identity check would
  // otherwise MATCH — only the role rejection stands between it and a reset an
  // owner is supposed to perform in the app.
  const r = await requestReset(acctPhone, acctPhone, 'wanted-pass');
  assert.equal(r.status, 404, `accountant reset -> ${r.status} ${JSON.stringify(r.data)}`);
  assert.equal(r.data.code, 'ACCOUNT_NOT_FOUND');
});

test('the status poll 404s on a wrong code (the reference cannot be guessed off a requestId)', async () => {
  const owner = await registerOwner();
  const r = await requestReset(owner.username, owner.phone, 'wanted-pass');
  assert.equal(r.status, 201);

  const wrong = String((Number(r.data.code) + 1) % 1000000).padStart(6, '0');
  const bad = await statusOf(r.data.requestId, wrong);
  assert.equal(bad.status, 404, `wrong code -> ${bad.status} ${JSON.stringify(bad.data)}`);
  assert.equal(bad.data.code, 'REQUEST_NOT_FOUND');

  // The right code still works — the row was not disturbed by the bad poll.
  const good = await statusOf(r.data.requestId, r.data.code);
  assert.equal(good.status, 200);
  assert.equal(good.data.status, 'pending');
});

// ------------------------------------------------------------- admin list ---

test('the admin list shows the request (code included) and NEVER leaks newPasswordHash', async () => {
  const owner = await registerOwner();
  const r = await requestReset(owner.username, owner.phone, 'wanted-pass');
  assert.equal(r.status, 201);

  const list = await api('GET', `/api/admin/password-resets?q=${encodeURIComponent(owner.username)}`, {
    token: await getAdminToken(),
  });
  assert.equal(list.status, 200, `list -> ${list.status} ${JSON.stringify(list.data)}`);
  assert.equal(list.data.page, 1);
  assert.ok(list.data.total >= 1, 'the request is findable by username');

  const item = list.data.items.find((i) => i.id === r.data.requestId);
  assert.ok(item, 'the new request is on the first page (newest first)');
  assert.equal(item.userId, owner.id);
  assert.equal(item.username, owner.username.toLowerCase());
  assert.equal(item.phone, owner.phone);
  assert.equal(item.name, 'FP Owner');
  assert.equal(item.generatorName, 'FP Generator');
  // The 6-digit reference the owner reads back over the phone IS the admin's
  // primary lookup, so it must be present and identical to the app's copy.
  assert.equal(item.code, r.data.code);
  assert.equal(item.status, 'pending');
  assert.equal(item.decidedAt, null);
  assert.ok(item.createdAt && item.expiresAt);

  // The requested password only ever exists as a bcrypt hash, and that hash must
  // not reach the panel: assert on the RAW body, not just the parsed keys.
  const stored = await PasswordResetRequest.findById(r.data.requestId).lean();
  assert.ok(stored.newPasswordHash && stored.newPasswordHash.startsWith('$2'), 'stored bcrypt-hashed');
  assert.equal(Object.prototype.hasOwnProperty.call(item, 'newPasswordHash'), false);
  assert.equal(list.raw.includes(stored.newPasswordHash), false, 'the hash never appears in the response body');
  assert.equal(list.raw.includes('wanted-pass'), false, 'the plaintext never appears anywhere');

  // The queue is super-admin only.
  const asOwner = await api('GET', '/api/admin/password-resets', { token: owner.token });
  assert.equal(asOwner.status, 403, `owner must not read the queue, got ${asOwner.status}`);
  assert.equal(asOwner.data.code, 'FORBIDDEN');
});

// ---------------------------------------------------------------- approve ---

test('approve -> the NEW password logs in, the OLD one does not, and a pre-approval JWT is rejected', async () => {
  const owner = await registerOwner();
  const r = await requestReset(owner.username, owner.phone, 'approved-pass');
  assert.equal(r.status, 201);

  // The token minted at registration works right up to the decision.
  let me = await api('GET', '/api/auth/me', { token: owner.token });
  assert.equal(me.status, 200, 'the pre-approval token works before the decision');

  const dec = await approve(r.data.requestId);
  assert.equal(dec.status, 200, `approve -> ${dec.status} ${JSON.stringify(dec.data)}`);
  assert.equal(dec.data.ok, true);
  assert.equal(dec.data.request.status, 'approved');
  assert.ok(dec.data.request.decidedAt, 'the decision is timestamped');

  // Approval bumps tokenVersion: whoever held the account before the reset is
  // signed out everywhere (this is what makes the recovery safe).
  me = await api('GET', '/api/auth/me', { token: owner.token });
  assert.equal(me.status, 401, `the old JWT must be rejected, got ${me.status} ${JSON.stringify(me.data)}`);
  assert.equal(me.data.code, 'TOKEN_STALE');

  const good = await login(owner.username, 'approved-pass');
  assert.equal(good.status, 200, 'the approved password logs in');
  const bad = await login(owner.username, owner.password);
  assert.equal(bad.status, 401, 'the old password no longer logs in');

  const st = await statusOf(r.data.requestId, r.data.code);
  assert.equal(st.data.status, 'approved', 'the app poll sees the approval');
  assert.ok(st.data.decidedAt);
});

test('approving twice is a 409 no-op — the stored hash can never be applied a second time', async () => {
  const owner = await registerOwner();
  const r = await requestReset(owner.username, owner.phone, 'once-pass');
  assert.equal(r.status, 201);
  assert.equal((await approve(r.data.requestId)).status, 200);

  // The owner recovers, then changes the password themselves. A second approve
  // must NOT resurrect the reset hash over this newer password.
  const signedIn = await login(owner.username, 'once-pass');
  assert.equal(signedIn.status, 200);
  const changed = await api('PUT', '/api/account/profile', {
    token: signedIn.data.token,
    body: { password: 'third-pass', currentPassword: 'once-pass' },
  });
  assert.equal(changed.status, 200, `self password change -> ${changed.status} ${JSON.stringify(changed.data)}`);

  const again = await approve(r.data.requestId);
  assert.equal(again.status, 409, `second approve -> ${again.status} ${JSON.stringify(again.data)}`);
  assert.equal(again.data.code, 'RESET_NOT_PENDING');

  assert.equal((await login(owner.username, 'third-pass')).status, 200, 'the newest password still stands');
  assert.equal((await login(owner.username, 'once-pass')).status, 401, 'the reset hash was not re-applied');
});

// ----------------------------------------------------------------- reject ---

test('reject -> the password is unchanged and the request records why', async () => {
  const owner = await registerOwner();
  const r = await requestReset(owner.username, owner.phone, 'never-pass');
  assert.equal(r.status, 201);

  const dec = await reject(r.data.requestId, 'caller could not confirm identity');
  assert.equal(dec.status, 200, `reject -> ${dec.status} ${JSON.stringify(dec.data)}`);
  assert.equal(dec.data.ok, true);
  assert.equal(dec.data.request.status, 'rejected');
  assert.equal(dec.data.request.note, 'caller could not confirm identity');
  assert.ok(dec.data.request.decidedAt);

  // A rejection changes NOTHING on the account.
  assert.equal((await login(owner.username, owner.password)).status, 200, 'the old password still logs in');
  assert.equal((await login(owner.username, 'never-pass')).status, 401, 'the requested password never took effect');
  assert.equal((await api('GET', '/api/auth/me', { token: owner.token })).status, 200, 'existing sessions survive a rejection');

  const st = await statusOf(r.data.requestId, r.data.code);
  assert.equal(st.data.status, 'rejected');

  // …and a rejected request can never be approved afterwards.
  const late = await approve(r.data.requestId);
  assert.equal(late.status, 409, `approve after reject -> ${late.status} ${JSON.stringify(late.data)}`);
  assert.equal(late.data.code, 'RESET_NOT_PENDING');
  assert.equal((await login(owner.username, 'never-pass')).status, 401, 'still not applied');
});

// ------------------------------------------------------ supersede / expiry ---

test('a second request supersedes the first pending one (only one approvable hash per account)', async () => {
  const owner = await registerOwner();
  const first = await requestReset(owner.username, owner.phone, 'first-pass');
  assert.equal(first.status, 201);
  const second = await requestReset(owner.username, owner.phone, 'second-pass');
  assert.equal(second.status, 201);
  assert.notEqual(second.data.requestId, first.data.requestId);

  // The superseded one is retired, so the admin is never shown two approvable
  // hashes for the same owner.
  const stFirst = await statusOf(first.data.requestId, first.data.code);
  assert.equal(stFirst.data.status, 'expired', 'the older pending request is superseded');
  const stSecond = await statusOf(second.data.requestId, second.data.code);
  assert.equal(stSecond.data.status, 'pending');

  const stale = await approve(first.data.requestId);
  assert.equal(stale.status, 409, `approving the superseded request -> ${stale.status} ${JSON.stringify(stale.data)}`);
  assert.equal(stale.data.code, 'RESET_NOT_PENDING');
  assert.equal((await login(owner.username, 'first-pass')).status, 401, 'the superseded password was never applied');

  assert.equal((await approve(second.data.requestId)).status, 200);
  assert.equal((await login(owner.username, 'second-pass')).status, 200, 'the newest request is the one that applies');
  assert.equal((await login(owner.username, 'first-pass')).status, 401);
});

test('an expired request cannot be approved and reports "expired"', async () => {
  const owner = await registerOwner();
  const r = await requestReset(owner.username, owner.phone, 'too-late-pass');
  assert.equal(r.status, 201);

  // Age it past its 24 h window (nothing sweeps the collection; expiry is lazy,
  // evaluated when the request is read or decided).
  await PasswordResetRequest.updateOne(
    { _id: r.data.requestId },
    { $set: { expiresAt: new Date(Date.now() - 60 * 1000) } }
  );

  const dec = await approve(r.data.requestId);
  assert.equal(dec.status, 409, `approve expired -> ${dec.status} ${JSON.stringify(dec.data)}`);
  assert.equal(dec.data.code, 'RESET_EXPIRED');

  // The refusal also PERSISTS the lapse, so the app's poll agrees and the hash
  // can never be approved later.
  const stored = await PasswordResetRequest.findById(r.data.requestId).lean();
  assert.equal(stored.status, 'expired');
  const st = await statusOf(r.data.requestId, r.data.code);
  assert.equal(st.data.status, 'expired');

  assert.equal((await login(owner.username, owner.password)).status, 200, 'the account is untouched');
  assert.equal((await login(owner.username, 'too-late-pass')).status, 401);

  // Sanity: the owner is still a normal, unblocked account (nothing else moved).
  const still = await User.findById(owner.id).lean();
  assert.equal(still.blocked, false);
});
