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
  'settlements',
  // v43 (corrections after invoicing): the two new append-beside tables. An
  // UNKNOWN entity throws 400 for the WHOLE batch (see push below), so the
  // device outbox would never drain and — because pull() pushes first — that
  // device's synchronisation would stop permanently. THIS REGISTRATION MUST BE
  // DEPLOYED BEFORE A SINGLE v43 APK IS INSTALLED, not simultaneously. It is
  // inert until an app actually pushes such a row, so shipping it early is safe.
  'corrections',
  'financial_adjustments',
]);

/**
 * Maps an entity to the accountant permission required to write it.
 *  - `null`  => always allowed for an accountant (the cashier core job:
 *               recording payments / refunds).
 *  - `false` => owner-only; an accountant can NEVER write it (the identity
 *               tables, and v43's money ledger `financial_adjustments`).
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
  // Wallet settlements are core accountant work (like receipts): always allowed.
  // authorizeRecord then server-stamps branch_id + accountant_id for a
  // branch-confined accountant, so a settlement request cannot be forged for
  // another branch/accountant.
  settlements: null,
  branches: false,
  accountants: false,
  // v43: a correction is a REQUEST, not money. It is core accountant work like a
  // settlement request (`null` = always allowed) and must NOT be gated on the
  // 'subscribers' permission: the correction flow is precisely the escape hatch
  // for an accountant who may NOT edit a locked/invoiced subscriber, so gating
  // it there would silently skip (accept-and-drop) the request of the only
  // accountant who needs it — the row would live on the device and never reach
  // the owner for approval. authorizeRecord still server-stamps branch_id +
  // accountant_id below, so a correction cannot be forged for another
  // branch/accountant.
  corrections: null,
  // v43: OWNER/ADMIN ONLY. `financial_adjustments` is the signed, append-only
  // money delta that is folded into the wallet — an accountant able to push one
  // could mint their own wallet credit. Only an owner/admin approval writes it.
  // (`false` throws 403 in authorizeRecord, which the push loop catches and
  // SKIPS+counts — the batch still succeeds, so this can never wedge a device.)
  financial_adjustments: false,
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
/**
 * Entities whose `accountant_id` is a WALLET TARGET chosen by the app, not the
 * identity of the writer — so it must survive the push untouched.
 */
const ATTRIBUTION_PRESERVED = new Set(['corrections', 'financial_adjustments']);

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
    //
    // v43 review fix — EXCEPT for the correction entities. There,
    // `accountant_id` does not mean "who wrote this row", it means "WHOSE
    // WALLET this delta belongs to", and the app deliberately resolves it to
    // the accountant who COLLECTED that month, which is often NOT the filer.
    // Stamping it here silently re-attributed another accountant's wallet
    // credit to whoever happened to file the request.
    if (!ATTRIBUTION_PRESERVED.has(rec.entity)) {
      rec.data.accountant_id = user.localId || String(user._id);
    }
  }

  // v43 SECURITY FIX (pre-existing hole, found by the v43 mapping fleet).
  // `ENTITY_PERMISSION.settlements` is null = "always allowed", and the stamping
  // above only pins branch_id/accountant_id — it never inspects `data.status`.
  // So a crafted push of {status:'approved', decided_by:…} let an ACCOUNTANT
  // APPROVE THEIR OWN SETTLEMENT, bypassing the owner-only decision route
  // entirely and making the owner's books show cash handed over that never
  // arrived. An accountant may CREATE a settlement request; only the owner/admin
  // may DECIDE one (via the app's decide() or POST /settlements/:id/decision).
  //
  // Throwing 403 here is correct and safe: the push loop converts a 403 into
  // skip-and-count (the v25 pattern), so the forged row simply never enters the
  // mirror while the device still drains its outbox. A legitimately PULLED
  // approval is never re-pushed (pull clears the outbox rows it generates).
  if (rec.entity === 'settlements' && rec.data && typeof rec.data === 'object') {
    const status = String(rec.data.status || 'pending');
    if (status !== 'pending') {
      throw new HttpError(
        403,
        'accountants may request a settlement, not decide one',
        'SETTLEMENT_DECISION_FORBIDDEN'
      );
    }
    // Never let a client pre-seed the decision fields either.
    rec.data.decided_by = null;
    rec.data.decided_at = null;
  }

  // v44 review fix — same forgery class for `corrections`: the app's request
  // path ALWAYS writes status 'pending'; only an owner/admin decides. An
  // accountant pushing a decided/closed correction (approved, refund_due,
  // completed, carried_forward, rejected) would re-price every device on a
  // forged old_amps. 403 -> skip-and-count in the push loop (never a batch 4xx).
  if (rec.entity === 'corrections' && rec.data && typeof rec.data === 'object') {
    const status = String(rec.data.status || 'pending');
    if (status !== 'pending') {
      throw new HttpError(
        403,
        'accountants may file a correction, not decide one',
        'CORRECTION_DECISION_FORBIDDEN'
      );
    }
    rec.data.decided_by = null;
    rec.data.decided_at = null;
    rec.data.refund_paid_by = null;
    rec.data.refund_paid_at = null;
  }
}

/* ───────────────────────────────────────────────────────────────────────────
 * v43 — WHY THERE IS NO BUSINESS-RULE LOCK ON THE PUSH LOOP.
 *
 * v43 originally re-evaluated the invoice/settlement lock here, against the
 * owner mirror, so a hand-crafted `/api/sync/push` could not slip a
 * locked-month change past the app. Adversarial review showed that gate is
 * NET-DESTRUCTIVE on this architecture, and it was removed. The reasoning is
 * recorded here so it is not reintroduced.
 *
 * The mirror is PUSH-ONLY and the DEVICE is the source of truth. `pull()` is a
 * FULL RESTORE (INSERT OR REPLACE) used on a new device, after
 * delete-local-data, and on every branch switch. Therefore any row the server
 * REFUSES becomes a permanent divergence, and that divergence materialises as
 * SILENT DATA LOSS the next time the account restores: the device's real value
 * is overwritten by the stale mirror value.
 *
 * The server also cannot reproduce the app's rules faithfully:
 *   - a `subscribers` row carries no month, so a server lock can only ask "was
 *     this subscriber EVER invoiced" — strictly stricter than the app's
 *     month-scoped rule, so it refused ordinary amps/category edits aimed at an
 *     open month;
 *   - the app's receipt-reversal rule is per-accountant, per-method and
 *     issue-time-based, while the server could only see "does this month carry
 *     any active settlement" — so it refused reversals the app itself permits.
 * Both cases dropped a LEGITIMATE edit from the mirror and then reverted it on
 * the device at the next full restore.
 *
 * Decisively: this is a LIVE system with a MIXED-VERSION fleet. A v42 device
 * has no client-side v43 guard at all, so a new server-side refusal breaks a
 * workflow that works today and costs that account real data. Accepting the
 * row is never worse than yesterday's behaviour; refusing it is.
 *
 * So v43 enforces its rules where enforcement cannot diverge:
 *   1. the app (repository + controller choke points), and
 *   2. the direct admin REST surface (`assertDeletableRow`, the correction
 *      decision routes) — which is where a "manual API request" actually
 *      reaches, and where a refusal has no device counterpart to desync.
 *
 * The ONE refusal kept on the push path is `authorizeRecord`'s: a row NO app
 * version can legitimately produce (an accountant pushing an already-decided
 * settlement — forgery, not a workflow). It is skip-and-counted, never thrown,
 * and is now reported in `rejected[]`.
 * ─────────────────────────────────────────────────────────────────────────── */

/** 'YYYY-MM'. Also the guard that keeps a client string out of a $regex. */
const MONTH_RE = /^\d{4}-\d{2}$/;

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
 * { ok, count, rejected, serverTime }.
 *
 * v43: `rejected` is an ADDITIVE array of { entity, localId, reason } listing
 * the rows the server-side MONTH LOCK refused to mirror (a locked-month change
 * pushed by a hand-crafted call or a tampered client). Those rows are still
 * COUNTED in `count` and the response is still 200 — a lock violation must
 * never fail the batch (see the lock comment block above). A client that
 * ignores the field behaves exactly as it does today.
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
  // v43: rows the server declined to mirror. ADDITIVE field on the 200
  // response — a client that ignores it is byte-for-byte unaffected (the batch
  // still succeeds and `count` still covers every record, so the outbox
  // drains). Only forged rows land here; see the design note above MONTH_RE.
  const rejected = [];

  for (const rec of records) {
    if (!rec || typeof rec.entity !== 'string' || typeof rec.localId !== 'string') {
      throw new HttpError(400, 'each record needs entity and localId', 'BAD_RECORD');
    }
    // Whitelist the entity against the known synced tables.
    if (!SYNCED_ENTITIES.has(rec.entity)) {
      throw new HttpError(400, `unknown entity: ${rec.entity}`, 'BAD_ENTITY');
    }
    // Accountant authorization + server-stamp branch/accountant (mutates rec.data).
    // v25 WEDGE FIX: an UNAUTHORIZED record is SKIPPED, never allowed to fail
    // the whole batch. The device auto-creates owner-only identity rows (e.g.
    // ensureMain's Main-branch row fires the sync trigger at app BOOT, before
    // anyone logs in); pushed under an accountant JWT it 403'd here and
    // permanently poisoned that device's outbox: every push failed, so pull
    // (which pushes first) never ran — dashboard all zeros, "1 pending change"
    // forever, and the v17 logout guard blocked the wipe (only clearing app
    // data escaped). Skipping counts the record as accepted so the device
    // DRAINS its outbox; the row simply never enters the mirror (the owner's
    // own device pushes the real one). Tampered-client 400s above still fail.
    try {
      authorizeRecord(req.user, rec);
    } catch (err) {
      if (err instanceof HttpError && err.status === 403) {
        console.warn(
          `[sync] skipped unauthorized ${rec.entity}/${rec.localId} from ` +
            `${req.user?.username || req.user?._id} (${err.code})`
        );
        // Report it so the field is actionable rather than always-empty.
        rejected.push({
          entity: rec.entity,
          localId: rec.localId,
          reason: err.code || 'FORBIDDEN',
        });
        count += 1; // accepted/no-op so the device clears its outbox
        continue;
      }
      throw err;
    }

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

    // NOTE: v43 deliberately applies NO business-rule lock here. Refusing a row
    // the device already committed diverges the mirror and silently reverts real
    // data at the next full restore — see the design note above MONTH_RE.

    // eslint-disable-next-line no-await-in-loop
    await SyncRecord.findOneAndUpdate(
      { user: userId, entity: rec.entity, localId: rec.localId },
      { $set: { data, deleted, updatedAt }, $setOnInsert: { user: userId, entity: rec.entity, localId: rec.localId } },
      { new: true, upsert: true, setDefaultsOnInsert: true }
    );
    count += 1;
  }

  res.status(200).json({ ok: true, count, rejected, serverTime: new Date().toISOString() });
});

/**
 * GET /api/sync/pull?since=ISO[&receiptsMonth=YYYY-MM] (auth)
 * Returns { records: [ { entity, localId, deleted, updatedAt, data } ] } for the
 * current account, updated since `since` (defaults to all). Used by a new device
 * to restore the mirror.
 *
 * Optional `receiptsMonth` (YYYY-MM): when present, ONLY the `receipts` entity is
 * restricted to rows whose `data.month` equals it (every other entity is
 * unaffected) — used by the post-login pull to restore only the current month's
 * receipts. `since` still applies to all entities.
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

  // Scope ONLY the receipts entity to a single month, leaving all other entities
  // intact: a record either is NOT a receipt, OR is a receipt of that month.
  const receiptsMonth = String(req.query.receiptsMonth || '').trim();
  if (receiptsMonth) {
    const monthClause = {
      $or: [
        { entity: { $ne: 'receipts' } },
        { entity: 'receipts', 'data.month': receiptsMonth },
        // Receipt DELETIONS are tombstones with data=null, so they wouldn't match
        // the month clause — always include them so a delete still propagates.
        { entity: 'receipts', deleted: true },
      ],
    };
    filter.$and = (filter.$and || []).concat([monthClause]);
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
