'use strict';

const bcrypt = require('bcryptjs');
const User = require('../models/User');
const asyncHandler = require('../utils/asyncHandler');
const { signToken } = require('../utils/token');
const { serializeAccount } = require('../utils/serialize');
const { upsertDevice } = require('../utils/devices');
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
  res.status(201).json({
    token,
    account: serializeAccount(user, device && device.deviceId),
  });
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

  // Bind / validate device. Throws 403 DEVICE_LIMIT when a NEW device exceeds
  // the active plan's maxDevices.
  if (device) await upsertDevice(user, device);
  await user.save();

  const token = signToken(user);
  res.status(200).json({
    token,
    account: serializeAccount(user, device && device.deviceId),
  });
});

/** GET /api/auth/me (auth) */
const me = asyncHandler(async (req, res) => {
  res.status(200).json({ account: serializeAccount(req.user) });
});

module.exports = { register, login, me };
