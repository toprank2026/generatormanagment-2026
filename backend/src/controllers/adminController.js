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
 * Core mirror listing shared by the admin endpoint (any user id) and the owner
 * self-service endpoint (`/api/account/data`, the JWT user's own data).
 *
 * Lists the mirrored business rows an owner pushed for a single entity, newest
 * first. Optional case-insensitive substring search (q) is applied (over the
 * entity's SEARCH_FIELDS, or localId for unknown entities) before pagination.
 * Deleted tombstones are excluded unless includeDeleted=true. Also supports a
 * localId exact fetch and a whitelisted relField/relValue relationship filter.
 *
 * @param {*} userId Mongo id of the account whose mirror is listed.
 * @param {object} query Express `req.query` (entity, q, page, limit, ...).
 * @returns {Promise<{entity, records, total, page, limit}>}
 */
async function listUserData(userId, query = {}) {
  const { entity } = query;
  if (!entity || typeof entity !== 'string') {
    throw new HttpError(400, 'entity query param is required', 'ENTITY_REQUIRED');
  }

  const filter = { user: userId, entity };
  const includeDeleted = query.includeDeleted === 'true';
  if (!includeDeleted) filter.deleted = false;

  // Exact single-record fetch by localId (receipt-details screen).
  const localId = typeof query.localId === 'string' ? query.localId.trim() : '';
  if (localId) filter.localId = localId;

  const q = typeof query.q === 'string' ? query.q.trim() : '';
  if (q) {
    const regex = { $regex: escapeRegex(q), $options: 'i' };
    const fields = SEARCH_FIELDS[entity] || [];
    const or = fields.map((f) => ({ [`data.${f}`]: regex }));
    // Unknown entity (or no fields): fall back to matching the localId.
    if (or.length === 0) or.push({ localId: regex });
    filter.$or = or;
  }

  // Optional relationship filter (drill-down). Whitelisted fields only.
  const REL_FIELDS = ['subscriber_id', 'board_id', 'circuit_id'];
  const relField = typeof query.relField === 'string' ? query.relField : '';
  const relValue = query.relValue;
  if (relField && REL_FIELDS.includes(relField) && typeof relValue === 'string' && relValue) {
    filter[`data.${relField}`] = relValue;
  }

  const page = Math.max(1, parseInt(query.page, 10) || 1);
  let limit = parseInt(query.limit, 10);
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

  return { entity, records, total, page, limit };
}

/**
 * GET /api/admin/users/:id/data?entity=E&q=&page=1&limit=25[&includeDeleted=true]
 *
 * Admin view over any owner's mirror; validates the :id param then delegates
 * to listUserData (see above for the supported query params).
 */
const getUserData = asyncHandler(async (req, res) => {
  const user = await User.findById(req.params.id);
  if (!user) throw new HttpError(404, 'User not found', 'USER_NOT_FOUND');

  res.status(200).json(await listUserData(user._id, req.query));
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

/**
 * Compact human label for a mirrored record, shown in "latest uploads" lists
 * (admin dashboard + owner panel home).
 */
const labelFor = (entity, data) => {
  if (!data) return null;
  switch (entity) {
    case 'subscribers': return data.name || data.phone || null;
    case 'boards': return data.name || data.code || null;
    case 'circuits': return data.name || null;
    case 'receipts': return data.receipt_no != null ? `#${data.receipt_no}` : null;
    case 'expenses': return [data.category, data.amount].filter((v) => v != null).join(' — ') || null;
    case 'monthly_prices': return data.month || null;
    default: return null;
  }
};

/**
 * GET /api/admin/recent-data?limit=10
 *
 * The latest data uploaded (synced) from the Flutter apps across ALL accounts,
 * newest first — shown on the admin dashboard home. Each item carries the
 * owner's name/generator plus a compact human label derived from the record.
 */
const recentData = asyncHandler(async (req, res) => {
  const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 10, 1), 50);
  const page = Math.max(parseInt(req.query.page, 10) || 1, 1);

  const filter = { deleted: false };
  const total = await SyncRecord.countDocuments(filter);
  const records = await SyncRecord.find(filter)
    .sort({ updatedAt: -1 })
    .skip((page - 1) * limit)
    .limit(limit);

  const userIds = [...new Set(records.map((r) => String(r.user)))];
  const users = await User.find({ _id: { $in: userIds } });
  const byId = new Map(users.map((u) => [String(u._id), u]));

  res.status(200).json({
    items: records.map((r) => {
      const owner = byId.get(String(r.user));
      return {
        entity: r.entity,
        localId: r.localId,
        updatedAt: r.updatedAt,
        label: labelFor(r.entity, r.data),
        userId: String(r.user),
        userName: owner ? owner.name || owner.username : null,
        generatorName: owner ? owner.generatorName || null : null,
      };
    }),
    total,
    page,
    limit,
  });
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
  listUserData,
  getUserData,
  deleteUserData,
  recentData,
  labelFor,
  listPlans,
  upsertPlan,
  deletePlan,
};
