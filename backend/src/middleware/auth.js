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
  if (user.blocked) {
    return res.status(403).json({ message: 'Account blocked', code: 'BLOCKED' });
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
