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

  const updated = await SyncRecord.findOneAndUpdate(
    { user: mirrorUserId, entity: 'settlements', localId: req.params.localId },
    { $set: set },
    { new: true }
  );

  if (!updated) {
    throw new HttpError(404, 'Settlement not found', 'SETTLEMENT_NOT_FOUND');
  }

  res.status(200).json({ settlement: updated.data });
});

module.exports = { decide };
