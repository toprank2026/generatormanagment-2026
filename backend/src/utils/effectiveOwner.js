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

module.exports = { effectiveOwnerId };
