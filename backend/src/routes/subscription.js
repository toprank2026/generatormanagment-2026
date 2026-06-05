'use strict';

const express = require('express');
const { body } = require('express-validator');
const {
  listPlans,
  getSubscription,
  requestPlan,
} = require('../controllers/subscriptionController');
const { validate } = require('../middleware/validate');
const { requireAuth } = require('../middleware/auth');

const router = express.Router();

// Public: active plans.
router.get('/plans', listPlans);

// Auth.
router.get('/', requireAuth, getSubscription);
router.post(
  '/request',
  requireAuth,
  [body('planCode').isString().trim().notEmpty().withMessage('planCode is required')],
  validate,
  requestPlan
);

module.exports = router;
