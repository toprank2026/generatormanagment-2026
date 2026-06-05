'use strict';

const jwt = require('jsonwebtoken');
const env = require('../config/env');

/** Sign a JWT for a user id (+ role for convenience in middleware). */
function signToken(user) {
  const payload = { sub: String(user._id || user.id), role: user.role };
  return jwt.sign(payload, env.JWT_SECRET, { expiresIn: env.JWT_EXPIRES });
}

/** Verify a JWT; throws if invalid/expired. Returns the decoded payload. */
function verifyToken(token) {
  return jwt.verify(token, env.JWT_SECRET);
}

module.exports = { signToken, verifyToken };
