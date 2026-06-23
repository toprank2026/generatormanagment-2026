'use strict';

const SyncRecord = require('../models/SyncRecord');
const User = require('../models/User');
const asyncHandler = require('../utils/asyncHandler');
const { listUserData, labelFor } = require('./adminController');
const { effectiveOwnerId } = require('../utils/effectiveOwner');

/** Entities getMyStats always reports a count for (missing in mirror = 0). */
const STAT_ENTITIES = [
  'subscribers',
  'boards',
  'circuits',
  'receipts',
  'expenses',
  'monthly_prices',
  'accountants',
  'branches',
  'settlements',
];

/**
 * GET /api/account/data?entity=E&q=&page=1&limit=25[&includeDeleted=true]
 *
 * Owner self-service view of the **caller's own** synced mirror (any role).
 * Same query params and response shape as GET /api/admin/users/:id/data, but
 * always scoped to the JWT user. Read-only — there is no delete counterpart.
 */
const getMyData = asyncHandler(async (req, res) => {
  // Accountants read the OWNER's mirror (effective owner); owners/admins their own.
  res.status(200).json(await listUserData(effectiveOwnerId(req.user), req.query));
});

/** Coerce a mirrored (untyped) value to a finite number, defaulting to 0. */
const num = (value) => {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
};

/**
 * Builds the app-style dashboard for the caller's mirror, replicating the
 * Flutter dashboard for month M. Pricing is category-aware: a per-category
 * price map P = { [category]: price_per_amp } is built from the month's
 * monthly_prices (legacy/missing categories default to 'standard'; absent = 0).
 * A subscriber's due = amps * P[category]; it is PAID when its month-M coverage
 * (Σ paid_amount + Σ discount_value of its receipts) is >= that due — so a
 * discounted FULL payment counts as fully paid, and with no price every
 * subscriber counts as paid, exactly like the app. The expected total is
 * Σ amps × P[category] over the in-scope subscribers; totalDue is kept raw
 * (expected - collected - Σ discount_value), which may go negative, matching the
 * app. The discount is WAIVED money: it folds into the DUE side only and is
 * NEVER added to `collected`/revenue/profit. The full per-category map is also
 * returned as `categoryPrices` so the panel can render all three tariffs.
 *
 * @param {*} userId Mongo id of the caller.
 * @param {object} counts Per-entity counts (reused for boards/circuits).
 * @param {string} month The month to report on, 'YYYY-MM' (already validated).
 * @param {string|null} accountantId When set, scope the MONEY figures to that
 *   one accountant (receipts/expenses with data.accountant_id == it);
 *   null = the whole owner account (all accountants).
 * @param {string|null} branchId When set, scope EVERY figure to that one branch
 *   (full isolation — subscribers/boards/circuits/receipts/expenses/price with
 *   data.branch_id == it); null = consolidated / all branches.
 * @returns {Promise<object>} The `dashboard` payload for GET /api/account/stats.
 */
async function buildDashboard(userId, counts, month, accountantId = null, branchId = null) {
  // Branch is the outer partition (full isolation): when branchId is set, every
  // query is scoped to that branch. Accountant is the inner MONEY scope
  // (collected/expenses), applied in JS. monthly_prices is per-branch (its PK
  // is "<month>|<branchId>") so we match it by data.month + branch.
  const branchMatch = branchId ? { 'data.branch_id': branchId } : {};
  const [priceRows, subscribers, receipts, expenses, lastUpload, boardsCount, circuitsCount] = await Promise.all([
    // Per-branch, per-category monthly prices (matched by data.month + branch;
    // legacy rows that predate per-branch pricing carry no branch_id and only
    // match consolidated). One row per category — we build a category→price map.
    SyncRecord.find(
      { user: userId, entity: 'monthly_prices', deleted: false, 'data.month': month, ...branchMatch },
      { data: 1 }
    ),
    SyncRecord.find(
      { user: userId, entity: 'subscribers', deleted: false, ...branchMatch },
      { data: 1, localId: 1 }
    ),
    // Non-refunded receipts for the month in this branch — drives paid/unpaid.
    SyncRecord.find(
      {
        user: userId,
        entity: 'receipts',
        deleted: false,
        'data.month': month,
        'data.status': { $ne: 'refunded' },
        ...branchMatch,
      },
      { data: 1 }
    ),
    // Expense rows for the month in this branch; scoped in JS for the total.
    SyncRecord.find(
      { user: userId, entity: 'expenses', deleted: false, 'data.date': { $regex: '^' + month }, ...branchMatch },
      { data: 1 }
    ),
    // Most recent sync activity of any kind (incl. deletions) — "last upload".
    SyncRecord.findOne({ user: userId }, { updatedAt: 1 }).sort({ updatedAt: -1 }),
    // Boards/circuits counts (branch-scoped).
    SyncRecord.countDocuments({ user: userId, entity: 'boards', deleted: false, ...branchMatch }),
    SyncRecord.countDocuments({ user: userId, entity: 'circuits', deleted: false, ...branchMatch }),
  ]);

  // Per-branch, per-category price map keyed by "<branchKey>|<category>" where
  // branchKey = data.branch_id || 'main' (the app's IFNULL(branch_id,'main')
  // convention). This preserves each branch's OWN tariffs in the CONSOLIDATED
  // (branchId=null) view — previously all branches collapsed into one category
  // map and the last row won, so per-branch pricing was lost. In single-branch
  // mode (branchId set) every row shares one branchKey, so behavior is unchanged.
  const priceByBranchCat = {};
  // A flat per-category map for the REPORTED branch (single-branch view) or, when
  // consolidated, the merged category prices — used only for the back-compat
  // pricePerAmp / categoryPrices payload fields, NOT for per-subscriber math.
  const reportedPriceMap = {};
  for (const row of priceRows) {
    const pd = row.data || {};
    const cat = pd.category || 'standard';
    const bkey = pd.branch_id || 'main';
    const price = num(pd.price_per_amp ?? pd.price ?? 0);
    priceByBranchCat[`${bkey}|${cat}`] = price;
    // For the reported map, prefer the explicitly-requested branch; when
    // consolidated, the last seen price per category (display only).
    if (!branchId || bkey === branchId) reportedPriceMap[cat] = price;
  }
  const priceFor = (bid, cat) =>
    num(priceByBranchCat[`${bid || 'main'}|${cat || 'standard'}`] || 0);

  // Back-compat single price reported in the payload: prefer 'standard', else the
  // first category present (or 0). Per-subscriber math below uses priceByBranchCat.
  const pricePerAmp =
    reportedPriceMap.standard != null
      ? reportedPriceMap.standard
      : num(Object.values(reportedPriceMap)[0] ?? 0);
  const priceMap = reportedPriceMap;

  // True when a row belongs to the selected accountant (or no filter set).
  const inScope = (data) => !accountantId || (data || {}).accountant_id === accountantId;

  // paidBySubscriber uses ALL receipts (paid/unpaid is global); `collected` is
  // the selected accountant's own receipts (or all when unfiltered).
  // A discount is WAIVED money (NOT collected): it never counts toward
  // `collected`/revenue, but it DOES count toward a subscriber's coverage
  // (paid_amount + discount_value) for paid/unpaid, and reduces what is still
  // owed. discountTotal is the in-scope Σ discount_value for the due side.
  let collected = 0;
  let discountTotal = 0;
  const coverageBySubscriber = new Map();
  for (const r of receipts) {
    const data = r.data || {};
    const paid = num(data.paid_amount);
    const discount = num(data.discount_value); // legacy receipts -> 0
    // v14 (item 3): coverage (paid/unpaid) honors the accountant scope, so a
    // per-accountant report shows the subscribers THAT accountant collected from.
    // When accountantId is null (overall/branch report) inScope() is always true,
    // so this is byte-identical to the prior global behavior — no regression.
    if (inScope(data)) {
      collected += paid;
      discountTotal += discount;
      const sid = data.subscriber_id;
      // Coverage folds the waived discount in so a discounted FULL payment counts
      // as fully paid (coverage = paid_amount + discount_value >= due).
      if (sid != null) {
        coverageBySubscriber.set(sid, (coverageBySubscriber.get(sid) || 0) + paid + discount);
      }
    }
  }

  let totalAmps = 0;
  let expected = 0; // Σ amps × priceMap[category] over all in-scope subscribers.
  let paidCount = 0;
  // Per-tariff PAID counts so the owner panel reports match the app (which shows
  // gold/standard/commercial paid counts). Unknown/legacy category => 'standard'.
  const paidByCategory = { gold: 0, standard: 0, commercial: 0 };
  for (const s of subscribers) {
    const data = s.data || {};
    const amps = num(data.amps);
    totalAmps += amps;
    // Price from the subscriber's OWN branch + category (consolidated view keeps
    // per-branch tariffs distinct). In single-branch mode all rows share one
    // branchKey so this is identical to the old per-category lookup.
    const catPrice = priceFor(data.branch_id, data.category);
    const due = amps * catPrice;
    expected += due;
    const coverage = coverageBySubscriber.get(data.id || s.localId) || 0;
    if (coverage >= due) {
      paidCount += 1;
      const cat = paidByCategory[data.category] !== undefined ? data.category : 'standard';
      paidByCategory[cat] += 1;
    }
  }

  // Expenses total scoped to the selected accountant (or all when unfiltered).
  let expensesTotal = 0;
  for (const e of expenses) {
    if (inScope(e.data)) expensesTotal += num((e.data || {}).amount);
  }

  // Category-aware due: expected (Σ per-category) minus what was collected AND
  // minus the waived discount (discount reduces what is still owed without ever
  // counting as collected). Kept raw (no clamp) to match the prior behavior and
  // the app — it may go negative.
  const remaining = expected - collected - discountTotal;

  return {
    month,
    pricePerAmp,
    // Per-category ampere price map { gold, standard, commercial, ... } so the
    // reports view can render all three tariffs (pricePerAmp stays for back-compat).
    categoryPrices: priceMap,
    totalSubscribers: subscribers.length,
    totalAmps,
    paidCount,
    unpaidCount: subscribers.length - paidCount,
    // Per-tariff paid counts (owner-panel reports parity with the app).
    paidByCategory,
    totalDue: remaining,
    collected,
    // Explicit aliases for the app/panels: revenue = collected valid receipts
    // (discount NOT included — it is waived), remaining = expected (category-aware)
    // − collected − waived discount.
    monthlyRevenue: collected,
    monthlyRemaining: remaining,
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
  // The caller's explicit ?month=YYYY-MM is honored as-is; only an absent or
  // malformed value falls back to the current month (server UTC). The UTC
  // fallback can differ from the device's local month near a month boundary, so
  // the app always passes its own selected month explicitly.
  const requested = String(req.query.month || '');
  const month = /^\d{4}-\d{2}$/.test(requested)
    ? requested
    : new Date().toISOString().slice(0, 7); // 'YYYY-MM' (UTC)

  // Accountants resolve to the OWNER's mirror (effective owner); owners/admins
  // to their own.
  const ownerId = effectiveOwnerId(req.user);

  // Optional owner filters: scope the dashboard to one accountant and/or one
  // branch (full isolation). Both default to null = whole account / all branches.
  const accId = String(req.query.accountantId || '').trim() || null;
  const branchId = String(req.query.branchId || '').trim() || null;

  const counts = {};
  for (const entity of STAT_ENTITIES) counts[entity] = 0;
  if (branchId) {
    // Branch selected -> the per-entity COUNT cards must reflect that branch
    // only (full isolation), mirroring the branch-scoped dashboard below.
    const rows = await SyncRecord.aggregate([
      { $match: { user: ownerId, deleted: false, 'data.branch_id': branchId } },
      { $group: { _id: '$entity', count: { $sum: 1 } } },
    ]);
    for (const row of rows) counts[row._id] = row.count;
    // accountants carry no data.branch_id -> resolve via the authoritative
    // User.branchId (same rule as the accountants list, adminController.js).
    counts.accountants = await User.countDocuments({ owner: ownerId, role: 'accountant', branchId });
    // branches: the count of branch definitions (the switcher itself), not
    // branch-scoped — keep the full count so the card stays meaningful.
    counts.branches = await SyncRecord.countDocuments({ user: ownerId, entity: 'branches', deleted: false });
  } else {
    const rows = await SyncRecord.aggregate([
      { $match: { user: ownerId, deleted: false } },
      { $group: { _id: '$entity', count: { $sum: 1 } } },
    ]);
    for (const row of rows) counts[row._id] = row.count;
  }

  const dashboard = await buildDashboard(ownerId, counts, month, accId, branchId);

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

  // Accountants see the OWNER's recent uploads (effective owner); owners/admins
  // their own.
  const filter = { user: effectiveOwnerId(req.user), deleted: false };
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

/**
 * GET /api/account/wallet (auth) — v12 per-method accountant wallet, computed
 * SERVER-SIDE from the full mirror (authoritative across all months, unaffected
 * by the device's current-month receipt scope). For an accountant: their own
 * figures; for an owner: the owner-collected (accountant_id null) figures.
 *
 * Two wallets are tracked, bucketed by payment method M ('cash'|'card'):
 *  collected(M) = Σ paid_amount of valid receipts whose (payment_method||'cash')==M;
 *  settled(M)   = Σ amount of approved settlements whose (method||'cash')==M;
 *  balance(M)   = collected(M) − settled(M).
 * The top-level { collected, settled, balance } mirror the CASH wallet for
 * backward-compat with any old client that predates the per-method split.
 */
const getWallet = asyncHandler(async (req, res) => {
  const ownerId = effectiveOwnerId(req.user);
  const acctId =
    req.user.role === 'accountant'
      ? (req.user.localId || String(req.user._id))
      : null;

  const recFilter = { user: ownerId, entity: 'receipts', deleted: false, 'data.status': 'valid' };
  if (acctId) recFilter['data.accountant_id'] = acctId;
  const receipts = await SyncRecord.find(recFilter).lean();
  const collected = { cash: 0, card: 0 };
  for (const r of receipts) {
    const d = r.data || {};
    const method = (d.payment_method || 'cash') === 'card' ? 'card' : 'cash';
    collected[method] += Number(d.paid_amount) || 0;
  }

  const setFilter = { user: ownerId, entity: 'settlements', deleted: false, 'data.status': 'approved' };
  if (acctId) setFilter['data.accountant_id'] = acctId;
  const setts = await SyncRecord.find(setFilter).lean();
  const settled = { cash: 0, card: 0 };
  for (const s of setts) {
    const d = s.data || {};
    const method = (d.method || 'cash') === 'card' ? 'card' : 'cash';
    settled[method] += Number(d.amount) || 0;
  }

  const wallet = (m) => ({
    collected: collected[m],
    settled: settled[m],
    balance: collected[m] - settled[m],
  });
  const cash = wallet('cash');
  const card = wallet('card');

  res.status(200).json({
    cash,
    card,
    // Top-level = cash wallet for backward-compat with pre-v12 clients.
    collected: cash.collected,
    settled: cash.settled,
    balance: cash.balance,
  });
});

module.exports = {
  getMyData,
  getMyStats,
  getMyRecent,
  getWallet,
  // Exported so the per-branch owner-panel endpoints can reuse the exact same
  // dashboard math + stat-entity list, scoped to a branch user's mirror.
  buildDashboard,
  STAT_ENTITIES,
};
