'use strict';

const SyncRecord = require('../models/SyncRecord');
const asyncHandler = require('../utils/asyncHandler');
const { HttpError } = require('../middleware/error');
const { effectiveOwnerId } = require('../utils/effectiveOwner');

/**
 * POST /api/sync/push (auth)
 * Body: { records: [ { entity, localId, deleted, updatedAt, data? } ] }
 *
 * Upserts each record into the per-account mirror keyed by (user, entity,
 * localId), setting data/deleted/updatedAt. Returns { ok, count, serverTime }.
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

    const deleted = Boolean(rec.deleted);
    const updatedAt = rec.updatedAt ? new Date(rec.updatedAt) : new Date();
    // Store the raw SQLite row as-is; tombstones may omit `data`.
    const data = rec.data ?? null;

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

module.exports = { push, pull };
