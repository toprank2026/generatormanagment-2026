'use strict';

const Plan = require('../models/Plan');
const asyncHandler = require('../utils/asyncHandler');
const { serializePlan, serializeSubscription } = require('../utils/serialize');
const { HttpError } = require('../middleware/error');

/** GET /api/subscription/plans (public) — active plans only. */
const listPlans = asyncHandler(async (req, res) => {
  const plans = await Plan.find({ active: true }).sort({ price: 1, durationDays: 1 });
  res.status(200).json({ plans: plans.map(serializePlan) });
});

/** GET /api/subscription (auth) */
const getSubscription = asyncHandler(async (req, res) => {
  res.status(200).json({ subscription: serializeSubscription(req.user.subscription) });
});

/** POST /api/subscription/request (auth) — sets status=pending. */
const requestPlan = asyncHandler(async (req, res) => {
  const { planCode } = req.body;

  const plan = await Plan.findOne({ code: planCode, active: true });
  if (!plan) {
    throw new HttpError(404, 'Plan not found', 'PLAN_NOT_FOUND');
  }

  // A pending request is not yet active — clear any prior active/expired dates
  // so the client never sees stale start/expiry on a pending subscription.
  req.user.subscription = {
    planCode,
    status: 'pending',
    startedAt: null,
    expiresAt: null,
  };
  await req.user.save();

  res.status(200).json({ subscription: serializeSubscription(req.user.subscription) });
});

module.exports = { listPlans, getSubscription, requestPlan };
