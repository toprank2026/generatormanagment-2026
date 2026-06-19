'use strict';

const jwt = require('jsonwebtoken');
const env = require('../config/env');

/**
 * Sign a JWT for a user id (+ role for convenience in middleware). The `tv`
 * (token version) claim mirrors user.tokenVersion so a password change (which
 * bumps tokenVersion) invalidates every previously-issued token — requireAuth
 * rejects a token whose tv no longer matches the stored user (401 TOKEN_STALE).
 */
function signToken(user) {
  const payload = {
    sub: String(user._id || user.id),
    role: user.role,
    tv: user.tokenVersion || 0,
  };
  return jwt.sign(payload, env.JWT_SECRET, { expiresIn: env.JWT_EXPIRES });
}

/** Verify a JWT; throws if invalid/expired. Returns the decoded payload. */
function verifyToken(token) {
  return jwt.verify(token, env.JWT_SECRET);
}

module.exports = { signToken, verifyToken };
