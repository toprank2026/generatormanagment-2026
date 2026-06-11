'use strict';

const SyncRecord = require('../models/SyncRecord');
const asyncHandler = require('../utils/asyncHandler');
const { listUserData, labelFor } = require('./adminController');

/** Entities getMyStats always reports a count for (missing in mirror = 0). */
const STAT_ENTITIES = [
  'subscribers',
  'boards',
  'circuits',
  'receipts',
  'expenses',
  'monthly_prices',
];

/**
 * GET /api/account/data?entity=E&q=&page=1&limit=25[&includeDeleted=true]
 *
 * Owner self-service view of the **caller's own** synced mirror (any role).
 * Same query params and response shape as GET /api/admin/users/:id/data, but
 * always scoped to the JWT user. Read-only — there is no delete counterpart.
 */
const getMyData = asyncHandler(async (req, res) => {
  res.status(200).json(await listUserData(req.user._id, req.query));
});

/**
 * GET /api/account/stats
 *
 * Per-entity counts of the caller's non-deleted mirrored rows, for the owner
 * panel dashboard. Entities with no rows are reported as 0.
 */
const getMyStats = asyncHandler(async (req, res) => {
  const rows = await SyncRecord.aggregate([
    { $match: { user: req.user._id, deleted: false } },
    { $group: { _id: '$entity', count: { $sum: 1 } } },
  ]);

  const counts = {};
  for (const entity of STAT_ENTITIES) counts[entity] = 0;
  for (const row of rows) counts[row._id] = row.count;

  res.status(200).json({ counts });
});

/**
 * GET /api/account/recent?limit=10
 *
 * The caller's most recently uploaded (synced) records, newest first — shown
 * on the owner panel home so the owner sees what the app last sent.
 */
const getMyRecent = asyncHandler(async (req, res) => {
  const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 10, 1), 50);
  const page = Math.max(parseInt(req.query.page, 10) || 1, 1);

  const filter = { user: req.user._id, deleted: false };
  const total = await SyncRecord.countDocuments(filter);
  const records = await SyncRecord.find(filter)
    .sort({ updatedAt: -1 })
    .skip((page - 1) * limit)
    .limit(limit);

  res.status(200).json({
    items: records.map((r) => ({
      entity: r.entity,
      localId: r.localId,
      updatedAt: r.updatedAt,
      label: labelFor(r.entity, r.data),
    })),
    total,
    page,
    limit,
  });
});

module.exports = {
  getMyData,
  getMyStats,
  getMyRecent,
};
