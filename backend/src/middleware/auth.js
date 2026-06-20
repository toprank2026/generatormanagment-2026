'use strict';

const { verifyToken } = require('../utils/token');
const User = require('../models/User');
const asyncHandler = require('../utils/asyncHandler');

/**
 * Verifies the Bearer JWT, loads the user, and attaches it to req.user.
 * Responds 401 when missing/invalid. A blocked account is rejected with 403
 * (so a blocked user's session ends on the next /auth/me).
 */
const requireAuth = asyncHandler(async (req, res, next) => {
  const header = req.headers.authorization || '';
  const [scheme, token] = header.split(' ');

  if (scheme !== 'Bearer' || !token) {
    return res.status(401).json({ message: 'Missing or malformed token' });
  }

  let payload;
  try {
    payload = verifyToken(token);
  } catch (e) {
    return res.status(401).json({ message: 'Invalid or expired token' });
  }

  const user = await User.findById(payload.sub);
  if (!user) {
    return res.status(401).json({ message: 'Account not found' });
  }
  // Token invalidation on password change: a token carries the tokenVersion
  // (tv) it was issued with. A password change bumps user.tokenVersion, so any
  // token minted before it no longer matches and is rejected (must re-login).
  // Back-comp: a legacy token with no tv claim is treated as tv=0.
  if ((payload.tv || 0) !== (user.tokenVersion || 0)) {
    return res.status(401).json({ message: 'Token invalidated, please sign in again', code: 'TOKEN_STALE' });
  }
  if (user.blocked) {
    return res.status(403).json({ message: 'Account blocked', code: 'BLOCKED' });
  }

  // An accountant sub-account is only as alive as its OWNER: a blocked/missing
  // owner must cut off all the owner's accountants (the admin's block is the
  // whole-account kill switch). Load the owner once and expose it as the
  // effective account for feature-gating (see requireFeature).
  if (user.role === 'accountant') {
    const owner = user.owner ? await User.findById(user.owner) : null;
    if (!owner || owner.blocked) {
      return res.status(403).json({ message: 'Account blocked', code: 'BLOCKED' });
    }
    req.ownerAccount = owner;
  }

  // A BRANCH (role:'owner' with parentOwner set) is cascade-blocked by its parent
  // top-level owner: a blocked/missing parent cuts the branch off too. Load the
  // parent once and expose it for feature-gating (branches inherit the parent's
  // plan via featureSubject/requireFeature).
  if (user.parentOwner) {
    const parent = await User.findById(user.parentOwner);
    if (!parent || parent.blocked) {
      return res.status(403).json({ message: 'Account blocked', code: 'BLOCKED' });
    }
    req.parentAccount = parent;
  }

  req.user = user;
  return next();
});

/** Requires req.user.role === 'admin'. Mount after requireAuth. */
function requireAdmin(req, res, next) {
  if (!req.user || req.user.role !== 'admin') {
    return res.status(403).json({ message: 'Admin access required', code: 'FORBIDDEN' });
  }
  return next();
}

module.exports = { requireAuth, requireAdmin };
