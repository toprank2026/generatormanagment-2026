'use strict';

const { featuresForUser } = require('../utils/planFeatures');
const { featureSubject } = require('../utils/effectiveOwner');
const asyncHandler = require('../utils/asyncHandler');

/**
 * Gates a route behind a per-plan capability flag (sync | backup | ownerPanel).
 * Resolves the caller's features LIVE from their active plan via featuresForUser
 * and 403s when the named feature is disabled. Mount AFTER requireAuth so
 * req.user is populated.
 */
function requireFeature(name) {
  return asyncHandler(async (req, res, next) => {
    // Sub-accounts inherit their PARENT's plan: an accountant gates against its
    // owner (req.ownerAccount), a BRANCH against its parent owner
    // (req.parentAccount) — never the sub-account's own empty subscription, which
    // would default every feature to TRUE and bypass a restricted parent's plan.
    // featureSubject returns self for a top-level owner/admin.
    const subject =
      featureSubject(req.user, {
        ownerAccount: req.ownerAccount,
        parentAccount: req.parentAccount,
      }) || req.user;
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
