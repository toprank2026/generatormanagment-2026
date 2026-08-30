'use strict';

const bcrypt = require('bcryptjs');
const mongoose = require('mongoose');
// v42 item 4: the 6-digit verification code the owner reads back to the super
// admin is generated with the CSPRNG — Math.random is predictable and would make
// a pending reset guessable.
const { randomInt } = require('node:crypto');
const User = require('../models/User');
const PasswordResetRequest = require('../models/PasswordResetRequest');
const asyncHandler = require('../utils/asyncHandler');
const { signToken } = require('../utils/token');
const { serializeAccount, serializeSubscription } = require('../utils/serialize');
const { featuresForUser } = require('../utils/planFeatures');
const { upsertDevice, sameDevice } = require('../utils/devices');
const { adminEvents } = require('../utils/events');
const { HttpError } = require('../middleware/error');

/**
 * Flash v42 — phone matching for the forgot-password identity check.
 *
 * The same Iraqi number is written many ways in practice: `07701234567`,
 * `+9647701234567`, `009647701234567`, `0770 123 4567`, `0770-123-4567`. A raw
 * string comparison locks a legitimate owner out of their own recovery whenever
 * the number was saved in a different shape from the one they type — and,
 * because the endpoint deliberately answers "account not found" for both halves
 * of the pair, the owner gets a message that looks like their details are simply
 * wrong. So both sides are normalised to the SUBSCRIBER number before comparing:
 * digits only, minus the 964 country code and any trunk 0.
 *
 * This is a formatting normalisation, NOT a loosening: the full subscriber
 * number must still match exactly, and a number that normalises to fewer than 8
 * digits is rejected outright so a short/garbage value can never collide.
 */
const samePhone = {
  normalize(v) {
    let d = String(v == null ? '' : v).replace(/\D+/g, '');
    if (!d) return '';
    if (d.startsWith('00964')) d = d.slice(5);
    else if (d.startsWith('964')) d = d.slice(3);
    while (d.startsWith('0')) d = d.slice(1);
    return d.length >= 8 ? d : '';
  },

  /**
   * A Mongo regex that finds the stored phone whatever separators it carries:
   * the normalised digits with `[^0-9]*` allowed between them, and an optional
   * country-code / trunk-0 prefix. Deliberately WIDE — it only narrows the
   * candidate set; `normalize()` then decides the actual match, so a loose hit
   * here can never become a false identification.
   */
  looseRegex(normalized) {
    const body = normalized.split('').join('[^0-9]*');
    return new RegExp(`^[^0-9]*(?:(?:00)?964)?[^0-9]*0?[^0-9]*${body}[^0-9]*$`);
  },
};

/** POST /api/auth/register (public) */
const register = asyncHandler(async (req, res) => {
  const { name, generatorName, phone, username, password, device } = req.body;

  const exists = await User.findOne({ username: String(username).toLowerCase() });
  if (exists) {
    throw new HttpError(409, 'Username already taken', 'USERNAME_TAKEN');
  }

  // Phone numbers are unique account identifiers too (the app signs up with
  // username == phone, but enforce it for any client / payload shape).
  if (phone) {
    const phoneTaken = await User.findOne({ phone: String(phone) });
    if (phoneTaken) {
      throw new HttpError(409, 'Phone number already registered', 'PHONE_TAKEN');
    }
  }

  const passwordHash = await bcrypt.hash(password, 10);
  const user = new User({
    name,
    generatorName: generatorName || null,
    phone: phone || null,
    username,
    passwordHash,
    role: 'owner',
    subscription: { status: 'none', planCode: null },
    devices: [],
  });

  // Bind the calling device (no active plan yet => limit 1, which the first
  // device always satisfies).
  if (device) await upsertDevice(user, device);
  await user.save();

  // Notify any connected admin panels in real time (SSE). Best-effort; never
  // blocks the registration response.
  adminEvents.emit('user_registered', {
    id: String(user._id),
    name: user.name,
    username: user.username,
    phone: user.phone || null,
    generatorName: user.generatorName || null,
    createdAt: user.createdAt,
  });

  const token = signToken(user);
  const account = serializeAccount(user, device && device.deviceId);
  account.subscription.features = await featuresForUser(user);
  res.status(201).json({ token, account });
});

/** POST /api/auth/login (public) */
const login = asyncHandler(async (req, res) => {
  const { username, password, device } = req.body;

  const user = await User.findOne({ username: String(username).toLowerCase() });
  if (!user) {
    throw new HttpError(401, 'Invalid username or password');
  }

  const ok = await bcrypt.compare(password, user.passwordHash);
  if (!ok) {
    throw new HttpError(401, 'Invalid username or password');
  }

  if (user.blocked) {
    throw new HttpError(403, 'Account blocked', 'BLOCKED');
  }

  if (user.role === 'accountant') {
    // Accountants are device-binding exempt (skip upsert/maxDevices entirely)
    // and inherit the OWNER's subscription/features. A blocked/missing owner
    // must reject the accountant too — the admin's block on an owner is the
    // whole-account kill switch (block is orthogonal to subscription.status).
    const owner = user.owner ? await User.findById(user.owner) : null;
    if (!owner || owner.blocked) {
      throw new HttpError(403, 'Account blocked', 'BLOCKED');
    }
    const token = signToken(user);
    const account = serializeAccount(user);
    // An accountant has no generatorName of its own; print receipts under the
    // OWNER's generator name (the Flutter receipt header reads account.generatorName).
    account.generatorName = owner.generatorName || null;
    // v30 F3: same for the owner's contact phone printed on receipts.
    account.contactPhone = owner.contactPhone || null;
    account.subscription = serializeSubscription(owner.subscription);
    account.subscription.features = await featuresForUser(owner);
    res.status(200).json({ token, account });
    return;
  }

  // A BRANCH sub-account (role:'owner' with parentOwner set) is ALWAYS
  // cascade-blocked by its parent top-level owner (a blocked/missing parent kills
  // the branch). It is still a full owner for its OWN data mirror, so device
  // binding below applies.
  //
  // Flash v13 Phase D: subscription/feature reporting splits on independentPlan:
  //  - independentPlan === true  => report its OWN subscription/features (so the
  //    branch is subscriptionBlocked / needs approval until the super-admin
  //    activates its plan, exactly like a freshly-registered owner).
  //  - independentPlan falsy (LEGACY) => INHERIT the parent's subscription/features
  //    (so the branch is never gated on its own empty subscription) — unchanged.
  let parent = null;
  let inheritParentPlan = false;
  if (user.parentOwner) {
    parent = await User.findById(user.parentOwner);
    if (!parent || parent.blocked) {
      throw new HttpError(403, 'Account blocked', 'BLOCKED');
    }
    inheritParentPlan = user.independentPlan !== true;
  }

  // Bind / validate the device WHEN PRESENT. The mobile app always sends one
  // (so maxDevices is enforced for every real app login); the browser admin /
  // owner panel logs in through this same endpoint WITHOUT a device, so we must
  // not hard-require it or the web panel is locked out. Throws 403 DEVICE_LIMIT
  // when a NEW device exceeds the active plan's maxDevices.
  // NOTE: omitting the device still yields a usable token — closing that
  // monetization bypass robustly requires per-device membership checks on the
  // DATA routes (sync/backup), tracked as a Phase-2 item, since it can't be
  // distinguished from a legit web-panel login here.
  if (device && typeof device === 'object') {
    await upsertDevice(user, device);
    await user.save();
  }

  const token = signToken(user);
  const account = serializeAccount(user, device && device.deviceId);
  // LEGACY branches report the PARENT's subscription/features (inherited);
  // INDEPENDENT branches and top-level owners report their OWN.
  if (inheritParentPlan && parent) {
    account.subscription = serializeSubscription(parent.subscription);
    account.subscription.features = await featuresForUser(parent);
  } else {
    account.subscription.features = await featuresForUser(user);
  }
  res.status(200).json({ token, account });
});

/**
 * POST /api/auth/recover-device (public, rate-limited like login)
 * Body: { username, password, device }
 *
 * Password-authenticated self-service for a user who lost / replaced their only
 * device and is locked out by maxDevices. Validates credentials (401 on bad),
 * then — to make room for the new device — EVICTS the owner's least-recently-seen
 * device (by lastSeen) before binding `device`, and returns a normal
 * { token, account } just like login. Owner role only: accountants are
 * device-exempt and admins are unrestricted, so neither needs recovery.
 */
const recoverDevice = asyncHandler(async (req, res) => {
  const { username, password, device } = req.body;

  if (!device || typeof device !== 'object' || !device.deviceId) {
    throw new HttpError(400, 'device.deviceId is required', 'VALIDATION');
  }

  const user = await User.findOne({ username: String(username).toLowerCase() });
  if (!user) {
    throw new HttpError(401, 'Invalid username or password');
  }

  const ok = await bcrypt.compare(password, user.passwordHash);
  if (!ok) {
    throw new HttpError(401, 'Invalid username or password');
  }

  if (user.blocked) {
    throw new HttpError(403, 'Account blocked', 'BLOCKED');
  }

  // Only owners are device-limited; accountants are exempt and admins
  // unrestricted, so device recovery is meaningless (and disallowed) for them.
  if (user.role !== 'owner') {
    throw new HttpError(403, 'Device recovery is only for owner accounts', 'RECOVERY_NOT_ALLOWED');
  }

  // If this physical device is already bound, upsertDevice will just refresh it
  // (no eviction needed). Otherwise free a slot first: evict the LEAST-recently
  // -seen device so a brand-new device always fits under maxDevices.
  const known = user.devices.some((d) => sameDevice(d, device));
  if (!known && user.devices.length > 0) {
    let lruIndex = 0;
    let lruTime = Infinity;
    user.devices.forEach((d, i) => {
      const t = d.lastSeen ? new Date(d.lastSeen).getTime() : 0;
      if (t < lruTime) {
        lruTime = t;
        lruIndex = i;
      }
    });
    user.devices.splice(lruIndex, 1);
  }

  // Bind the new device (room was made above, so this won't trip DEVICE_LIMIT)
  // and persist.
  await upsertDevice(user, device);
  await user.save();

  const token = signToken(user);
  const account = serializeAccount(user, device.deviceId);
  account.subscription.features = await featuresForUser(user);
  res.status(200).json({ token, account });
});

/** GET /api/auth/me (auth) */
const me = asyncHandler(async (req, res) => {
  const account = serializeAccount(req.user);

  if (req.user.role === 'accountant') {
    // Inherit the owner's subscription + features (see login). requireAuth has
    // already rejected a blocked/missing owner and attached req.ownerAccount.
    const owner =
      req.ownerAccount ||
      (req.user.owner ? await User.findById(req.user.owner) : null);
    if (!owner || owner.blocked) {
      throw new HttpError(403, 'Account blocked', 'BLOCKED');
    }
    // An accountant prints receipts under the OWNER's generator name (see login).
    account.generatorName = owner.generatorName || null;
    // v30 F3: same for the owner's contact phone printed on receipts.
    account.contactPhone = owner.contactPhone || null;
    account.subscription = serializeSubscription(owner.subscription);
    account.subscription.features = await featuresForUser(owner);
    res.status(200).json({ account });
    return;
  }

  // A BRANCH is cascade-blocked by its parent (requireAuth already rejected a
  // blocked/missing parent and attached req.parentAccount). Flash v13 Phase D:
  //  - LEGACY branch (independentPlan falsy) => INHERIT the parent's plan/features.
  //  - INDEPENDENT branch (independentPlan===true) => report its OWN plan/features
  //    (subscriptionBlocked until the super-admin activates it).
  if (req.user.parentOwner) {
    const parent =
      req.parentAccount ||
      (req.user.parentOwner ? await User.findById(req.user.parentOwner) : null);
    if (!parent || parent.blocked) {
      throw new HttpError(403, 'Account blocked', 'BLOCKED');
    }
    if (req.user.independentPlan === true) {
      account.subscription.features = await featuresForUser(req.user);
    } else {
      account.subscription = serializeSubscription(parent.subscription);
      account.subscription.features = await featuresForUser(parent);
    }
    res.status(200).json({ account });
    return;
  }

  account.subscription.features = await featuresForUser(req.user);
  res.status(200).json({ account });
});

/**
 * POST /api/auth/forgot-password (public, rate-limited like login)
 * Body: { username, phone, newPassword }
 *
 * Flash v42 item 4: super-admin-APPROVED password recovery. Nothing on the
 * account changes here — the requested password is stored bcrypt-hashed on a
 * PENDING request and only the super admin's approve (adminController) writes it
 * onto the user. The identity check is `username` + the account's REGISTERED
 * phone: both halves must match, and a mismatch on either always answers the
 * same 404 ACCOUNT_NOT_FOUND so this endpoint can neither enumerate accounts nor
 * confirm a known account's phone number.
 */
const forgotPassword = asyncHandler(async (req, res) => {
  const { username, phone, newPassword } = req.body;

  // v42 follow-up — the PHONE alone identifies the account. An owner who is
  // locked out should have exactly one thing to get right, and the phone is what
  // they are certain of. This is not a weakening of the flow: the phone only
  // FINDS the account and files a pending request; it grants nothing. The actual
  // identity check is still the super admin reading the 6-digit code back to the
  // caller before approving, and no password changes until they do.
  //
  // The stored value may be written any number of ways, so a candidate set is
  // pulled with a separator-tolerant regex and then confirmed by normalising
  // both sides (see samePhone).
  const givenPhone = samePhone.normalize(phone);
  const candidates = givenPhone
    ? await User.find({ phone: samePhone.looseRegex(givenPhone) })
    : [];
  // Owner/admin accounts only. An accountant's password is managed by its owner
  // in the app, so it must NOT be recoverable here.
  const matches = candidates.filter(
    (u) => u.role !== 'accountant' && samePhone.normalize(u.phone) === givenPhone
  );
  // Exactly one account must own the number. Zero = nothing to recover;
  // more than one = the number cannot identify anyone, so recovering "the first"
  // would be a coin flip on whose password changes. Both answer identically, so
  // the endpoint still reveals nothing about which case it was.
  const user = matches.length === 1 ? matches[0] : null;
  if (!user) {
    throw new HttpError(404, 'Account not found', 'ACCOUNT_NOT_FOUND');
  }
  // Backward-compat: an older APK still sends `username`. When present it must
  // ALSO match — an extra condition, never a substitute for the phone.
  if (username != null && String(username).trim() !== '') {
    if (String(username).trim().toLowerCase() !== String(user.username || '').toLowerCase()) {
      throw new HttpError(404, 'Account not found', 'ACCOUNT_NOT_FOUND');
    }
  }

  // The plaintext never leaves this request: it is hashed here (same cost factor
  // as register) and only the hash is persisted or logged.
  const newPasswordHash = await bcrypt.hash(newPassword, 10);

  // One active request per account: an older pending one is superseded so the
  // super admin can never be shown two approvable hashes for the same owner.
  await PasswordResetRequest.updateMany(
    { user: user._id, status: 'pending' },
    { $set: { status: 'expired' } }
  );

  const code = String(randomInt(0, 1000000)).padStart(6, '0');
  const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000);

  const request = await PasswordResetRequest.create({
    user: user._id,
    // Identity snapshot as submitted, so the admin list can search on it even if
    // the account is renamed before the decision (name/generatorName are not
    // snapshotted — the panel joins them from `user`).
    username: user.username,
    // As STORED (not the normalised comparison key): the super admin reads
    // this back to the owner, so it must look like the number they know.
    phone: user.phone || null,
    newPasswordHash,
    code,
    status: 'pending',
    expiresAt,
    // Abuse triage on this public route (no `trust proxy` here, so this is the
    // socket peer — indicative, never an identity check).
    ip: req.ip || null,
  });

  // Notify any connected admin panels in real time (SSE). Best-effort; never
  // blocks the response — exactly like register's 'user_registered'.
  adminEvents.emit('password_reset_requested', {
    id: String(request._id),
    userId: String(user._id),
    name: user.name,
    username: user.username,
    phone: user.phone || null,
    generatorName: user.generatorName || null,
    code,
    createdAt: request.createdAt,
  });

  res.status(201).json({
    requestId: String(request._id),
    code,
    status: request.status,
    expiresAt: request.expiresAt,
  });
});

/**
 * GET /api/auth/forgot-password/status?requestId=&code= (public, rate-limited)
 *
 * Flash v42 item 4: the app polls this while the owner waits for the super
 * admin's decision. requestId + code is the ONLY key (no session exists — the
 * owner is locked out by definition), so both must match; the pending password
 * hash is never part of the response.
 */
const forgotPasswordStatus = asyncHandler(async (req, res) => {
  const { requestId, code } = req.query;

  // A malformed id is attacker-supplied and says nothing about whether the
  // request exists, so it answers like an unknown one (404) instead of letting
  // Mongoose's CastError surface as a 400.
  const request = mongoose.isValidObjectId(requestId)
    ? await PasswordResetRequest.findOne({
        _id: requestId,
        code: String(code).trim(),
      })
    : null;
  if (!request) {
    throw new HttpError(404, 'Request not found', 'REQUEST_NOT_FOUND');
  }

  // Lazy expiry: a pending request past its 24h window reports AND persists
  // 'expired' on first read (the model's isExpired() is the single definition of
  // "past the window"), so a stale hash can no longer be approved even if nobody
  // polled in between.
  if (request.status === 'pending' && request.isExpired()) {
    request.status = 'expired';
    await request.save();
  }

  res.status(200).json({
    status: request.status,
    decidedAt: request.decidedAt || null,
    expiresAt: request.expiresAt,
  });
});

module.exports = {
  register,
  login,
  me,
  recoverDevice,
  forgotPassword,
  forgotPasswordStatus,
};
