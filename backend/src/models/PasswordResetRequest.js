'use strict';

const mongoose = require('mongoose');

const { Schema } = mongoose;

/**
 * Flash v42 item 4 — a generator owner's "forgot password" request, approved by
 * hand in the super-admin panel.
 *
 * The flow is deliberately NOT self-service: the app posts the identity
 * (username + the account's registered phone) together with the password the
 * owner WANTS, and this document parks that request until a super admin decides.
 * Approval is the only moment the account's password actually changes.
 *
 * Two rules this schema encodes:
 *  - `newPasswordHash` is stored ALREADY bcrypt-hashed by the controller; the
 *    plaintext password never reaches this collection (nor any log/response).
 *  - `code` is the 6-digit reference shown to the owner in the app so they can
 *    read it back to the super admin, who matches it against the panel row. It
 *    is an identity *reference*, not a secret that can approve anything by
 *    itself — only a super admin can flip `status` to 'approved'.
 */
const PasswordResetRequestSchema = new Schema(
  {
    user: { type: Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    // Snapshot of the identity as submitted, kept for the admin list/search even
    // if the account later renames. `username` is lowercased to match the
    // User.username casing (User.js lowercases it too).
    username: { type: String, default: null, trim: true, lowercase: true },
    phone: { type: String, default: null, trim: true },
    // bcrypt hash of the requested password — written onto the user only on
    // approval. NEVER plaintext.
    newPasswordHash: { type: String, required: true },
    // 6-digit verification reference quoted by the owner to the super admin.
    code: { type: String, required: true, trim: true },
    status: {
      type: String,
      enum: ['pending', 'approved', 'rejected', 'expired'],
      default: 'pending',
      index: true,
    },
    // Free-text reason recorded by the super admin (mainly on reject).
    note: { type: String, default: null },
    decidedAt: { type: Date, default: null },
    decidedBy: { type: Schema.Types.ObjectId, ref: 'User', default: null },
    // 24 h from creation. Intentionally NOT a TTL index: an expired request must
    // stay visible (as 'expired') in the admin history rather than vanish — this
    // collection is an audit trail of who asked for a password change and when.
    expiresAt: { type: Date, required: true },
    // Requester IP, recorded for abuse triage on this public, rate-limited route.
    ip: { type: String, default: null },
  },
  { timestamps: true }
);

// The "is there already an open request for this account" lookup (a new request
// supersedes the previous pending one) and the panel's status filter.
PasswordResetRequestSchema.index({ user: 1, status: 1 });
// Newest-first ordering for the paginated admin list.
PasswordResetRequestSchema.index({ createdAt: -1 });

/**
 * True once the request has passed its 24 h window. `status` is only flipped to
 * 'expired' lazily (when read/decided), so a stored 'pending' is not proof the
 * request is still live — always gate on this. Mirrors the tolerant clock
 * handling of `utils/serialize.isSubscriptionActive`: a missing/unparseable
 * expiry is treated as "no expiry" rather than silently killing the request.
 *
 * @param {Date} [now=new Date()]  override the clock (tests)
 * @returns {boolean}
 */
PasswordResetRequestSchema.methods.isExpired = function isExpired(now = new Date()) {
  if (!this.expiresAt) return false;
  const exp = this.expiresAt instanceof Date ? this.expiresAt : new Date(this.expiresAt);
  if (Number.isNaN(exp.getTime())) return false;
  return exp.getTime() <= now.getTime();
};

module.exports = mongoose.model('PasswordResetRequest', PasswordResetRequestSchema);
