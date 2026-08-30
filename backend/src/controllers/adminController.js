'use strict';

const bcrypt = require('bcryptjs');
const User = require('../models/User');
const Plan = require('../models/Plan');
const SyncRecord = require('../models/SyncRecord');
const PasswordResetRequest = require('../models/PasswordResetRequest');
const asyncHandler = require('../utils/asyncHandler');
const { toIso, serializeAccount, serializePlan } = require('../utils/serialize');
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
  subscribers: ['name', 'phone', 'category'],
  boards: ['name', 'code'],
  circuits: ['name', 'phase'],
  receipts: ['receipt_no', 'month'],
  expenses: ['category', 'note'],
  monthly_prices: ['month', 'category'],
  accountants: ['name', 'username'],
  branches: ['name', 'code'],
  settlements: ['status', 'accountant_id'],
};

/** Escape regex metacharacters so q is treated as a literal substring. */
function escapeRegex(str) {
  return String(str).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * v42 item 6: the three "structure" entities are browsed as a catalogue, not as
 * a change feed, so the panel lists them OLDEST→NEWEST by creation — matching
 * the app, which orders the same three tables with DbHelper.creationOrder. Every
 * other entity keeps its newest-first `updatedAt` ordering unchanged.
 */
const CREATION_ORDERED_ENTITIES = new Set(['boards', 'circuits', 'subscribers']);

/**
 * Core mirror listing shared by the admin endpoint (any user id) and the owner
 * self-service endpoint (`/api/account/data`, the JWT user's own data).
 *
 * Lists the mirrored business rows an owner pushed for a single entity, newest
 * first — except boards/circuits/subscribers, ordered oldest→newest by creation
 * (v42 item 6, see CREATION_ORDERED_ENTITIES). Optional case-insensitive
 * substring search (q) is applied (over the entity's SEARCH_FIELDS, or localId
 * for unknown entities) before pagination.
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
  const REL_FIELDS = ['subscriber_id', 'board_id', 'circuit_id', 'branch_id', 'accountant_id'];
  const relField = typeof query.relField === 'string' ? query.relField : '';
  const relValue = query.relValue;
  if (relField && REL_FIELDS.includes(relField) && typeof relValue === 'string' && relValue) {
    // v23 (§7): '__none__' selects rows with NO value for the field — e.g.
    // owner-created expenses have `data.accountant_id = null`, which a plain
    // equality match can't express.
    filter[`data.${relField}`] = relValue === '__none__' ? null : relValue;
  }

  // v23 (§7): optional month=YYYY-MM prefix filter on data.date (expenses date
  // browsing on the owner panel). Same convention buildDashboard uses.
  // v39 item 1: settlements accept the same param, so the owner-panel
  // settlements screen is strictly month-isolated server-side.
  // v40: the settlement bucket is the app-stamped TARIFF month (data.month);
  // legacy rows without the stamp fall back to the requested_at UTC prefix.
  // Composed under $and so it never clobbers the q-search $or above.
  const month = typeof query.month === 'string' ? query.month.trim() : '';
  if (month && /^\d{4}-\d{2}$/.test(month)) {
    if (entity === 'expenses') {
      filter['data.date'] = { $regex: '^' + month };
    } else if (entity === 'settlements') {
      // NOTE: {'data.month': null} matches both an explicit null and a
      // missing key in MongoDB — exactly the legacy-row shape.
      filter.$and = (filter.$and || []).concat([{
        $or: [
          { 'data.month': month },
          { 'data.month': null, 'data.requested_at': { $regex: '^' + month } },
        ],
      }]);
    }
  }

  // Optional active-branch scope (full isolation): composes with q/relField so a
  // panel-wide branch switch narrows EVERY entity list to that branch. Most
  // entities carry data.branch_id and filter directly. ACCOUNTANTS carry none in
  // their synced identity row, so we resolve their branch from the authoritative
  // User.branchId (set at creation) and filter by localId — so switching a branch
  // also narrows the accountants list and their wallet/settlement views.
  // `branches` is the identity table itself and is never branch-scoped.
  const branchId = typeof query.branchId === 'string' ? query.branchId.trim() : '';
  if (branchId && entity !== 'branches') {
    if (entity === 'accountants') {
      if (!localId) {
        const accts = await User.find(
          { owner: userId, role: 'accountant', branchId },
          { localId: 1 }
        ).lean();
        const ids = accts.map((a) => a.localId).filter((x) => x != null).map(String);
        // No accountant in this branch → match nothing (not "match all").
        filter.localId = ids.length ? { $in: ids } : '__none__';
      }
    } else {
      filter['data.branch_id'] = branchId;
    }
  }

  const page = Math.max(1, parseInt(query.page, 10) || 1);
  let limit = parseInt(query.limit, 10);
  if (!Number.isFinite(limit) || limit < 1) limit = 25;
  limit = Math.min(200, Math.max(1, limit));

  // v42 item 6: boards/circuits/subscribers by creation, everything else newest
  // first. `localId` (the device UUID) is the tie-break, so the order is
  // identical on every load instead of following push arrival. A record with no
  // `data.created_at` sorts first (MongoDB orders missing/null before strings) —
  // legacy rows stay at the top of the list and none can drop out.
  const sort = CREATION_ORDERED_ENTITIES.has(entity)
    ? { 'data.created_at': 1, localId: 1 }
    : { updatedAt: -1 };

  const total = await SyncRecord.countDocuments(filter);
  const docs = await SyncRecord.find(filter)
    .sort(sort)
    .skip((page - 1) * limit)
    .limit(limit);

  const records = docs.map((d) => ({
    localId: d.localId,
    data: d.data,
    deleted: d.deleted,
    updatedAt: d.updatedAt ? d.updatedAt.toISOString() : null,
  }));

  // v23 (§7): for expenses, also return the total amount over the SAME filter
  // (not just the current page) so the panel can show a meaningful sum row.
  const result = { entity, records, total, page, limit };
  if (entity === 'expenses') {
    const agg = await SyncRecord.aggregate([
      { $match: filter },
      {
        $group: {
          _id: null,
          sum: { $sum: { $toDouble: { $ifNull: ['$data.amount', 0] } } },
        },
      },
    ]);
    result.totalAmount = agg.length ? agg[0].sum : 0;
  }
  return result;
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
 * TOMBSTONES a single mirrored row for the owner (the mirror is otherwise
 * read-only; delete is the lone exception). v23 (§10.2): this used to HARD
 * delete, which left the device's local row intact — the row's next local edit
 * re-created the mirror record (resurrection). Setting `deleted:true` + a fresh
 * `data.updated_at` instead means a pulling device deletes its local row, and a
 * later STALE local edit LOSES to this tombstone under last-edit-wins. Panel
 * lists already filter `deleted:false`, so the display is unchanged.
 */
const deleteUserData = asyncHandler(async (req, res) => {
  const { id, entity, localId } = req.params;

  const user = await User.findById(id);
  if (!user) throw new HttpError(404, 'User not found', 'USER_NOT_FOUND');

  const rec = await SyncRecord.findOne({ user: user._id, entity, localId });
  if (!rec) throw new HttpError(404, 'Record not found', 'RECORD_NOT_FOUND');

  const now = new Date();
  rec.deleted = true;
  rec.updatedAt = now; // pull cursor
  // Stamp data.updated_at so the sync engine's last-EDIT-wins treats this
  // tombstone as newer than any pre-existing device edit.
  rec.data = Object.assign({}, rec.data, { updated_at: now.toISOString() });
  rec.markModified('data');
  await rec.save();

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
    case 'accountants': return data.name || data.username || null;
    case 'branches': return data.name || data.code || null;
    case 'settlements': return data.amount != null ? String(data.amount) : null;
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
  const {
    code,
    name,
    durationDays,
    maxDevices,
    price,
    description,
    active,
    syncEnabled,
    backupEnabled,
    ownerPanelEnabled,
    multiBranchEnabled,
  } = req.body;

  const update = {
    name,
    durationDays,
    maxDevices,
    price: price ?? 0,
    description: description || '',
    active: active !== false,
    syncEnabled,
    backupEnabled,
    ownerPanelEnabled,
    multiBranchEnabled,
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

// ---- Password reset requests (v42 item 4) ----

/** The statuses a request can be filtered by; anything else is ignored. */
const RESET_STATUSES = new Set(['pending', 'approved', 'rejected', 'expired']);

/**
 * Panel shape of a password-reset request.
 *
 * `newPasswordHash` is NEVER serialized: the requested password enters the
 * collection already hashed and only ever leaves it by being written onto the
 * user in approvePasswordReset. `owner` is the request's account, resolved by
 * the caller (the ref itself is never populated — see listPasswordResets).
 */
function serializeResetRequest(doc, owner) {
  const acct = owner || null;
  return {
    id: String(doc._id),
    userId: doc.user ? String(doc.user) : null,
    name: acct ? acct.name || null : null,
    generatorName: acct ? acct.generatorName || null : null,
    username: doc.username || null,
    phone: doc.phone || null,
    // The 6-digit reference the owner reads out to the super admin. The schema
    // field is `code` (PasswordResetRequest.js) — reading a `verificationCode`
    // that does not exist would silently null out the whole identity check.
    code: doc.code || null,
    status: doc.status,
    note: doc.note || null,
    createdAt: toIso(doc.createdAt),
    expiresAt: toIso(doc.expiresAt),
    decidedAt: toIso(doc.decidedAt),
  };
}

/**
 * GET /api/admin/password-resets?q=&status=&page=1&limit=25
 *
 * The owner-initiated password-reset queue, newest first, with the same
 * search + server-side pagination shape as the other admin lists. `q` matches
 * the request's own username/phone plus the account's name/generatorName —
 * those two live on the referenced User, which a Mongo regex can't reach
 * through a ref, so the matching accounts are resolved FIRST and folded into
 * the $or as a `user: { $in }` term (the two-step listUserData already uses for
 * the accountants branch scope).
 */
const listPasswordResets = asyncHandler(async (req, res) => {
  const filter = {};

  const status = typeof req.query.status === 'string' ? req.query.status.trim() : '';
  if (status && RESET_STATUSES.has(status)) filter.status = status;

  const q = typeof req.query.q === 'string' ? req.query.q.trim() : '';
  if (q) {
    const regex = { $regex: escapeRegex(q), $options: 'i' };
    const namedAccounts = await User.find(
      { $or: [{ name: regex }, { generatorName: regex }] },
      { _id: 1 }
    ).lean();
    filter.$or = [
      { username: regex },
      { phone: regex },
      // The 6-digit reference the owner reads back over the phone — in practice
      // the admin's PRIMARY lookup, so it must be searchable (API_CONTRACT.md
      // lists it alongside name/generatorName/username/phone).
      { code: regex },
      // Empty $in matches nothing — the right answer when no account's
      // name/generatorName matched, not "match everything".
      { user: { $in: namedAccounts.map((a) => a._id) } },
    ];
  }

  const page = Math.max(1, parseInt(req.query.page, 10) || 1);
  let limit = parseInt(req.query.limit, 10);
  if (!Number.isFinite(limit) || limit < 1) limit = 25;
  limit = Math.min(200, Math.max(1, limit));

  const total = await PasswordResetRequest.countDocuments(filter);
  const docs = await PasswordResetRequest.find(filter)
    .sort({ createdAt: -1 })
    .skip((page - 1) * limit)
    .limit(limit);

  // Resolve the page's accounts in one query (same shape recentData uses) so a
  // deleted account degrades to null name/generatorName instead of failing.
  const userIds = [...new Set(docs.map((d) => String(d.user)))];
  const accounts = await User.find({ _id: { $in: userIds } }, { name: 1, generatorName: 1 });
  const byId = new Map(accounts.map((u) => [String(u._id), u]));

  res.status(200).json({
    items: docs.map((d) => serializeResetRequest(d, byId.get(String(d.user)))),
    total,
    page,
    limit,
  });
});

/**
 * POST /api/admin/password-resets/:id/approve
 *
 * THIS is the moment the owner's password actually changes — never at request
 * time. Only a still-pending, unexpired request may be applied, so a second
 * approve is a 409 no-op (idempotent: the hash can never be written twice, and
 * an already-decided request can never be re-applied over a newer password).
 */
const approvePasswordReset = asyncHandler(async (req, res) => {
  const request = await PasswordResetRequest.findById(req.params.id);
  if (!request) throw new HttpError(404, 'Reset request not found', 'RESET_NOT_FOUND');

  if (request.status !== 'pending') {
    throw new HttpError(409, `Request already ${request.status}`, 'RESET_NOT_PENDING');
  }
  // Nothing sweeps the collection, so a lapsed request is retired HERE: persist
  // 'expired' (the app's status poll then reports it) and refuse — the owner
  // must file a fresh request.
  if (request.expiresAt && new Date(request.expiresAt).getTime() <= Date.now()) {
    request.status = 'expired';
    await request.save();
    throw new HttpError(409, 'Reset request has expired', 'RESET_EXPIRED');
  }
  // Defensive: never blank an owner's passwordHash from a malformed request.
  if (!request.newPasswordHash) {
    throw new HttpError(409, 'Reset request carries no password', 'RESET_INVALID');
  }

  const user = await User.findById(request.user);
  if (!user) throw new HttpError(404, 'User not found', 'USER_NOT_FOUND');

  // The hash was computed at request time (the plaintext never reached the
  // panel) and is written verbatim.
  user.passwordHash = request.newPasswordHash;
  // Invalidate all previously-issued JWTs (old tokens become TOKEN_STALE) — the
  // same bump updateMyProfile does on a self password change. Whoever held the
  // account before the reset is signed out everywhere.
  user.tokenVersion = (user.tokenVersion || 0) + 1;
  await user.save();

  request.status = 'approved';
  request.decidedAt = new Date();
  request.decidedBy = req.user._id;
  await request.save();

  res.status(200).json({ ok: true, request: serializeResetRequest(request, user) });
});

/**
 * POST /api/admin/password-resets/:id/reject  body { note }
 *
 * Declines the request and records why. The user's password and tokenVersion
 * are NOT touched — a rejection changes nothing but this row.
 */
const rejectPasswordReset = asyncHandler(async (req, res) => {
  const { note } = req.body || {};

  const request = await PasswordResetRequest.findById(req.params.id);
  if (!request) throw new HttpError(404, 'Reset request not found', 'RESET_NOT_FOUND');

  if (request.status !== 'pending') {
    throw new HttpError(409, `Request already ${request.status}`, 'RESET_NOT_PENDING');
  }

  request.status = 'rejected';
  if (note !== undefined) request.note = note ? String(note).trim() : null;
  request.decidedAt = new Date();
  request.decidedBy = req.user._id;
  await request.save();

  const user = await User.findById(request.user);
  res.status(200).json({ ok: true, request: serializeResetRequest(request, user) });
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
  listPasswordResets,
  approvePasswordReset,
  rejectPasswordReset,
};
