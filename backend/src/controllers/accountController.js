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
  'accountants',
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

/** Coerce a mirrored (untyped) value to a finite number, defaulting to 0. */
const num = (value) => {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
};

/**
 * Builds the app-style dashboard for the caller's mirror, replicating the
 * Flutter dashboard for month M with P = monthly_prices[M]
 * (0 if absent): a subscriber is PAID when the sum of their month-M receipts'
 * paid_amount is >= amps * P — so with P = 0 every subscriber counts as paid,
 * exactly like the app. totalDue is kept raw (totalAmps * P - collected),
 * which may go negative, again matching the app.
 *
 * @param {*} userId Mongo id of the caller.
 * @param {object} counts Per-entity counts (reused for boards/circuits).
 * @param {string} month The month to report on, 'YYYY-MM' (already validated).
 * @param {string|null} accountantId When set, scope every figure to that one
 *   accountant (subscribers/receipts/expenses with data.accountant_id == it);
 *   null = the whole owner account (all accountants). monthly_prices stays
 *   global (one shared price per month).
 * @returns {Promise<object>} The `dashboard` payload for GET /api/account/stats.
 */
async function buildDashboard(userId, counts, month, accountantId = null) {
  // Optional per-accountant filter, merged into the entity queries.
  const acc = accountantId ? { 'data.accountant_id': accountantId } : {};
  const [priceRow, subscribers, receipts, expenses, lastUpload, boardsCount, circuitsCount] = await Promise.all([
    // monthly_prices' device PK is the month string, so localId === month.
    SyncRecord.findOne(
      { user: userId, entity: 'monthly_prices', deleted: false, localId: month },
      { data: 1 }
    ),
    SyncRecord.find(
      { user: userId, entity: 'subscribers', deleted: false, ...acc },
      { data: 1, localId: 1 }
    ),
    // Only non-refunded receipts count toward collected + paid/unpaid, matching
    // the app (a refunded receipt must not inflate the totals). $ne also keeps
    // receipts with no explicit status (treated as valid).
    SyncRecord.find(
      {
        user: userId,
        entity: 'receipts',
        deleted: false,
        'data.month': month,
        'data.status': { $ne: 'refunded' },
        ...acc,
      },
      { data: 1 }
    ),
    // Expense rows whose data.date starts with the month ('YYYY-MM...').
    // month is validated digits+dash, so the regex needs no escaping.
    SyncRecord.find(
      { user: userId, entity: 'expenses', deleted: false, 'data.date': { $regex: '^' + month }, ...acc },
      { data: 1 }
    ),
    // Most recent sync activity of any kind (incl. deletions) — "last upload".
    SyncRecord.findOne({ user: userId }, { updatedAt: 1 }).sort({ updatedAt: -1 }),
    // Boards/circuits counts (scoped to the accountant when filtering).
    SyncRecord.countDocuments({ user: userId, entity: 'boards', deleted: false, ...acc }),
    SyncRecord.countDocuments({ user: userId, entity: 'circuits', deleted: false, ...acc }),
  ]);

  const priceData = (priceRow && priceRow.data) || {};
  const pricePerAmp = num(priceData.price_per_amp ?? priceData.price ?? 0);

  // Sum paid_amount per subscriber for this month (and the overall total).
  let collected = 0;
  const paidBySubscriber = new Map();
  for (const r of receipts) {
    const data = r.data || {};
    const paid = num(data.paid_amount);
    collected += paid;
    const sid = data.subscriber_id;
    if (sid != null) paidBySubscriber.set(sid, (paidBySubscriber.get(sid) || 0) + paid);
  }

  let totalAmps = 0;
  let paidCount = 0;
  for (const s of subscribers) {
    const data = s.data || {};
    const amps = num(data.amps);
    totalAmps += amps;
    const paid = paidBySubscriber.get(data.id || s.localId) || 0;
    if (paid >= amps * pricePerAmp) paidCount += 1;
  }

  let expensesTotal = 0;
  for (const e of expenses) expensesTotal += num((e.data || {}).amount);

  return {
    month,
    pricePerAmp,
    totalSubscribers: subscribers.length,
    totalAmps,
    paidCount,
    unpaidCount: subscribers.length - paidCount,
    totalDue: totalAmps * pricePerAmp - collected,
    collected,
    expensesTotal,
    netProfit: collected - expensesTotal,
    boards: boardsCount,
    circuits: circuitsCount,
    lastUploadAt: lastUpload ? lastUpload.updatedAt : null,
  };
}

/**
 * GET /api/account/stats[?month=YYYY-MM]
 *
 * Per-entity counts of the caller's non-deleted mirrored rows, plus an
 * app-style `dashboard` object (paid/unpaid/collected/due/expenses/net —
 * see buildDashboard) for the requested month (`?month=YYYY-MM`, defaulting
 * to the current UTC month when absent or malformed), for the owner panel
 * dashboard and monthly reports. Entities with no rows are reported as 0.
 */
const getMyStats = asyncHandler(async (req, res) => {
  const requested = String(req.query.month || '');
  const month = /^\d{4}-\d{2}$/.test(requested)
    ? requested
    : new Date().toISOString().slice(0, 7); // 'YYYY-MM' (UTC)

  const rows = await SyncRecord.aggregate([
    { $match: { user: req.user._id, deleted: false } },
    { $group: { _id: '$entity', count: { $sum: 1 } } },
  ]);

  const counts = {};
  for (const entity of STAT_ENTITIES) counts[entity] = 0;
  for (const row of rows) counts[row._id] = row.count;

  // Optional admin/owner filter: scope the dashboard to one accountant.
  const accId = String(req.query.accountantId || '').trim() || null;
  const dashboard = await buildDashboard(req.user._id, counts, month, accId);

  res.status(200).json({ counts, dashboard });
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
