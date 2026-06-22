'use strict';

/**
 * The id of the account whose data mirror a request operates on.
 *
 * Accountants are sub-accounts of an owner; they read/write the OWNER's mirror
 * (a per-account, push-only copy of the device's business data). For owners and
 * admins the effective owner is simply themselves.
 *
 * @param {object} user  the authenticated User doc (req.user)
 * @returns {*} the Mongo id to key SyncRecord by (owner for accountants, else self)
 */
function effectiveOwnerId(user) {
  if (user && user.role === 'accountant' && user.owner) {
    return user.owner;
  }
  return user && (user._id || user.id);
}

/**
 * The account whose subscription/feature flags gate a request.
 *
 * Accountants ALWAYS inherit their `owner`'s plan for gating.
 *
 * BRANCHES (role:'owner' with parentOwner set) split by the `independentPlan` flag:
 *  - INDEPENDENT branch (`independentPlan === true`, Flash v13 Phase D): gated on
 *    ITS OWN subscription/features — a brand-new generator with its own plan and
 *    its own super-admin approval. Returns self (so it is subscriptionBlocked /
 *    needs approval until the super-admin activates its plan).
 *  - LEGACY branch (`independentPlan` falsy): INHERITS its `parentOwner`'s plan,
 *    exactly as before — never gated on its own empty subscription (which would
 *    default every feature to true and bypass a restricted parent's plan).
 *
 * requireAuth pre-loads these parents (req.ownerAccount for accountants,
 * req.parentAccount for branches); pass them in to avoid an extra DB read.
 *
 * @param {object} user the authenticated User (req.user)
 * @param {object} [loaded] { ownerAccount, parentAccount } pre-loaded parents
 * @returns {object|null} the User whose plan to gate against (self for top-level)
 */
function featureSubject(user, loaded = {}) {
  if (!user) return null;
  if (user.role === 'accountant') return loaded.ownerAccount || null;
  if (user.parentOwner) {
    // Independent branch => its own plan; legacy branch => the parent's.
    if (user.independentPlan === true) return user;
    return loaded.parentAccount || null;
  }
  return user;
}

module.exports = { effectiveOwnerId, featureSubject };
