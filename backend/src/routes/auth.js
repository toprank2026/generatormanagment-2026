'use strict';

const express = require('express');
const { body, query } = require('express-validator');
const {
  register,
  login,
  me,
  recoverDevice,
  forgotPassword,
  forgotPasswordStatus,
} = require('../controllers/authController');
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

// v42 item 4: super-admin-approved password recovery. Public and credential-shaped
// (it takes a username + the account's registered phone as the identity check), so
// it rides the same authLimiter as login/register/recover-device. `newPassword` is
// only ever stored bcrypt-hashed on the pending request — nothing changes on the
// account until a super admin approves it in the panel.
router.post(
  '/forgot-password',
  authLimiter,
  [
    // v42 follow-up: the owner recovers with their PHONE ALONE — one field to
    // get wrong when you are already locked out. `username` stays OPTIONAL so an
    // already-shipped APK that still sends it keeps working (when present it is
    // checked as an extra condition, never as a substitute).
    body('username').optional({ nullable: true }).isString().trim(),
    body('phone').isString().trim().notEmpty().withMessage('phone is required'),
    body('newPassword').isString().isLength({ min: 4 }).withMessage('newPassword must be at least 4 chars'),
  ],
  validate,
  forgotPassword
);

// Declared before GET '/me' so the two-segment path can never be shadowed by a
// future single-segment GET. Public: the app polls it while the owner waits for
// the super admin's decision, and requestId + the 6-digit code are the only keys
// (no session exists yet). Rate-limited so the code can't be brute-forced.
router.get(
  '/forgot-password/status',
  authLimiter,
  [
    query('requestId').isString().trim().notEmpty().withMessage('requestId is required'),
    query('code').isString().trim().notEmpty().withMessage('code is required'),
  ],
  validate,
  forgotPasswordStatus
);

router.get('/me', requireAuth, me);

module.exports = router;
