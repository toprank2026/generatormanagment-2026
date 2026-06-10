'use strict';

const express = require('express');
const { verifyToken } = require('../utils/token');
const User = require('../models/User');
const asyncHandler = require('../utils/asyncHandler');
const { streamAdminEvents } = require('../controllers/eventsController');

const router = express.Router();

/**
 * Authenticates an ADMIN from a `?token=<jwt>` QUERY param instead of the usual
 * Authorization header — the browser EventSource API cannot send custom headers,
 * so the SSE endpoint takes the JWT on the query string.
 */
const requireAdminQueryToken = asyncHandler(async (req, res, next) => {
  const token = req.query.token;
  if (!token || typeof token !== 'string') {
    return res.status(401).json({ message: 'Missing token', code: 'NO_TOKEN' });
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
  if (user.role !== 'admin') {
    return res.status(403).json({ message: 'Admin access required', code: 'FORBIDDEN' });
  }

  req.user = user;
  return next();
});

// GET /api/admin/events — SSE stream of admin events (admin via ?token=).
router.get('/events', requireAdminQueryToken, streamAdminEvents);

module.exports = router;
