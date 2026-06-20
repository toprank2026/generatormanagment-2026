'use strict';

const mongoose = require('mongoose');
const bcrypt = require('bcryptjs');
const User = require('../models/User');
const SyncRecord = require('../models/SyncRecord');
const asyncHandler = require('../utils/asyncHandler');
const { HttpError } = require('../middleware/error');
const { serializeBranch } = require('../utils/serialize');
const { listUserData } = require('./adminController');
const { buildDashboard, STAT_ENTITIES } = require('./accountController');

/**
 * Branch sub-accounts ("branch = owner-created sub-account").
 *
 * A BRANCH is a backend `User` that is a CHILD of the creating top-level OWNER
 * and behaves owner-like for its OWN data mirror. It keeps `role:'owner'` (so the
 * existing owner-scoped sync/backup/account logic applies to the branch's own
 * mirror unchanged — its effectiveOwner is itself) but has `parentOwner` set to
 * the creating owner's _id. It logs in through the normal /api/auth/login (its
 * phone as username, its own password). It INHERITS the parent owner's
 * subscription/features for gating and is cascade-blocked by the parent (see
 * authController/login + me and middleware/auth requireAuth).
 *
 * A branch may NOT create sub-branches: a caller whose own parentOwner is set is
 * rejected (403). Accountants cannot create branches (route-level owner-only).
 */

/**
 * Resolve one of the caller's BRANCHES by the :branchId path param (Mongo _id),
 * always scoped to the caller as parentOwner so an owner can only ever address
 * its own branches. Returns null when not found / not the caller's branch.
 */
async function findOwnedBranch(parentOwnerId, branchId) {
  if (!mongoose.isValidObjectId(branchId)) return null;
  return User.findOne({ _id: branchId, parentOwner: parentOwnerId });
}

/**
 * POST /api/account/branches (requireAuth; owner only)
 *
 * Create a branch sub-account owned by the caller. Owner-only: a branch (caller
 * with parentOwner set) cannot create sub-branches (403 SUB_BRANCH_FORBIDDEN);
 * accountants are rejected at the route. Body: { generatorName, phone, password }.
 * username = phone.toLowerCase() and must be unique (and phone unique) — reusing
 * the same checks as register. Returns { branch: serialized }.
 */
const createBranch = asyncHandler(async (req, res) => {
  // A branch cannot create sub-branches (one level deep only).
  if (req.user.parentOwner) {
    throw new HttpError(403, 'A branch cannot create sub-branches', 'SUB_BRANCH_FORBIDDEN');
  }

  const { generatorName, phone, password } = req.body || {};

  if (!generatorName || typeof generatorName !== 'string' || !generatorName.trim()) {
    throw new HttpError(400, 'generatorName is required', 'VALIDATION');
  }
  if (!phone || typeof phone !== 'string' || !phone.trim()) {
    throw new HttpError(400, 'phone is required', 'VALIDATION');
  }
  if (!password || typeof password !== 'string' || password.length < 4) {
    throw new HttpError(400, 'password must be at least 4 chars', 'VALIDATION');
  }

  // The branch logs in with username == phone (same convention as the app's
  // owner sign-up). Enforce both username AND phone uniqueness like register.
  const uname = String(phone).toLowerCase().trim();
  const exists = await User.findOne({ username: uname });
  if (exists) {
    throw new HttpError(409, 'Phone number already registered', 'PHONE_TAKEN');
  }
  const phoneTaken = await User.findOne({ phone: String(phone).trim() });
  if (phoneTaken) {
    throw new HttpError(409, 'Phone number already registered', 'PHONE_TAKEN');
  }

  const passwordHash = await bcrypt.hash(password, 10);
  const branch = await User.create({
    name: generatorName.trim(),
    generatorName: generatorName.trim(),
    phone: String(phone).trim(),
    username: uname,
    passwordHash,
    role: 'owner',
    parentOwner: req.user._id,
    // A branch inherits the parent's plan via parentOwner (see featureSubject):
    // its own subscription stays 'none' and is never used for gating.
    subscription: { status: 'none', planCode: null },
    devices: [],
  });

  res.status(201).json({ branch: serializeBranch(branch) });
});

/**
 * GET /api/account/branches (requireAuth; owner only)
 *
 * List the caller's branches (parentOwner === caller), newest first.
 */
const listBranches = asyncHandler(async (req, res) => {
  const branches = await User.find({ parentOwner: req.user._id }).sort({ createdAt: -1 });
  res.status(200).json({ branches: branches.map(serializeBranch) });
});

/**
 * GET /api/account/branches/:branchId/stats[?month=YYYY-MM] (owner only)
 *
 * The parent owner's panel views ONE of its branches' dashboards, scoped to that
 * branch user's OWN mirror (effectiveOwner = the branch). Ownership-checked: the
 * :branchId User must have parentOwner === req.user._id (else 404). Reuses the
 * same per-entity counts + buildDashboard as GET /api/account/stats.
 */
const getBranchStats = asyncHandler(async (req, res) => {
  const branch = await findOwnedBranch(req.user._id, req.params.branchId);
  if (!branch) throw new HttpError(404, 'Branch not found', 'BRANCH_NOT_FOUND');

  const requested = String(req.query.month || '');
  const month = /^\d{4}-\d{2}$/.test(requested)
    ? requested
    : new Date().toISOString().slice(0, 7);

  const rows = await SyncRecord.aggregate([
    { $match: { user: branch._id, deleted: false } },
    { $group: { _id: '$entity', count: { $sum: 1 } } },
  ]);

  const counts = {};
  for (const entity of STAT_ENTITIES) counts[entity] = 0;
  for (const row of rows) counts[row._id] = row.count;

  // The branch is a full owner of its own mirror, so no inner accountant/branch
  // filter is applied here — the dashboard is the WHOLE branch account.
  const dashboard = await buildDashboard(branch._id, counts, month, null, null);

  res.status(200).json({ counts, dashboard });
});

/**
 * GET /api/account/branches/:branchId/data?entity=&... (owner only)
 *
 * The parent owner's panel reads ONE of its branches' synced mirror (same query
 * params + response shape as GET /api/account/data), scoped to that branch user's
 * OWN mirror. Ownership-checked like getBranchStats.
 */
const getBranchData = asyncHandler(async (req, res) => {
  const branch = await findOwnedBranch(req.user._id, req.params.branchId);
  if (!branch) throw new HttpError(404, 'Branch not found', 'BRANCH_NOT_FOUND');

  res.status(200).json(await listUserData(branch._id, req.query));
});

module.exports = {
  serializeBranch,
  createBranch,
  listBranches,
  getBranchStats,
  getBranchData,
};
