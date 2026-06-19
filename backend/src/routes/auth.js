'use strict';

const express = require('express');
const { body } = require('express-validator');
const { register, login, me, recoverDevice } = require('../controllers/authController');
const { validate } = require('../middleware/validate');
const { requireAuth } = require('../middleware/auth');
const { authLimiter } = require('../middleware/rateLimit');

const router = express.Router();

router.post(
  '/register',
  authLimiter,
  [
    body('name').isString().trim().notEmpty().withMessage('name is required'),
    body('username').isString().trim().notEmpty().withMessage('username is required'),
    body('password').isString().isLength({ min: 4 }).withMessage('password must be at least 4 chars'),
    body('phone').optional({ nullable: true }).isString(),
    body('device').optional().isObject(),
  ],
  validate,
  register
);

router.post(
  '/login',
  authLimiter,
  [
    body('username').isString().trim().notEmpty().withMessage('username is required'),
    body('password').isString().notEmpty().withMessage('password is required'),
    body('device').optional().isObject(),
  ],
  validate,
  login
);

// Password-authenticated self-service recovery for a maxDevices-locked owner:
// evicts the least-recently-seen device and binds the calling one. Rate-limited
// like login/register (public, credential-checking endpoint).
router.post(
  '/recover-device',
  authLimiter,
  [
    body('username').isString().trim().notEmpty().withMessage('username is required'),
    body('password').isString().notEmpty().withMessage('password is required'),
    body('device').isObject().withMessage('device is required'),
  ],
  validate,
  recoverDevice
);

router.get('/me', requireAuth, me);

module.exports = router;
