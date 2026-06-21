'use strict';

const SyncRecord = require('../models/SyncRecord');
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
 * Owners/admins only (route-gated by requireOwnerOrAdmin); a settlement always
 * lives in the OWNER's mirror, so we key on the effective owner. The accountant
 * cannot reach this route — its decision authority is the owner's alone.
 */
const decide = asyncHandler(async (req, res) => {
  const { status, note } = req.body || {};

  if (!status || !DECISIONS.has(status)) {
    throw new HttpError(400, "status must be 'approved' or 'rejected'", 'BAD_STATUS');
  }

  const nowIso = new Date().toISOString();
  const ownerId = effectiveOwnerId(req.user);

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

  const updated = await SyncRecord.findOneAndUpdate(
    { user: ownerId, entity: 'settlements', localId: req.params.localId },
    { $set: set },
    { new: true }
  );

  if (!updated) {
    throw new HttpError(404, 'Settlement not found', 'SETTLEMENT_NOT_FOUND');
  }

  res.status(200).json({ settlement: updated.data });
});

module.exports = { decide };
