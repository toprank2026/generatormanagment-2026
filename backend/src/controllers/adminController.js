'use strict';

const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const mongoose = require('mongoose');
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
  // v43: the two correction tables. Both previously fell through to the
  // localId-only fallback below (no entry = no searchable field), so adding
  // them only widens a search that could not find anything useful before.
  corrections: ['month', 'status', 'reason', 'subscriber_id'],
  financial_adjustments: ['month', 'kind', 'subscriber_id'],
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
  // v43: `correction_id` lets the panel drill from one correction into the
  // immutable ledger rows it produced
  // (?entity=financial_adjustments&relField=correction_id&relValue=<uuid>).
  const REL_FIELDS = [
    'subscriber_id',
    'board_id',
    'circuit_id',
    'branch_id',
    'accountant_id',
    'correction_id',
  ];
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

/* ───────────────────────────────────────────────────────────────────────────
 * v43 (F2) — the SETTLEMENT MONTH LOCK on the admin synced-data DELETE.
 *
 * Unlike `/api/sync/push` — where a 4xx fails the WHOLE batch, permanently
 * wedges the device outbox and stops that device's synchronisation for good
 * (which is why the push loop SKIPS a locked row and reports it in
 * `rejected[]` instead of throwing) — this is an ordinary request/response
 * endpoint with no offline semantics. A hard refusal here is therefore safe
 * and correct: nothing retries it in a loop and no device is blocked by it.
 *
 * The lock is DERIVED, never stored (a lock COLUMN on `receipts`/`settlements`
 * would be wiped account-wide by the next `SyncService.pull`, which writes
 * INSERT OR REPLACE): a month is closed while a settlement with status
 * pending|approved exists for it, bucketed by the v40 tariff rule
 * COALESCE(data.month, substr(data.requested_at,1,7)) — byte-identical to the
 * expression the app, `accountController.getWallet`, `listUserData` above and
 * the push-loop guard already use.
 * ─────────────────────────────────────────────────────────────────────────── */

/** A settlement in either of these states closes its accounting month. */
const ACTIVE_SETTLEMENT_STATUSES = ['pending', 'approved'];

/** 'YYYY-MM'. Also the guard that keeps a stored string out of a $regex. */
const MONTH_RE = /^\d{4}-\d{2}$/;

/** Trimmed string of an arbitrary value ('' for null/undefined/non-strings). */
const str = (v) => (typeof v === 'string' ? v.trim() : '');

/**
 * Entities whose mirrored rows carry money for a closed month, with the code
 * reported when the delete is refused. Every OTHER entity keeps today's
 * behaviour exactly — subscribers/boards/circuits/expenses/... delete as before.
 */
const DELETE_LOCK_CODES = {
  receipts: 'RECEIPT_MONTH_LOCKED',
  settlements: 'SETTLEMENT_MONTH_LOCKED',
};

/**
 * v43 review fix: entities that are APPEND-ONLY by construction and may never
 * be deleted through the generic synced-data DELETE — not for a settled month,
 * not for an open one. `financial_adjustments` IS the correction ledger the
 * wallet is derived from, and `corrections` is its audit trail; a tombstone
 * here does not just hide a panel row, it PROPAGATES to every device on the
 * next pull and silently moves the accountant's wallet. The whole v43 design
 * rests on "approval never edits or deletes an original", so the delete route
 * must refuse outright rather than lock per-month.
 */
const DELETE_FORBIDDEN_CODES = {
  financial_adjustments: 'ADJUSTMENT_IMMUTABLE',
  corrections: 'CORRECTION_IMMUTABLE',
};

/**
 * The accounting month a mirrored row belongs to, or '' when it carries none.
 * A receipt stamps the billing month directly; a settlement uses the v40
 * tariff month and falls back to the `requested_at` UTC prefix for legacy rows
 * written before that stamp existed.
 */
function bucketMonthOf(entity, data) {
  const d = data && typeof data === 'object' ? data : {};
  const stamped = str(d.month);
  if (MONTH_RE.test(stamped)) return stamped;
  if (entity === 'settlements') {
    const legacy = str(d.requested_at).slice(0, 7);
    if (MONTH_RE.test(legacy)) return legacy;
  }
  return '';
}

/** True when a pending|approved settlement buckets into [month] for [userId]. */
async function monthHasActiveSettlement(userId, month) {
  if (!MONTH_RE.test(month)) return false;
  const hit = await SyncRecord.findOne({
    user: userId,
    entity: 'settlements',
    deleted: false,
    'data.status': { $in: ACTIVE_SETTLEMENT_STATUSES },
    // Composed under $and so the bucket $or can never clobber the clauses
    // above. NOTE: {'data.month': null} matches an explicit null AND a missing
    // key in MongoDB — exactly the legacy-row shape.
    $and: [
      {
        $or: [
          { 'data.month': month },
          { 'data.month': null, 'data.requested_at': { $regex: '^' + month } },
        ],
      },
    ],
  })
    .select('_id')
    .lean();
  return Boolean(hit);
}

/**
 * Refuses (409) the delete of a receipt/settlement whose accounting month is
 * closed by an active settlement. Deleting one would silently move money out
 * of a month the owner has already settled — the exact class of change v43
 * routes through a correction request instead.
 *
 * Two deliberate consequences, both safe:
 *  - an ACTIVE settlement locks its own month, so a pending/approved
 *    settlement row cannot be deleted. Reject it first (the owner decision
 *    route) and it becomes deletable — a rejection is recorded, a silent
 *    disappearance is not.
 *  - a row with no parseable month is NOT locked, so legacy rows keep exactly
 *    the delete behaviour they have today (when in doubt, do not lock).
 */
async function assertDeletableRow(userId, entity, data) {
  const forbidden = DELETE_FORBIDDEN_CODES[entity];
  if (forbidden) {
    throw new HttpError(
      409,
      'This is an append-only accounting record and cannot be deleted. ' +
        'Reject or reverse the correction instead.',
      forbidden
    );
  }
  const code = DELETE_LOCK_CODES[entity];
  if (!code) return;
  const month = bucketMonthOf(entity, data);
  if (!month) return;
  if (!(await monthHasActiveSettlement(userId, month))) return;
  throw new HttpError(
    409,
    `The accounting month ${month} is settled — this row cannot be deleted. ` +
      'File a correction instead.',
    code
  );
}

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

  // v43 (F2): a receipt/settlement of a month closed by an active settlement is
  // refused outright (409) — see assertDeletableRow above. Every other entity,
  // and every unsettled month, is unaffected.
  await assertDeletableRow(user._id, entity, rec.data);

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
    // v43: a correction reads as "the month it corrects — the delta"; an
    // adjustment as "its kind — the signed amount". Both returned null before.
    case 'corrections':
      return [data.month, data.difference].filter((v) => v != null).join(' — ') || null;
    case 'financial_adjustments':
      return [data.kind, data.amount].filter((v) => v != null).join(' — ') || null;
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

/* ───────────────────────────────────────────────────────────────────────────
 * Corrections after invoicing (v43) — the admin decision queue.
 *
 * A correction is how an ALREADY-INVOICED (or already-settled) month is fixed
 * without rewriting a single existing row. The accountant files one on the
 * device; it reaches the owner's mirror as a `corrections` SyncRecord. The
 * super admin decides it HERE, and a decision writes at most one row: an
 * immutable `financial_adjustments` record. THE ORIGINAL RECEIPT AND THE
 * ORIGINAL SETTLEMENT ARE NEVER TOUCHED BY ANY HANDLER BELOW — an invoice is a
 * historical document, and the adjustment is deliberately NOT a receipt (a
 * receipt row would consume a real `receipt_no`, which is NOT NULL and
 * allocated MAX+1 per branch, and would appear in printed history as a phantom
 * invoice).
 *
 * THE MONEY RULE, identical to the app's CorrectionController so the panel and
 * the device can never book a decision differently:
 *   increase (difference > 0) -> `correction_increase` for +|Δ|  -> status `approved`
 *                                that month's wallet RISES, so an additional
 *                                settlement for the month becomes possible.
 *   decrease (difference < 0) -> `correction_decrease` for +|Δ|  -> status `refund_due`
 *                                recorded for the audit trail ONLY: the wallet
 *                                is NOT reduced (it must never be driven
 *                                negative by a historical correction).
 *   cash returned             -> `refund_return` for −|Δ|        -> status `completed`
 *                                the PHYSICAL return, with accountant_id NULL
 *                                so no accountant's derived wallet drops.
 * Approving a decrease and handing the money back are two separate,
 * separately-recorded operations — approval alone never asserts cash moved.
 *
 * `financial_adjustments` is APPEND-ONLY: written once, never updated, never
 * deleted, by anyone. There is deliberately no update/delete handler for it
 * here, and none may be added — correcting a mistake means APPENDING another
 * adjustment.
 * ─────────────────────────────────────────────────────────────────────────── */

const { buildFrozenAmps } = require('../utils/frozenAmps');

const CORRECTION_ENTITY = 'corrections';
const ADJUSTMENT_ENTITY = 'financial_adjustments';

/** Correction lifecycle — mirrors CorrectionStatus (correction_models.dart). */
const CORRECTION_STATUSES = new Set([
  'pending',
  'approved',
  'rejected',
  'refund_due',
  'completed',
  'carried_forward', // v44: decrease credit applied to the next month
]);

/**
 * The statuses that mean "already decided". A row whose status is any of these
 * is out of the pending gate; ANYTHING ELSE — 'pending', an explicit null, a
 * missing key, or an unrecognised value — counts as still pending, which is
 * exactly how the app normalizes it (CorrectionStatus.normalize) and how
 * settlementController treats an unstamped settlement. Expressed as a $nin so
 * the guard and the normalizer can never disagree.
 */
const DECIDED_CORRECTION_STATUSES = ['approved', 'rejected', 'refund_due', 'completed', 'carried_forward'];

/** AdjustmentKind (correction_models.dart) — the three ledger kinds. */
const ADJ_INCREASE = 'correction_increase';
const ADJ_DECREASE = 'correction_decrease';
const ADJ_REFUND_RETURN = 'refund_return';
/** v44: a decrease's credit applied to a LATER month (`month` = the target). */
const ADJ_CREDIT_APPLIED = 'credit_applied';

/** 'YYYY-MM' + 1 month, year-wrap safe. */
function nextMonthOf(m) {
  const mm = /^(\d{4})-(\d{2})$/.exec(String(m || ''));
  if (!mm) return null;
  const d = new Date(Date.UTC(Number(mm[1]), Number(mm[2]), 1)); // month index = mm[2] → next
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
}

/**
 * Free-text search over corrections resolves matching SUBSCRIBER names first
 * (a Mongo regex cannot reach `data.name` on another record through an id), the
 * two-step listPasswordResets/listUserData already use. Capped so an admin
 * typing a single common letter cannot pull an unbounded id list into memory.
 */
const SUBSCRIBER_MATCH_CAP = 500;

/** RFC 4122 URL namespace — `Namespace.url` in the app's `uuid` package. */
const UUID_URL_NAMESPACE = '6ba7b811-9dad-11d1-80b4-00c04fd430c8';

/**
 * RFC 4122 v5 (SHA-1, namespace + name) — byte-identical to the app's
 * `const Uuid().v5(Namespace.url.value, name)`. Implemented here rather than
 * pulled in as a dependency: it is fifteen lines of the spec and the backend
 * has no uuid package.
 */
function uuidV5(name) {
  const ns = Buffer.from(UUID_URL_NAMESPACE.replace(/-/g, ''), 'hex');
  const hash = crypto
    .createHash('sha1')
    .update(ns)
    .update(Buffer.from(String(name), 'utf8'))
    .digest();
  const bytes = Buffer.from(hash.subarray(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50; // version 5
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  const hex = bytes.toString('hex');
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20),
  ].join('-');
}

/**
 * The DETERMINISTIC id of the adjustment for one (correction, kind).
 *
 * This is the whole idempotency of the money path, and it is shared verbatim
 * with `CorrectionController._adjustmentId` on the device: a retried approval,
 * a double-clicked panel button, or the same decision recorded on a device and
 * in the panel can only ever write THE SAME ledger row. With a random id each
 * of those would DOUBLE-CREDIT the wallet — and, the table being append-only,
 * the surplus row could never be deleted.
 */
function adjustmentIdFor(correctionId, kind) {
  return uuidV5(`moldati/v43/adjustment/${correctionId}/${kind}`);
}

/** Normalized status of a correction's `data` (unknown/absent -> 'pending'). */
function correctionStatusOf(data) {
  const s = str((data || {}).status);
  return CORRECTION_STATUSES.has(s) ? s : 'pending';
}

/** Finite number, or null — never NaN into a JSON money field. */
function numOrNull(v) {
  if (v == null || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

/**
 * Panel shape of one correction. camelCase like every other admin serializer;
 * `id` is the mirror record's Mongo id (what the decision routes take) and
 * `localId` the device UUID of the `corrections` row (what the app and the
 * ledger's `correction_id` reference).
 */
function serializeCorrection(doc, owner, subscriberName) {
  const d = doc.data && typeof doc.data === 'object' ? doc.data : {};
  const acct = owner || null;
  return {
    id: String(doc._id),
    localId: doc.localId,
    userId: doc.user ? String(doc.user) : null,
    ownerName: acct ? acct.name || null : null,
    generatorName: acct ? acct.generatorName || null : null,
    subscriberId: d.subscriber_id || null,
    subscriberName: subscriberName || null,
    month: d.month || null,
    branchId: d.branch_id || null,
    accountantId: d.accountant_id || null,
    receiptUuid: d.receipt_uuid || null,
    settlementId: d.settlement_id || null,
    reason: d.reason || null,
    oldAmps: numOrNull(d.old_amps),
    newAmps: numOrNull(d.new_amps),
    oldDue: numOrNull(d.old_due),
    newDue: numOrNull(d.new_due),
    difference: numOrNull(d.difference) || 0,
    status: correctionStatusOf(d),
    requestedBy: d.requested_by || null,
    requestedAt: d.requested_at || null,
    decidedBy: d.decided_by || null,
    decidedAt: d.decided_at || null,
    decisionNote: d.decision_note || null,
    refundPaidAt: d.refund_paid_at || null,
    refundPaidBy: d.refund_paid_by || null,
    createdAt: d.created_at || null,
    deleted: Boolean(doc.deleted),
    updatedAt: toIso(doc.updatedAt),
  };
}

/**
 * GET /api/admin/corrections?q=&status=&month=&userId=&page=1&limit=25
 *
 * The correction queue across every owner's mirror — PENDING FIRST, then
 * newest by `requested_at` (the ordering `CorrectionRepository.list` uses on
 * the device, so the panel and the app read the same queue). Same search +
 * server-side pagination + `{ items, total, page, limit }` envelope as the
 * other admin lists.
 *
 * `q` matches the correction's own month/reason/subscriber id/localId plus two
 * things a plain regex cannot reach through an id — the owner ACCOUNT's
 * name/generatorName and the SUBSCRIBER's name — each resolved first and folded
 * into the $or as an `$in` term. `status` and `month` are exact filters;
 * `userId` optionally narrows to a single account (and scopes the subscriber
 * name lookup to it).
 */
const listCorrections = asyncHandler(async (req, res) => {
  const filter = { entity: CORRECTION_ENTITY, deleted: false };

  const status = str(req.query.status);
  if (status && CORRECTION_STATUSES.has(status)) filter['data.status'] = status;

  const month = str(req.query.month);
  if (month && MONTH_RE.test(month)) filter['data.month'] = month;

  // Optional single-account scope. Cast EXPLICITLY: the listing runs through an
  // aggregate (for the pending-first sort) and aggregation does NOT apply the
  // schema's ObjectId casting the query layer gives you for free — a raw string
  // here would silently match nothing.
  const userId = str(req.query.userId);
  if (userId && mongoose.isValidObjectId(userId)) {
    filter.user = new mongoose.Types.ObjectId(userId);
  }

  const q = str(req.query.q);
  if (q) {
    const regex = { $regex: escapeRegex(q), $options: 'i' };
    const namedAccounts = await User.find(
      { $or: [{ name: regex }, { generatorName: regex }] },
      { _id: 1 }
    ).lean();
    const subFilter = { entity: 'subscribers', deleted: false, 'data.name': regex };
    if (filter.user) subFilter.user = filter.user;
    const namedSubs = await SyncRecord.find(subFilter, { localId: 1 })
      .limit(SUBSCRIBER_MATCH_CAP)
      .lean();
    // Under $and so it composes with the status/month/user filters above
    // instead of replacing them. Empty $in matches nothing — the right answer
    // when nothing matched, not "match everything".
    filter.$and = (filter.$and || []).concat([
      {
        $or: [
          { localId: regex },
          { 'data.subscriber_id': regex },
          { 'data.reason': regex },
          { 'data.month': regex },
          { user: { $in: namedAccounts.map((a) => a._id) } },
          {
            'data.subscriber_id': {
              $in: namedSubs.map((s) => s.localId).filter((x) => x != null).map(String),
            },
          },
        ],
      },
    ]);
  }

  const page = Math.max(1, parseInt(req.query.page, 10) || 1);
  let limit = parseInt(req.query.limit, 10);
  if (!Number.isFinite(limit) || limit < 1) limit = 25;
  limit = Math.min(200, Math.max(1, limit));

  const total = await SyncRecord.countDocuments(filter);
  // Pending first, then newest requested_at (an ISO string, so a plain
  // descending sort is newest-first), tie-broken on the device UUID so paging
  // is stable when several rows share a timestamp.
  const docs = await SyncRecord.aggregate([
    { $match: filter },
    { $addFields: { pendingRank: { $cond: [{ $eq: ['$data.status', 'pending'] }, 0, 1] } } },
    { $sort: { pendingRank: 1, 'data.requested_at': -1, localId: -1 } },
    { $skip: (page - 1) * limit },
    { $limit: limit },
  ]);

  // Resolve the page's owner accounts in one query (the recentData shape), so a
  // deleted account degrades to null names instead of failing.
  const userIds = [...new Set(docs.map((d) => String(d.user)))];
  const accounts = await User.find({ _id: { $in: userIds } }, { name: 1, generatorName: 1 });
  const byId = new Map(accounts.map((u) => [String(u._id), u]));

  // Subscriber names for the page, one query. Built as an $or of
  // (user, entity, localId) triples so every branch hits the unique compound
  // index — an {entity, localId} match alone cannot use it (the index is
  // prefixed by `user`).
  const pairs = [];
  const seenPairs = new Set();
  for (const d of docs) {
    const subId = str((d.data || {}).subscriber_id);
    if (!subId) continue;
    const key = `${String(d.user)}|${subId}`;
    if (seenPairs.has(key)) continue;
    seenPairs.add(key);
    pairs.push({ user: d.user, entity: 'subscribers', localId: subId });
  }
  const nameByKey = new Map();
  if (pairs.length) {
    const subs = await SyncRecord.find({ $or: pairs }, { user: 1, localId: 1, 'data.name': 1 }).lean();
    for (const s of subs) {
      nameByKey.set(`${String(s.user)}|${s.localId}`, (s.data || {}).name || null);
    }
  }

  // v43 review fix: resolve the RECEIPT NUMBER of the invoice each correction
  // hangs off. The panel's receipt column already prefers a number and falls
  // back to the uuid, but nothing ever supplied the number, so the branch was
  // dead. Same batched {user, entity, localId} shape as the subscriber names
  // above so it stays one query for the whole page.
  const recPairs = [];
  const seenRec = new Set();
  for (const d of docs) {
    const ru = str((d.data || {}).receipt_uuid);
    if (!ru) continue;
    const key = `${String(d.user)}|${ru}`;
    if (seenRec.has(key)) continue;
    seenRec.add(key);
    recPairs.push({ user: d.user, entity: 'receipts', localId: ru });
  }
  const receiptNoByKey = new Map();
  if (recPairs.length) {
    const rcps = await SyncRecord.find(
      { $or: recPairs },
      { user: 1, localId: 1, 'data.receipt_no': 1 }
    ).lean();
    for (const r of rcps) {
      receiptNoByKey.set(`${String(r.user)}|${r.localId}`, numOrNull((r.data || {}).receipt_no));
    }
  }

  // v44: SETTLEMENT STATUS of each correction's difference, DERIVED (never
  // stored) the same way the app's Corrections tab derives it. For an approved
  // INCREASE it asks whether the customer's valid receipts for that month now
  // cover the corrected due (`new_due`); every other status maps directly.
  const covKeys = [];
  const seenCov = new Set();
  for (const d of docs) {
    const data = d.data || {};
    if (correctionStatusOf(data) !== 'approved') continue;
    const sid = str(data.subscriber_id);
    const m = str(data.month);
    if (!sid || !m) continue;
    const key = `${String(d.user)}|${sid}|${m}`;
    if (seenCov.has(key)) continue;
    seenCov.add(key);
    covKeys.push({ user: d.user, entity: 'receipts', deleted: false, 'data.status': 'valid', 'data.subscriber_id': sid, 'data.month': m });
  }
  const coverageByKey = new Map();
  if (covKeys.length) {
    const rcps = await SyncRecord.find({ $or: covKeys }, { user: 1, 'data.subscriber_id': 1, 'data.month': 1, 'data.paid_amount': 1, 'data.discount_value': 1 }).lean();
    for (const r of rcps) {
      const rd = r.data || {};
      const key = `${String(r.user)}|${str(rd.subscriber_id)}|${str(rd.month)}`;
      coverageByKey.set(key, (coverageByKey.get(key) || 0) + (Number(rd.paid_amount) || 0) + (Number(rd.discount_value) || 0));
    }
  }
  // v44 review fix: for an approved increase, `paid` is derived on the SAME
  // formula as the app's Corrections tab (frozen amps x price + in-force
  // delta − coverage), not the stored new_due snapshot — the two diverge as
  // soon as a carried credit or a second correction lands on the month.
  const remainingCache = new Map();
  const remainingFor = async (d) => {
    const data = d.data || {};
    const key = `${String(d.user)}|${str(data.subscriber_id)}|${str(data.month)}`;
    if (!remainingCache.has(key)) {
      remainingCache.set(key, await remainingDueOnMirror(d.user, data.subscriber_id, str(data.month)));
    }
    return remainingCache.get(key);
  };
  const settlementStatusOf = async (d) => {
    const data = d.data || {};
    const st = correctionStatusOf(data);
    if (st === 'pending') return 'awaiting_approval';
    if (st === 'rejected') return 'rejected';
    if (st === 'refund_due') return 'credit';
    if (st === 'completed') return 'refunded';
    if (st === 'carried_forward') return 'carried_forward';
    // approved (an increase): is the extra amount covered by a receipt yet?
    const remaining = await remainingFor(d);
    if (remaining == null) return 'unpaid_difference'; // unpriced: nothing can cover it
    return remaining <= 0 ? 'paid' : 'unpaid_difference';
  };

  const items = [];
  for (const d of docs) {
    const item = serializeCorrection(
      d,
      byId.get(String(d.user)),
      nameByKey.get(`${String(d.user)}|${str((d.data || {}).subscriber_id)}`)
    );
    const ru = str((d.data || {}).receipt_uuid);
    item.receiptNo = ru ? (receiptNoByKey.get(`${String(d.user)}|${ru}`) ?? null) : null;
    // eslint-disable-next-line no-await-in-loop
    item.settlementStatus = await settlementStatusOf(d);
    items.push(item);
  }
  res.status(200).json({
    items,
    total,
    page,
    limit,
  });
});

/**
 * The correction mirror record addressed by `:id` — the SyncRecord Mongo id
 * (what the list returns as `id`), falling back to the device UUID of the
 * `corrections` row so a caller holding only the app's id can act too.
 */
async function findCorrectionRecord(idParam) {
  const raw = str(idParam);
  if (!raw) return null;
  if (mongoose.isValidObjectId(raw)) {
    const byId = await SyncRecord.findOne({ _id: raw, entity: CORRECTION_ENTITY });
    if (byId) return byId;
  }
  return SyncRecord.findOne({ entity: CORRECTION_ENTITY, localId: raw });
}

/** Which wallet the delta belongs to: the corrected invoice's payment method. */
async function adjustmentMethodFor(userId, correction) {
  const uuid = str((correction || {}).receipt_uuid);
  if (!uuid) return 'cash';
  const receipt = await SyncRecord.findOne(
    { user: userId, entity: 'receipts', localId: uuid },
    { 'data.payment_method': 1 }
  ).lean();
  const method = receipt && receipt.data ? receipt.data.payment_method : null;
  // Same COALESCE(payment_method,'cash') convention as every other money query.
  return method === 'card' ? 'card' : 'cash';
}

/**
 * Appends ONE immutable ledger row into the owner's mirror.
 *
 * `$setOnInsert` + the deterministic id IS the append-only rule expressed in
 * MongoDB: if the row already exists (a retry, or the device recorded the same
 * decision first) the STORED row is left byte-for-byte as it was — never
 * re-amounted, never re-signed, never deleted. It is the exact server twin of
 * `CorrectionRepository.insertAdjustment`'s ConflictAlgorithm.ignore.
 */
async function appendAdjustment(userId, { correctionId, correction, kind, amount, accountantId, createdBy }) {
  const localId = adjustmentIdFor(correctionId, kind);
  const nowIso = new Date().toISOString();
  const data = {
    id: localId,
    correction_id: correctionId,
    subscriber_id: (correction || {}).subscriber_id || null,
    month: (correction || {}).month || null,
    branch_id: (correction || {}).branch_id || null,
    accountant_id: accountantId,
    kind,
    amount,
    method: await adjustmentMethodFor(userId, correction),
    created_at: nowIso,
    created_by: createdBy,
    // Per-row edit time for the sync conflict resolver. The row is append-only,
    // so in practice this never changes after the insert.
    updated_at: nowIso,
  };
  await SyncRecord.updateOne(
    { user: userId, entity: ADJUSTMENT_ENTITY, localId },
    { $setOnInsert: { data, deleted: false, updatedAt: new Date() } },
    { upsert: true }
  );
  const stored = await SyncRecord.findOne(
    { user: userId, entity: ADJUSTMENT_ENTITY, localId },
    { data: 1 }
  ).lean();
  return stored ? stored.data : data;
}

/** The decision fields a correction carries, restored verbatim by a revert. */
const DECISION_FIELDS = [
  'status',
  'decided_at',
  'decided_by',
  'decision_note',
  'refund_paid_at',
  'refund_paid_by',
  'updated_at',
];

/**
 * Compensating action: puts a correction back EXACTLY as it was before a
 * decision was stamped, restoring each decision field to its previous value
 * (or $unset when it had none) plus the envelope `updatedAt`.
 *
 * Used only when the LEDGER WRITE that must accompany a decision fails. The
 * alternative orderings are both worse: writing the adjustment first can credit
 * the wallet for a correction someone else rejected in the same instant, and
 * flipping without a revert can leave a correction `approved` with no money row
 * and no way to re-approve it (only a pending correction may be approved). The
 * ledger is append-only, so a surplus row could never be removed — but a
 * decision on our own `corrections` row can always be rolled back.
 */
async function revertCorrectionDecision(recordId, previousData, previousUpdatedAt) {
  const prev = previousData && typeof previousData === 'object' ? previousData : {};
  const set = {};
  const unset = {};
  for (const f of DECISION_FIELDS) {
    if (prev[f] === undefined) unset[`data.${f}`] = '';
    else set[`data.${f}`] = prev[f];
  }
  if (previousUpdatedAt) set.updatedAt = previousUpdatedAt;
  const update = {};
  if (Object.keys(set).length) update.$set = set;
  if (Object.keys(unset).length) update.$unset = unset;
  if (!Object.keys(update).length) return;
  await SyncRecord.updateOne({ _id: recordId }, update);
}

/**
 * Applies a decision to a correction under an ATOMIC status guard and returns
 * the updated record — or throws the right 4xx. `guard` is the `data.status`
 * condition that must still hold (see DECIDED_CORRECTION_STATUSES), so a stale
 * panel tab, a double-click or a second admin can never decide the same
 * correction twice.
 */
async function applyCorrectionDecision(rec, guard, set, notPending) {
  const updated = await SyncRecord.findOneAndUpdate(
    { _id: rec._id, deleted: false, ...guard },
    { $set: set },
    { new: true }
  );
  if (updated) return updated;
  const existing = await SyncRecord.findById(rec._id, { data: 1, deleted: 1 }).lean();
  if (!existing) throw new HttpError(404, 'Correction not found', 'CORRECTION_NOT_FOUND');
  if (existing.deleted) {
    throw new HttpError(409, 'Correction was deleted', 'CORRECTION_DELETED');
  }
  throw new HttpError(
    409,
    `${notPending.message} (it is ${correctionStatusOf(existing.data)})`,
    notPending.code
  );
}

/** The correction record for `:id`, or the right 404/409 — shared preamble. */
async function loadDecidableCorrection(idParam) {
  const rec = await findCorrectionRecord(idParam);
  if (!rec) throw new HttpError(404, 'Correction not found', 'CORRECTION_NOT_FOUND');
  if (rec.deleted) throw new HttpError(409, 'Correction was deleted', 'CORRECTION_DELETED');
  return rec;
}

/** The decided correction + its owner, as the decision routes return it. */
async function decisionResponse(updated) {
  const owner = await User.findById(updated.user, { name: 1, generatorName: 1 });
  return serializeCorrection(updated, owner, null);
}

/**
 * POST /api/admin/corrections/:id/approve   body { note? }
 *
 * Books the correction. ONLY a still-pending correction may be approved (a
 * second call is a 409 no-op), because approving twice would credit the wallet
 * twice. An INCREASE lands `approved`; a DECREASE lands `refund_due` — the cash
 * has NOT been returned yet, and the wallet is deliberately not reduced.
 * Neither branch edits the receipt or the settlement.
 */
const approveCorrection = asyncHandler(async (req, res) => {
  const { note } = req.body || {};
  const rec = await loadDecidableCorrection(req.params.id);

  const data = rec.data && typeof rec.data === 'object' ? rec.data : {};
  const current = correctionStatusOf(data);
  if (current !== 'pending') {
    throw new HttpError(409, `Correction already ${current}`, 'CORRECTION_NOT_PENDING');
  }

  const parsed = numOrNull(data.difference);
  const delta = parsed == null ? 0 : parsed;
  // A zero-difference row (nothing the request path can create, but a legacy or
  // hand-crafted one could) books NO adjustment and is simply approved — never
  // `refund_due`, which would ask the admin to hand back nothing.
  const kind = delta > 0 ? ADJ_INCREASE : delta < 0 ? ADJ_DECREASE : null;
  const nextStatus = delta < 0 ? 'refund_due' : 'approved';

  const nowIso = new Date().toISOString();
  const set = {
    'data.status': nextStatus,
    'data.decided_at': nowIso,
    'data.decided_by': String(req.user._id),
    // Bump the per-row edit time so last-EDIT-wins applies this decision over
    // the device's older pending copy on its next pull.
    'data.updated_at': nowIso,
    updatedAt: new Date(),
  };
  if (note !== undefined) set['data.decision_note'] = note ? String(note).trim() : null;

  const updated = await applyCorrectionDecision(
    rec,
    { 'data.status': { $nin: DECIDED_CORRECTION_STATUSES } },
    set,
    { message: 'Correction is no longer pending', code: 'CORRECTION_NOT_PENDING' }
  );

  let adjustment = null;
  if (kind) {
    try {
      adjustment = await appendAdjustment(rec.user, {
        correctionId: str(data.id) || rec.localId,
        correction: data,
        kind,
        // Stored POSITIVE for both kinds; the SIGN is not what makes a decrease
        // harmless — `correction_decrease` contributes exactly 0 to every
        // wallet figure (see accountController.getWallet and the app's
        // CorrectionRepository.adjustmentTotal). The wallet must never be
        // driven negative by a historical correction.
        amount: Math.abs(delta),
        accountantId: data.accountant_id || null,
        createdBy: String(req.user._id),
      });
    } catch (err) {
      await revertCorrectionDecision(rec._id, data, rec.updatedAt);
      throw err;
    }
  }

  res.status(200).json({ ok: true, correction: await decisionResponse(updated), adjustment });
});

/**
 * POST /api/admin/corrections/:id/reject   body { note }
 *
 * Declines the request and records why. NO adjustment is written and no money
 * moves — the month keeps exactly the figures it already has. Only a pending
 * correction may be rejected.
 */
const rejectCorrection = asyncHandler(async (req, res) => {
  const { note } = req.body || {};
  const rec = await loadDecidableCorrection(req.params.id);

  const current = correctionStatusOf(rec.data);
  if (current !== 'pending') {
    throw new HttpError(409, `Correction already ${current}`, 'CORRECTION_NOT_PENDING');
  }

  const nowIso = new Date().toISOString();
  const set = {
    'data.status': 'rejected',
    'data.decided_at': nowIso,
    'data.decided_by': String(req.user._id),
    'data.updated_at': nowIso,
    updatedAt: new Date(),
  };
  if (note !== undefined) set['data.decision_note'] = note ? String(note).trim() : null;

  const updated = await applyCorrectionDecision(
    rec,
    { 'data.status': { $nin: DECIDED_CORRECTION_STATUSES } },
    set,
    { message: 'Correction is no longer pending', code: 'CORRECTION_NOT_PENDING' }
  );

  res.status(200).json({ ok: true, correction: await decisionResponse(updated) });
});

/**
 * POST /api/admin/corrections/:id/refund-paid
 *
 * Records the PHYSICAL cash return that closes a decrease correction:
 * `refund_due -> completed`, plus one `refund_return` ledger row. Allowed ONLY
 * from `refund_due` — approving a decrease never asserted that money moved,
 * which is why this is a separate operation with its own record, and why a
 * second call is a 409 rather than a second refund.
 *
 * The ledger row is stamped so the return has the RIGHT financial effect and no
 * other: `amount` is NEGATIVE (cash physically left the business, so the
 * month's collected figure falls by it) and `accountant_id` is deliberately
 * NULL — the OWNER/ADMIN returns the cash, not the accountant, and every wallet
 * query filters by `accountant_id`, so no accountant's derived wallet can be
 * driven negative by it. The audit link is unaffected: the row still carries
 * correction_id / subscriber_id / month / branch_id.
 */
const markCorrectionRefundPaid = asyncHandler(async (req, res) => {
  const rec = await loadDecidableCorrection(req.params.id);

  const data = rec.data && typeof rec.data === 'object' ? rec.data : {};
  const current = correctionStatusOf(data);
  if (current !== 'refund_due') {
    throw new HttpError(
      409,
      `Correction is ${current}, not awaiting a cash return`,
      'CORRECTION_NOT_REFUND_DUE'
    );
  }

  const parsed = numOrNull(data.difference);
  const delta = parsed == null ? 0 : parsed;

  const nowIso = new Date().toISOString();
  const set = {
    'data.status': 'completed',
    'data.refund_paid_at': nowIso,
    'data.refund_paid_by': String(req.user._id),
    'data.updated_at': nowIso,
    updatedAt: new Date(),
  };

  const updated = await applyCorrectionDecision(
    rec,
    { 'data.status': 'refund_due' },
    set,
    {
      message: 'Correction is no longer awaiting a cash return',
      code: 'CORRECTION_NOT_REFUND_DUE',
    }
  );

  let adjustment = null;
  try {
    adjustment = await appendAdjustment(rec.user, {
      correctionId: str(data.id) || rec.localId,
      correction: data,
      kind: ADJ_REFUND_RETURN,
      amount: -Math.abs(delta),
      accountantId: null, // see the doc comment — never an accountant wallet
      createdBy: String(req.user._id),
    });
  } catch (err) {
    await revertCorrectionDecision(rec._id, data, rec.updatedAt);
    throw err;
  }

  res.status(200).json({ ok: true, correction: await decisionResponse(updated), adjustment });
});

/**
 * v44 review fix — the target month's REMAINING due for one subscriber, from
 * the mirror, on the app's derivation: frozen amps x price + in-force delta
 * − valid-receipt coverage. Returns null when the month is unpriced for the
 * subscriber's branch/category (nothing to absorb a credit into).
 */
async function remainingDueOnMirror(userId, subscriberId, month) {
  const sid = String(subscriberId);
  const [sub, priceRows, corrRows, adjRows, rcpRows] = await Promise.all([
    SyncRecord.findOne({ user: userId, entity: 'subscribers', localId: sid }, { data: 1 }).lean(),
    SyncRecord.find({ user: userId, entity: 'monthly_prices', deleted: false, 'data.month': month }, { data: 1 }).lean(),
    SyncRecord.find({ user: userId, entity: 'corrections', deleted: false }, { data: 1, localId: 1 }).lean(),
    SyncRecord.find({ user: userId, entity: 'financial_adjustments', deleted: false, 'data.subscriber_id': sid, 'data.month': month }, { data: 1 }).lean(),
    SyncRecord.find({ user: userId, entity: 'receipts', deleted: false, 'data.status': 'valid', 'data.subscriber_id': sid, 'data.month': month }, { data: 1 }).lean(),
  ]);
  const sd = (sub && sub.data) || {};
  const bkey = sd.branch_id || 'main';
  const cat = sd.category || 'standard';
  const price = priceRows.find((p) => ((p.data || {}).branch_id || 'main') === bkey && ((p.data || {}).category || 'standard') === cat);
  if (!price) return null;
  const perAmp = numOrNull((price.data || {}).price_per_amp);
  if (perAmp == null) return null;
  const frozen = buildFrozenAmps(corrRows, month);
  const amps = frozen.ampsFor(sid, Number(sd.amps) || 0);
  let delta = 0;
  for (const a of adjRows) {
    const d = a.data || {};
    const st = frozen.statusOf(d.correction_id);
    if (d.kind === 'correction_increase' && st === 'approved') delta += Number(d.amount) || 0;
    else if (d.kind === 'credit_applied' && st === 'carried_forward') delta -= Number(d.amount) || 0;
  }
  let coverage = 0;
  for (const r of rcpRows) {
    const d = r.data || {};
    coverage += (Number(d.paid_amount) || 0) + (Number(d.discount_value) || 0);
  }
  return amps * perAmp + delta - coverage;
}

/**
 * POST /api/admin/corrections/:id/carry-forward   (v44)
 *
 * Closes a DECREASE by applying its credit to the NEXT month instead of
 * returning cash: `refund_due -> carried_forward`, plus ONE `credit_applied`
 * adjustment whose `month` is the TARGET month. That row reduces the target
 * month's due by the credit (app + dashboard both fold it) and moves NO cash —
 * no wallet changes. Same guarded/reverting shape as refund-paid.
 */
const carryForwardCorrection = asyncHandler(async (req, res) => {
  const rec = await loadDecidableCorrection(req.params.id);

  const data = rec.data && typeof rec.data === 'object' ? rec.data : {};
  const current = correctionStatusOf(data);
  if (current !== 'refund_due') {
    throw new HttpError(
      409,
      `Correction is ${current}, not holding a credit`,
      'CORRECTION_NOT_REFUND_DUE'
    );
  }
  const target = nextMonthOf(data.month);
  if (!target) {
    throw new HttpError(409, 'Correction has no valid month to carry forward from', 'CORRECTION_MONTH_MISSING');
  }

  const parsed = numOrNull(data.difference);
  const delta = parsed == null ? 0 : parsed;
  const credit = Math.abs(delta);

  // v44 review fix — a credit is applied ONLY when the target month can absorb
  // it in full. Otherwise the surplus would be silently destroyed (the app's
  // due would go negative / read as paid with no receipt). Refuse and point
  // to the cash-refund path instead; nothing is written.
  const remaining = await remainingDueOnMirror(rec.user, data.subscriber_id, target);
  if (remaining == null) {
    throw new HttpError(409, `Month ${target} is not priced for this subscriber — nothing to apply the credit to. Record a cash refund instead.`, 'CORRECTION_CARRY_TARGET_UNPRICED');
  }
  if (remaining <= 0) {
    throw new HttpError(409, `Month ${target} is already fully paid — nothing to apply the credit to. Record a cash refund instead.`, 'CORRECTION_CARRY_TARGET_COVERED');
  }
  if (credit > remaining + 0.000001) {
    throw new HttpError(409, `The ${credit} credit exceeds the ${remaining} still owed for ${target}. Record a cash refund instead.`, 'CORRECTION_CARRY_TOO_LARGE');
  }

  const nowIso = new Date().toISOString();
  const set = {
    'data.status': 'carried_forward',
    'data.refund_paid_at': nowIso,
    'data.refund_paid_by': String(req.user._id),
    'data.updated_at': nowIso,
    updatedAt: new Date(),
  };

  const updated = await applyCorrectionDecision(
    rec,
    { 'data.status': 'refund_due' },
    set,
    {
      message: 'Correction is no longer holding a credit',
      code: 'CORRECTION_NOT_REFUND_DUE',
    }
  );

  let adjustment = null;
  try {
    adjustment = await appendAdjustment(rec.user, {
      correctionId: str(data.id) || rec.localId,
      correction: Object.assign({}, data, { month: target }), // applied TO the target month
      kind: ADJ_CREDIT_APPLIED,
      amount: Math.abs(delta),
      accountantId: null, // a due reduction, never a wallet movement
      createdBy: String(req.user._id),
    });
  } catch (err) {
    await revertCorrectionDecision(rec._id, data, rec.updatedAt);
    throw err;
  }

  res.status(200).json({ ok: true, correction: await decisionResponse(updated), adjustment, targetMonth: target });
});

module.exports = {
  carryForwardCorrection,
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
  // v43 — corrections after invoicing.
  listCorrections,
  approveCorrection,
  rejectCorrection,
  markCorrectionRefundPaid,
};
