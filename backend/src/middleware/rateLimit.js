'use strict';

const rateLimit = require('express-rate-limit');
const env = require('../config/env');

/**
 * Rate limiter for the public auth endpoints (login / register).
 *
 * Caps brute-force / credential-stuffing to ~10 requests per minute per IP and
 * returns HTTP 429 with a JSON body the app can surface. Disabled under the test
 * env so the (high-volume, single-IP) integration suite is not throttled.
 */
const authLimiter = rateLimit({
  windowMs: 60 * 1000, // 1 minute
  max: 10, // ~10 attempts / minute / IP
  standardHeaders: true,
  legacyHeaders: false,
  // The integration suite hammers login/register from one IP; never throttle it.
  skip: () => env.NODE_ENV === 'test',
  message: { message: 'Too many attempts, please try again later.', code: 'RATE_LIMITED' },
});

module.exports = { authLimiter };
