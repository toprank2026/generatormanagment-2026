'use strict';

const bcrypt = require('bcryptjs');
const User = require('../models/User');
const Plan = require('../models/Plan');
const SyncRecord = require('../models/SyncRecord');
const asyncHandler = require('../utils/asyncHandler');
const { serializeAccount, serializePlan } = require('../utils/serialize');
const { HttpError } = require('../middleware/error');

// ---- Users ----

/** GET /api/admin/users */
const listUsers = asyncHandler(async (req, res) => {
  const users = await User.find().sort({ createdAt: -1 });
  res.status(200).json({ users: users.map((u) => serializeAccount(u)) });
});

/** POST /api/admin/users */
const createUser = asyncHandler(async (req, res) => {
  const { name, phone, username, password, role } = req.body;

  const exists = await User.findOne({ username: String(username).toLowerCase() });
  if (exists) {
    throw new HttpError(409, 'Username already taken', 'USERNAME_TAKEN');
  }

  const passwordHash = await bcrypt.hash(password, 10);
  const user = await User.create({
    name,
    phone: phone || null,
    username,
    passwordHash,
    role: role === 'admin' ? 'admin' : 'owner',
    subscription: { status: 'none', planCode: null },
    devices: [],
  });

  res.status(201).json({ user: serializeAccount(user) });
});

/** GET /api/admin/users/:id */
const getUser = asyncHandler(async (req, res) => {
  const user = await User.findById(req.params.id);
  if (!user) throw new HttpError(404, 'User not found', 'USER_NOT_FOUND');
  res.status(200).json({ user: serializeAccount(user) });
});

/** DELETE /api/admin/users/:id */
const deleteUser = asyncHandler(async (req, res) => {
  const user = await User.findById(req.params.id);
  if (!user) throw new HttpError(404, 'User not found', 'USER_NOT_FOUND');
  if (String(user._id) === String(req.user._id)) {
    throw new HttpError(400, 'You cannot delete your own admin account', 'SELF_DELETE');
  }
  await user.deleteOne();
  res.status(200).json({ ok: true });
});

/** PUT /api/admin/users/:id/blocked  body { blocked } */
const setBlocked = asyncHandler(async (req, res) => {
  const { blocked } = req.body;
  const user = await User.findById(req.params.id);
  if (!user) throw new HttpError(404, 'User not found', 'USER_NOT_FOUND');
  user.blocked = Boolean(blocked);
  await user.save();
  res.status(200).json({ user: serializeAccount(user) });
});

/** Compute expiresAt from a plan's durationDays starting now. */
async function planExpiry(planCode) {
  const plan = await Plan.findOne({ code: planCode });
  if (!plan) return null;
  const started = new Date();
  const expires = new Date(started.getTime() + plan.durationDays * 24 * 60 * 60 * 1000);
  return { started, expires };
}

/** PUT /api/admin/users/:id/plan  body { planCode, status } */
const setPlan = asyncHandler(async (req, res) => {
  const { planCode, status } = req.body;
  const user = await User.findById(req.params.id);
  if (!user) throw new HttpError(404, 'User not found', 'USER_NOT_FOUND');

  const plan = await Plan.findOne({ code: planCode });
  if (!plan) throw new HttpError(404, 'Plan not found', 'PLAN_NOT_FOUND');

  const nextStatus = status || 'active';
  const sub = { planCode, status: nextStatus, startedAt: null, expiresAt: null };

  if (nextStatus === 'active') {
    const dates = await planExpiry(planCode);
    if (dates) {
      sub.startedAt = dates.started;
      sub.expiresAt = dates.expires;
    }
  }

  user.subscription = sub;
  await user.save();
  res.status(200).json({ user: serializeAccount(user) });
});

/** POST /api/admin/users/:id/approve-plan — activate the pending request. */
const approvePlan = asyncHandler(async (req, res) => {
  const user = await User.findById(req.params.id);
  if (!user) throw new HttpError(404, 'User not found', 'USER_NOT_FOUND');

  const sub = user.subscription || {};
  if (sub.status !== 'pending' || !sub.planCode) {
    throw new HttpError(400, 'No pending plan request to approve', 'NO_PENDING');
  }

  const dates = await planExpiry(sub.planCode);
  if (!dates) {
    // The requested plan was deleted after the request was made.
    throw new HttpError(404, 'Requested plan no longer exists', 'PLAN_NOT_FOUND');
  }
  user.subscription = {
    planCode: sub.planCode,
    status: 'active',
    startedAt: dates.started,
    expiresAt: dates.expires,
  };
  await user.save();
  res.status(200).json({ user: serializeAccount(user) });
});

/** POST /api/admin/users/:id/reject-plan — mark the pending request rejected. */
const rejectPlan = asyncHandler(async (req, res) => {
  const user = await User.findById(req.params.id);
  if (!user) throw new HttpError(404, 'User not found', 'USER_NOT_FOUND');

  const sub = user.subscription || {};
  if (sub.status !== 'pending') {
    throw new HttpError(400, 'No pending plan request to reject', 'NO_PENDING');
  }

  user.subscription = {
    planCode: sub.planCode,
    status: 'rejected',
    startedAt: null,
    expiresAt: null,
  };
  await user.save();
  res.status(200).json({ user: serializeAccount(user) });
});

/** DELETE /api/admin/users/:id/devices/:deviceId — unbind a device. */
const unbindDevice = asyncHandler(async (req, res) => {
  const { id, deviceId } = req.params;
  const user = await User.findById(id);
  if (!user) throw new HttpError(404, 'User not found', 'USER_NOT_FOUND');

  const before = user.devices.length;
  user.devices = user.devices.filter((d) => d.deviceId !== deviceId);
  if (user.devices.length === before) {
    throw new HttpError(404, 'Device not found', 'DEVICE_NOT_FOUND');
  }
  await user.save();
  res.status(200).json({ ok: true });
});

// ---- Synced business data (per-account mirror) ----

/**
 * Per-entity `data.*` paths a free-text search (q) matches against. Unknown
 * entities fall back to matching the record's localId only.
 */
const SEARCH_FIELDS = {
  subscribers: ['name', 'phone'],
  boards: ['name', 'code'],
  circuits: ['name', 'phase'],
  receipts: ['receipt_no', 'month'],
  expenses: ['category', 'note'],
  monthly_prices: ['month'],
};

/** Escape regex metacharacters so q is treated as a literal substring. */
function escapeRegex(str) {
  return String(str).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * GET /api/admin/users/:id/data?entity=E&q=&page=1&limit=25[&includeDeleted=true]
 *
 * Lists the mirrored business rows an owner pushed for a single entity, newest
 * first. Optional case-insensitive substring search (q) is applied (over the
 * entity's SEARCH_FIELDS, or localId for unknown entities) before pagination.
 * Deleted tombstones are excluded unless includeDeleted=true.
 */
const getUserData = asyncHandler(async (req, res) => {
  const { entity } = req.query;
  if (!entity || typeof entity !== 'string') {
    throw new HttpError(400, 'entity query param is required', 'ENTITY_REQUIRED');
  }

  const user = await User.findById(req.params.id);
  if (!user) throw new HttpError(404, 'User not found', 'USER_NOT_FOUND');

  const filter = { user: user._id, entity };
  const includeDeleted = req.query.includeDeleted === 'true';
  if (!includeDeleted) filter.deleted = false;

  const q = typeof req.query.q === 'string' ? req.query.q.trim() : '';
  if (q) {
    const regex = { $regex: escapeRegex(q), $options: 'i' };
    const fields = SEARCH_FIELDS[entity] || [];
    const or = fields.map((f) => ({ [`data.${f}`]: regex }));
    // Unknown entity (or no fields): fall back to matching the localId.
    if (or.length === 0) or.push({ localId: regex });
    filter.$or = or;
  }

  // Optional relationship filter (admin drill-down). Whitelisted fields only.
  const REL_FIELDS = ['subscriber_id', 'board_id', 'circuit_id'];
  const relField = typeof req.query.relField === 'string' ? req.query.relField : '';
  const relValue = req.query.relValue;
  if (relField && REL_FIELDS.includes(relField) && typeof relValue === 'string' && relValue) {
    filter[`data.${relField}`] = relValue;
  }

  const page = Math.max(1, parseInt(req.query.page, 10) || 1);
  let limit = parseInt(req.query.limit, 10);
  if (!Number.isFinite(limit) || limit < 1) limit = 25;
  limit = Math.min(200, Math.max(1, limit));

  const total = await SyncRecord.countDocuments(filter);
  const docs = await SyncRecord.find(filter)
    .sort({ updatedAt: -1 })
    .skip((page - 1) * limit)
    .limit(limit);

  const records = docs.map((d) => ({
    localId: d.localId,
    data: d.data,
    deleted: d.deleted,
    updatedAt: d.updatedAt ? d.updatedAt.toISOString() : null,
  }));

  res.status(200).json({ entity, records, total, page, limit });
});

/**
 * DELETE /api/admin/users/:id/data/:entity/:localId
 *
 * Hard-deletes a single mirrored row for the owner. The mirror is otherwise
 * read-only (sync is push-only device->server); delete is the lone exception.
 */
const deleteUserData = asyncHandler(async (req, res) => {
  const { id, entity, localId } = req.params;

  const user = await User.findById(id);
  if (!user) throw new HttpError(404, 'User not found', 'USER_NOT_FOUND');

  const deleted = await SyncRecord.findOneAndDelete({ user: user._id, entity, localId });
  if (!deleted) throw new HttpError(404, 'Record not found', 'RECORD_NOT_FOUND');

  res.status(200).json({ ok: true });
});

// ---- Plans ----

/** GET /api/admin/plans — all plans (active + inactive). */
const listPlans = asyncHandler(async (req, res) => {
  const plans = await Plan.find().sort({ price: 1, durationDays: 1 });
  res.status(200).json({ plans: plans.map(serializePlan) });
});

/** PUT /api/admin/plans — upsert a plan by code (body = Plan). */
const upsertPlan = asyncHandler(async (req, res) => {
  const { code, name, durationDays, maxDevices, price, description, active } = req.body;

  const update = {
    name,
    durationDays,
    maxDevices,
    price: price ?? 0,
    description: description || '',
    active: active !== false,
  };
  // Drop undefined so a partial PUT only changes provided fields on update.
  Object.keys(update).forEach((k) => update[k] === undefined && delete update[k]);

  const plan = await Plan.findOneAndUpdate(
    { code },
    { $set: update, $setOnInsert: { code } },
    { new: true, upsert: true, runValidators: true, setDefaultsOnInsert: true }
  );

  res.status(200).json({ plan: serializePlan(plan) });
});

/** DELETE /api/admin/plans/:code */
const deletePlan = asyncHandler(async (req, res) => {
  const plan = await Plan.findOneAndDelete({ code: req.params.code });
  if (!plan) throw new HttpError(404, 'Plan not found', 'PLAN_NOT_FOUND');
  res.status(200).json({ ok: true });
});

module.exports = {
  listUsers,
  createUser,
  getUser,
  deleteUser,
  setBlocked,
  setPlan,
  approvePlan,
  rejectPlan,
  unbindDevice,
  getUserData,
  deleteUserData,
  listPlans,
  upsertPlan,
  deletePlan,
};
