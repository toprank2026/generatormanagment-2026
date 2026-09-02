'use strict';

const mongoose = require('mongoose');
const SyncRecord = require('../models/SyncRecord');
const User = require('../models/User');
const asyncHandler = require('../utils/asyncHandler');
const { HttpError } = require('../middleware/error');
const { effectiveOwnerId } = require('../utils/effectiveOwner');

/** The only two decisions an owner can record on a settlement request. */
const DECISIONS = new Set(['approved', 'rejected']);

/**
 * POST /api/account/settlements/:localId/decision  (requireAuth; owner|admin)
 * Body: { status: 'approved'|'rejected', note? }
 *
 * An accountant requests a wallet settlement by pushing a `settlements` row
 * (status 'pending') into the OWNER's mirror via /api/sync/push. The owner
 * approves/rejects it here by mutating that same mirror row IN PLACE so a
 * subsequent accountant pull sees the decision. Bumping `data.updated_at` to now
 * makes last-EDIT-wins apply this owner decision over the accountant's older
 * pending row (the accountant's local copy is overwritten on pull).
 *
 * Owners/admins only (route-gated by requireOwnerOrAdmin); the accountant cannot
 * reach this route — its decision authority is the owner's alone.
 *
 * The settlement lives in the mirror of the generator that owns the accountant.
 * For the MAIN account that is the caller's own mirror (effective owner). For a
 * BRANCH account (independent generator the owner views via the panel switcher),
 * the body carries `branchId` and the settlement lives in THAT branch account's
 * mirror — we verify the branch belongs to the caller, then target it. Without
 * this, approving a branch settlement keyed on the owner mirror and 404'd
 * ("Settlement not found").
 *
 * v43 (F4) IDEMPOTENCY — pre-existing defect, fixed here. The update filter used
 * to be only {user, entity, localId} with NO status condition, so an
 * ALREADY-DECIDED settlement could be re-approved, flipped approved→rejected, or
 * re-amounted at any time (a stale panel tab, a double-click, two owners) —
 * silently changing the DERIVED wallet (balance = collected − Σ approved
 * settlements) with no record that it happened. Only an UNDECIDED request may be
 * decided now; a second decision gets `409 SETTLEMENT_NOT_PENDING` and changes
 * nothing. This matches the Dart twin (`SettlementRepository.decide`, v35 item
 * 6), which re-reads the row and no-ops unless it is still pending.
 *
 * Backward-compat detail: a row whose `data.status` is absent/null (never
 * written by the app — the column is `DEFAULT 'pending'` and the model always
 * stamps it — but possible for a hand-crafted or tombstoned mirror row) counts
 * as UNDECIDED and stays decidable, exactly as today. Only an explicit
 * 'approved'/'rejected' is refused, so no settlement that can be decided today
 * loses that ability.
 */
const decide = asyncHandler(async (req, res) => {
  const { status, note, branchId, amount } = req.body || {};

  if (!status || !DECISIONS.has(status)) {
    throw new HttpError(400, "status must be 'approved' or 'rejected'", 'BAD_STATUS');
  }

  // v28 item 12 (panel parity): a SALARY settlement is requested with no amount;
  // the owner enters it on approval. When a valid positive amount is supplied we
  // stamp it onto data.amount (mirrors the Flutter owner flow / SettlementRepo.
  // decide). Additive + backward-compatible: existing callers omit it.
  const approveAmount =
    status === 'approved' && amount != null && Number.isFinite(Number(amount)) && Number(amount) > 0
      ? Number(amount)
      : null;

  const nowIso = new Date().toISOString();

  // Which mirror holds the settlement: a branch account's (verified owned by the
  // caller) when branchId is given, else the caller's own (effective owner).
  let mirrorUserId = effectiveOwnerId(req.user);
  if (branchId) {
    if (!mongoose.isValidObjectId(branchId)) {
      throw new HttpError(404, 'Settlement not found', 'SETTLEMENT_NOT_FOUND');
    }
    const branch = await User.findOne({ _id: branchId, parentOwner: req.user._id });
    if (!branch) throw new HttpError(404, 'Branch not found', 'BRANCH_NOT_FOUND');
    mirrorUserId = branch._id;
  }

  const set = {
    'data.status': status,
    'data.decided_at': nowIso,
    'data.decided_by': String(req.user._id),
    // Bump the per-row edit time so last-EDIT-wins applies this decision over the
    // accountant's older pending row on the next pull.
    'data.updated_at': nowIso,
    updatedAt: new Date(),
  };
  if (note !== undefined) set['data.note'] = note;
  if (approveAmount != null) set['data.amount'] = approveAmount;

  // Identity of the row (no status condition) — reused for the 404-vs-409 split.
  const identity = { user: mirrorUserId, entity: 'settlements', localId: req.params.localId };

  // v43 (F4): the decision applies ONLY while the request is still undecided.
  // `{'data.status': null}` matches an explicit null AND a missing key in
  // MongoDB — the legacy/unstamped shape, treated as pending (see the header).
  const updated = await SyncRecord.findOneAndUpdate(
    {
      ...identity,
      $or: [{ 'data.status': 'pending' }, { 'data.status': null }],
    },
    { $set: set },
    { new: true }
  );

  if (!updated) {
    // Nothing matched: either the settlement does not exist in this mirror (404,
    // unchanged) or it exists but was ALREADY decided (409, new). Distinguish
    // them so the panel/app can tell "wrong account" from "already handled" —
    // and so a duplicate decision is never silently reported as a success.
    const existing = await SyncRecord.findOne(identity, { data: 1 }).lean();
    if (!existing) {
      throw new HttpError(404, 'Settlement not found', 'SETTLEMENT_NOT_FOUND');
    }
    const current = (existing.data || {}).status || 'pending';
    throw new HttpError(
      409,
      `Settlement already ${current}`,
      'SETTLEMENT_NOT_PENDING'
    );
  }

  res.status(200).json({ settlement: updated.data });
});

module.exports = { decide };
