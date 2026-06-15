'use strict';

const express = require('express');
const { body } = require('express-validator');
const { requireAuth, requireAdmin } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const ctrl = require('../controllers/adminController');

const router = express.Router();

// Every admin route requires a valid JWT + admin role.
router.use(requireAuth, requireAdmin);

// ---- Users ----
router.get('/users', ctrl.listUsers);
router.post(
  '/users',
  [
    body('name').isString().trim().notEmpty().withMessage('name is required'),
    body('username').isString().trim().notEmpty().withMessage('username is required'),
    body('password').isString().isLength({ min: 4 }).withMessage('password must be at least 4 chars'),
    body('role').optional().isIn(['owner', 'admin']).withMessage('invalid role'),
  ],
  validate,
  ctrl.createUser
);
router.get('/users/:id', ctrl.getUser);
router.delete('/users/:id', ctrl.deleteUser);

// Latest data uploaded from the apps across all accounts (dashboard home).
router.get('/recent-data', ctrl.recentData);

// Synced business data mirror for one owner (?entity=subscribers).
router.get('/users/:id/data', ctrl.getUserData);
// Hard-delete a single mirrored row (the mirror is otherwise read-only).
router.delete('/users/:id/data/:entity/:localId', ctrl.deleteUserData);

router.put(
  '/users/:id/blocked',
  [body('blocked').isBoolean().withMessage('blocked must be boolean')],
  validate,
  ctrl.setBlocked
);
router.put(
  '/users/:id/plan',
  [
    body('planCode').isString().trim().notEmpty().withMessage('planCode is required'),
    body('status').optional().isIn(['none', 'pending', 'active', 'rejected', 'expired']),
  ],
  validate,
  ctrl.setPlan
);
router.post('/users/:id/approve-plan', ctrl.approvePlan);
router.post('/users/:id/reject-plan', ctrl.rejectPlan);
router.delete('/users/:id/devices/:deviceId', ctrl.unbindDevice);

// ---- Plans ----
router.get('/plans', ctrl.listPlans);
router.put(
  '/plans',
  [
    body('code').isString().trim().notEmpty().withMessage('code is required'),
    body('name').optional().isString(),
    body('durationDays').optional().isInt({ min: 1 }),
    body('maxDevices').optional().isInt({ min: 1 }),
    body('price').optional().isNumeric(),
    body('active').optional().isBoolean(),
    body('syncEnabled').optional().isBoolean(),
    body('backupEnabled').optional().isBoolean(),
    body('ownerPanelEnabled').optional().isBoolean(),
    body('multiBranchEnabled').optional().isBoolean(),
  ],
  validate,
  ctrl.upsertPlan
);
router.delete('/plans/:code', ctrl.deletePlan);

module.exports = router;
