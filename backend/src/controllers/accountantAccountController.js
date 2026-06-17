'use strict';

const mongoose = require('mongoose');
const bcrypt = require('bcryptjs');
const User = require('../models/User');
const asyncHandler = require('../utils/asyncHandler');
const { HttpError } = require('../middleware/error');

/**
 * Resolve one of the caller's accountants by the :id path param, which may be
 * EITHER the app-side localId (the app addresses accountants by their local
 * UUID) OR the Mongo _id. Always scoped to the caller as owner so an owner can
 * only ever touch their own sub-accounts.
 */
function findOwnedAccountant(ownerId, idParam) {
  const or = [{ localId: idParam }];
  if (mongoose.isValidObjectId(idParam)) or.push({ _id: idParam });
  return User.findOne({ role: 'accountant', owner: ownerId, $or: or });
}

/**
 * Compact view of an accountant sub-account, as returned by the accountant
 * management endpoints (NOT the full Account shape — these are the caller's
 * sub-accounts, not login accounts).
 */
function serializeAccountant(u) {
  return {
    id: String(u._id || u.id),
    localId: u.localId || null,
    name: u.name,
    username: u.username,
    branchId: u.branchId || null,
    permissions: Array.isArray(u.permissions) ? u.permissions : [],
    active: !u.blocked,
  };
}

/**
 * POST /api/account/accountants (requireAuth; owner|admin)
 *
 * Create an accountant sub-account owned by the caller. The username is unique
 * (lowercased/trimmed); duplicate -> 409 USERNAME_TAKEN.
 */
const createAccountant = asyncHandler(async (req, res) => {
  const { name, username, password, branchId, permissions, localId } = req.body || {};

  if (!name || typeof name !== 'string' || !name.trim()) {
    throw new HttpError(400, 'name is required', 'VALIDATION');
  }
  if (!username || typeof username !== 'string' || !username.trim()) {
    throw new HttpError(400, 'username is required', 'VALIDATION');
  }
  if (!password || typeof password !== 'string' || password.length < 4) {
    throw new HttpError(400, 'password must be at least 4 chars', 'VALIDATION');
  }

  const uname = String(username).toLowerCase().trim();
  const exists = await User.findOne({ username: uname });
  if (exists) {
    throw new HttpError(409, 'Username already taken', 'USERNAME_TAKEN');
  }

  const passwordHash = await bcrypt.hash(password, 10);
  const accountant = await User.create({
    name: name.trim(),
    username: uname,
    passwordHash,
    role: 'accountant',
    owner: req.user._id,
    branchId: branchId || null,
    permissions: Array.isArray(permissions) ? permissions : [],
    localId: localId || null,
    subscription: { status: 'none', planCode: null },
    devices: [],
  });

  res.status(201).json({ accountant: serializeAccountant(accountant) });
});

/**
 * GET /api/account/accountants (requireAuth; owner|admin)
 *
 * The caller's own accountant sub-accounts (owner === caller).
 */
const listAccountants = asyncHandler(async (req, res) => {
  const accountants = await User.find({ role: 'accountant', owner: req.user._id }).sort({
    createdAt: -1,
  });
  res.status(200).json({ accountants: accountants.map(serializeAccountant) });
});

/**
 * PUT /api/account/accountants/:id (requireAuth; owner|admin)
 *
 * Update name / permissions / branchId / active / password of one of the
 * caller's accountants. Ownership guard: 404 when not the caller's accountant.
 */
const updateAccountant = asyncHandler(async (req, res) => {
  const accountant = await findOwnedAccountant(req.user._id, req.params.id);
  if (!accountant) throw new HttpError(404, 'Accountant not found', 'ACCOUNTANT_NOT_FOUND');

  const { name, permissions, branchId, active, password } = req.body || {};

  if (name !== undefined) accountant.name = String(name).trim();
  if (Array.isArray(permissions)) accountant.permissions = permissions;
  if (branchId !== undefined) accountant.branchId = branchId || null;
  if (active !== undefined) accountant.blocked = !active;
  if (password !== undefined && password) {
    accountant.passwordHash = await bcrypt.hash(String(password), 10);
  }

  await accountant.save();
  res.status(200).json({ accountant: serializeAccountant(accountant) });
});

/**
 * DELETE /api/account/accountants/:id (requireAuth; owner|admin)
 *
 * Delete one of the caller's accountants. Ownership guard: 404 otherwise.
 */
const deleteAccountant = asyncHandler(async (req, res) => {
  const accountant = await findOwnedAccountant(req.user._id, req.params.id);
  if (!accountant) throw new HttpError(404, 'Accountant not found', 'ACCOUNTANT_NOT_FOUND');

  await accountant.deleteOne();
  res.status(200).json({ ok: true });
});

module.exports = {
  serializeAccountant,
  createAccountant,
  listAccountants,
  updateAccountant,
  deleteAccountant,
};
