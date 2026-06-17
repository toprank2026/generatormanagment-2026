'use strict';

const { featuresForUser } = require('../utils/planFeatures');
const asyncHandler = require('../utils/asyncHandler');

/**
 * Gates a route behind a per-plan capability flag (sync | backup | ownerPanel).
 * Resolves the caller's features LIVE from their active plan via featuresForUser
 * and 403s when the named feature is disabled. Mount AFTER requireAuth so
 * req.user is populated.
 */
function requireFeature(name) {
  return asyncHandler(async (req, res, next) => {
    // Accountants inherit the OWNER's plan: gate against the owner's features
    // (attached by requireAuth as req.ownerAccount), never the accountant's own
    // empty subscription — which would otherwise default every feature to TRUE
    // and bypass a restricted owner's plan.
    const subject =
      req.user && req.user.role === 'accountant' && req.ownerAccount
        ? req.ownerAccount
        : req.user;
    const f = await featuresForUser(subject);
    if (!f[name]) {
      return res.status(403).json({
        message: 'هذه الميزة غير متوفرة في خطتك',
        code: 'FEATURE_DISABLED',
        feature: name,
      });
    }
    return next();
  });
}

module.exports = { requireFeature };
