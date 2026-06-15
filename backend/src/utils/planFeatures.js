'use strict';

const Plan = require('../models/Plan');

/**
 * Resolve the capability flags for a plan by its code. Each flag is enabled
 * unless the plan explicitly disables it (`<x>Enabled === false`). A missing
 * plan grants all capabilities (every flag true).
 *
 * @param {string} code  the plan's `code`
 * @returns {Promise<{sync: boolean, backup: boolean, ownerPanel: boolean}>}
 */
async function planFeaturesByCode(code) {
  const plan = code ? await Plan.findOne({ code }) : null;
  if (!plan) {
    return { sync: true, backup: true, ownerPanel: true, multiBranch: false };
  }
  return {
    sync: plan.syncEnabled !== false,
    backup: plan.backupEnabled !== false,
    ownerPanel: plan.ownerPanelEnabled !== false,
    // Opt-in upgrade: granted only when the plan explicitly enables it.
    multiBranch: plan.multiBranchEnabled === true,
  };
}

/**
 * Resolve the capability flags for a user, live from their ACTIVE plan. When
 * the user has no active subscription (or no plan), all capabilities are
 * granted (every flag true).
 *
 * @param {object} user  mongoose User doc / plain object
 * @returns {Promise<{sync: boolean, backup: boolean, ownerPanel: boolean}>}
 */
async function featuresForUser(user) {
  const sub = user && user.subscription;
  if (sub && sub.status === 'active' && sub.planCode) {
    return planFeaturesByCode(sub.planCode);
  }
  return { sync: true, backup: true, ownerPanel: true, multiBranch: false };
}

module.exports = { planFeaturesByCode, featuresForUser };
