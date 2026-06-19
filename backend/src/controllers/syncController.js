'use strict';

const SyncRecord = require('../models/SyncRecord');
const asyncHandler = require('../utils/asyncHandler');
const { HttpError } = require('../middleware/error');
const { effectiveOwnerId } = require('../utils/effectiveOwner');

/**
 * The entities the device may sync into the mirror — the server-side mirror of
 * DbHelper.syncedTables. A push for any other entity is rejected (400) so a
 * tampered/old client cannot create arbitrary collections in the owner mirror.
 */
const SYNCED_ENTITIES = new Set([
  'subscribers',
  'boards',
  'circuits',
  'receipts',
  'refunds',
  'expenses',
  'monthly_prices',
  'branches',
  'accountants',
]);

/**
 * Maps an entity to the accountant permission required to write it.
 *  - `null`  => always allowed for an accountant (the cashier core job:
 *               recording payments / refunds).
 *  - `false` => owner-only; an accountant can NEVER write it (identity tables).
 *  - string  => the permission key the accountant.permissions must include.
 * Mirrors lib/core/permissions.dart (subscribers/boards/expenses/prices).
 */
const ENTITY_PERMISSION = {
  subscribers: 'subscribers',
  boards: 'boards',
  circuits: 'boards',
  monthly_prices: 'prices',
  expenses: 'expenses',
  receipts: null,
  refunds: null,
  branches: false,
  accountants: false,
};

/**
 * Authorize + (for accountants) server-stamp a single pushed record in place.
 * Owners/admins are unrestricted. For an accountant caller this enforces the
 * server-side authorization that the Flutter UI does cosmetically:
 *  - the entity must be one the accountant's permissions allow (identity tables
 *    branches/accountants are owner-only -> 403);
 *  - branch-confined accountants may only write rows in their OWN branch; their
 *    data.branch_id and data.accountant_id are server-stamped (never trusted
 *    from the client) so cross-branch / cross-accountant rows cannot be forged.
 *
 * @throws {HttpError} 403 when the accountant lacks the permission/branch.
 */
function authorizeRecord(user, rec) {
  if (!user || user.role !== 'accountant') return; // owners/admins unrestricted

  const required = ENTITY_PERMISSION[rec.entity];
  if (required === false) {
    throw new HttpError(403, `accountants cannot write ${rec.entity}`, 'ENTITY_FORBIDDEN');
  }
  if (required) {
    const perms = Array.isArray(user.permissions) ? user.permissions : [];
    if (!perms.includes(required)) {
      throw new HttpError(403, `missing permission: ${required}`, 'PERMISSION_DENIED');
    }
  }

  // Branch-confined accountants are pinned to their own branch. Don't trust the
  // client's data.branch_id / data.accountant_id — server-stamp them.
  if (user.branchId && rec.data && typeof rec.data === 'object') {
    if (rec.data.branch_id != null && rec.data.branch_id !== user.branchId) {
      throw new HttpError(403, 'cannot write another branch', 'BRANCH_FORBIDDEN');
    }
    rec.data.branch_id = user.branchId;
    // Stamp the APP-side accountant id (localId) — every business row's
    // accountant_id is the device-mirror accountant UUID, and on-device
    // attribution + printed receipt names resolve via accountants.id == localId.
    // The Mongo _id exists nowhere in the accountants identity table, so
    // stamping it would null out attribution after a pull. Fall back to _id only
    // for the (unexpected) localId-less accountant.
    rec.data.accountant_id = user.localId || String(user._id);
  }
}

/**
 * Per-row edit time used for conflict resolution. The client stamps each
 * business row's REAL modification time into `data.updated_at` (ISO string).
 * The envelope `updatedAt` is the upload time (used only for the pull `since`
 * cursor), so it is NOT a reliable causality signal — prefer `data.updated_at`.
 * Returns a comparable epoch-ms number, or null when absent/unparseable.
 */
function editTimeMs(data) {
  if (!data || typeof data !== 'object') return null;
  const raw = data.updated_at;
  if (raw == null) return null;
  const t = new Date(raw).getTime();
  return Number.isNaN(t) ? null : t;
}

/**
 * POST /api/sync/push (auth)
 * Body: { records: [ { entity, localId, deleted, updatedAt, data? } ] }
 *
 * Upserts each record into the per-account mirror keyed by (user, entity,
 * localId), setting data/deleted/updatedAt. Rejects unknown entities (400) and
 * enforces per-accountant entity/branch authorization (403). Returns
 * { ok, count, serverTime }.
 *
 * Conflict resolution (last-EDIT-wins + sticky tombstones), per-row, server
 * side. BACKWARD-COMPATIBLE: when the per-row edit time (`data.updated_at`) is
 * absent on EITHER side, the old apply-always behavior is kept so nothing today
 * breaks. A SKIPPED record is still counted as accepted so the device drains its
 * outbox and does not loop re-pushing the same stale row.
 */
const push = asyncHandler(async (req, res) => {
  const { records } = req.body || {};
  if (!Array.isArray(records)) {
    throw new HttpError(400, 'records must be an array', 'BAD_RECORDS');
  }

  // Accountants push into the OWNER's mirror (effective owner); owners/admins
  // into their own.
  const userId = effectiveOwnerId(req.user);
  let count = 0;

  for (const rec of records) {
    if (!rec || typeof rec.entity !== 'string' || typeof rec.localId !== 'string') {
      throw new HttpError(400, 'each record needs entity and localId', 'BAD_RECORD');
    }
    // Whitelist the entity against the known synced tables.
    if (!SYNCED_ENTITIES.has(rec.entity)) {
      throw new HttpError(400, `unknown entity: ${rec.entity}`, 'BAD_ENTITY');
    }
    // Accountant authorization + server-stamp branch/accountant (mutates rec.data).
    authorizeRecord(req.user, rec);

    const deleted = Boolean(rec.deleted);
    const updatedAt = rec.updatedAt ? new Date(rec.updatedAt) : new Date();
    // Store the raw SQLite row as-is; tombstones may omit `data`.
    const data = rec.data ?? null;

    // Read the current mirror doc first so we can compare edit times and protect
    // tombstones. (Per-record read; the records array is small in practice.)
    // eslint-disable-next-line no-await-in-loop
    const existing = await SyncRecord.findOne({
      user: userId,
      entity: rec.entity,
      localId: rec.localId,
    });

    if (existing) {
      const incomingMs = editTimeMs(data);
      // For the stale-upsert guard we compare ONLY per-row edit times
      // (data.updated_at) — back-comp: if EITHER side lacks one we apply.
      const storedEditMs = editTimeMs(existing.data);

      if (deleted) {
        // A DELETE always tombstones — never un-delete-protected. (Deletes carry
        // no data; we still bump the envelope updatedAt for the pull cursor.)
        // Falls through to the apply below.
      } else if (existing.deleted === true) {
        // STICKY TOMBSTONE: only revive a deleted row when the incoming edit is
        // strictly NEWER than the recorded delete. The delete carried no data, so
        // fall back to the envelope updatedAt for the stored delete time. Absent
        // an incoming edit time -> SKIP so a stale (or untimestamped) edit can
        // never resurrect a deleted row.
        const storedDeleteMs =
          storedEditMs ?? (existing.updatedAt ? existing.updatedAt.getTime() : null);
        if (incomingMs == null || storedDeleteMs == null || !(incomingMs > storedDeleteMs)) {
          count += 1; // accepted/no-op so the device clears its outbox
          continue;
        }
      } else if (incomingMs != null && storedEditMs != null && incomingMs < storedEditMs) {
        // LAST-EDIT-WINS: a STALE upsert (older edit time) must not clobber a
        // newer stored row. Back-comp: if EITHER side lacks a per-row edit time
        // we fall through and apply (old apply-always behavior).
        count += 1; // accepted/no-op so the device clears its outbox
        continue;
      }
    }

    // eslint-disable-next-line no-await-in-loop
    await SyncRecord.findOneAndUpdate(
      { user: userId, entity: rec.entity, localId: rec.localId },
      { $set: { data, deleted, updatedAt }, $setOnInsert: { user: userId, entity: rec.entity, localId: rec.localId } },
      { new: true, upsert: true, setDefaultsOnInsert: true }
    );
    count += 1;
  }

  res.status(200).json({ ok: true, count, serverTime: new Date().toISOString() });
});

/**
 * GET /api/sync/pull?since=ISO (auth)
 * Returns { records: [ { entity, localId, deleted, updatedAt, data } ] } for the
 * current account, updated since `since` (defaults to all). Used by a new device
 * to restore the mirror.
 */
const pull = asyncHandler(async (req, res) => {
  // Accountants pull the OWNER's mirror (effective owner); owners/admins their own.
  const filter = { user: effectiveOwnerId(req.user) };

  if (req.query.since) {
    const since = new Date(req.query.since);
    if (Number.isNaN(since.getTime())) {
      throw new HttpError(400, 'invalid since timestamp', 'BAD_SINCE');
    }
    filter.updatedAt = { $gt: since };
  }

  // A branch-confined accountant only sees its OWN branch's rows, plus the
  // branch-agnostic identity tables it needs (branches/accountants) and any
  // legacy rows that carry no branch_id. Owners/admins are unaffected.
  if (req.user && req.user.role === 'accountant' && req.user.branchId) {
    filter.$or = [
      { 'data.branch_id': req.user.branchId },
      { entity: { $in: ['branches', 'accountants'] } },
      { 'data.branch_id': { $exists: false } },
      { 'data.branch_id': null },
    ];
  }

  const docs = await SyncRecord.find(filter).sort({ updatedAt: 1 });
  const records = docs.map((d) => ({
    entity: d.entity,
    localId: d.localId,
    deleted: d.deleted,
    updatedAt: d.updatedAt ? d.updatedAt.toISOString() : null,
    data: d.data,
  }));

  res.status(200).json({ records });
});

module.exports = { push, pull, SYNCED_ENTITIES, ENTITY_PERMISSION, authorizeRecord };
