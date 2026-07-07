'use strict';

const bcrypt = require('bcryptjs');
const User = require('../models/User');
const asyncHandler = require('../utils/asyncHandler');
const { signToken } = require('../utils/token');
const { serializeAccount, serializeSubscription } = require('../utils/serialize');
const { featuresForUser } = require('../utils/planFeatures');
const { upsertDevice, sameDevice } = require('../utils/devices');
const { adminEvents } = require('../utils/events');
const { HttpError } = require('../middleware/error');

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

module.exports = { register, login, me, recoverDevice };
