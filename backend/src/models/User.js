'use strict';

const mongoose = require('mongoose');

const { Schema } = mongoose;

const DeviceSchema = new Schema(
  {
    deviceId: { type: String, required: true },
    installId: { type: String },
    platform: { type: String },
    model: { type: String },
    brand: { type: String },
    osVersion: { type: String },
    imei: { type: String, default: null },
    mac: { type: String, default: null },
    boundAt: { type: Date, default: Date.now },
    lastSeen: { type: Date, default: Date.now },
  },
  { _id: false }
);

const SubscriptionSchema = new Schema(
  {
    planCode: { type: String, default: null },
    status: {
      type: String,
      enum: ['none', 'pending', 'active', 'rejected', 'expired'],
      default: 'none',
    },
    startedAt: { type: Date, default: null },
    expiresAt: { type: Date, default: null },
  },
  { _id: false }
);

const UserSchema = new Schema(
  {
    name: { type: String, required: true, trim: true },
    generatorName: { type: String, default: null, trim: true },
    phone: { type: String, default: null, trim: true },
    username: {
      type: String,
      required: true,
      unique: true,
      trim: true,
      lowercase: true,
    },
    passwordHash: { type: String, required: true },
    // Bumped on every password change; embedded in the JWT (tv claim) and
    // compared in requireAuth so all tokens issued before a password change are
    // invalidated (401 TOKEN_STALE). See utils/token.js + middleware/auth.js.
    tokenVersion: { type: Number, default: 0 },
    role: { type: String, enum: ['owner', 'admin', 'accountant'], default: 'owner' },
    blocked: { type: Boolean, default: false },
    subscription: { type: SubscriptionSchema, default: () => ({}) },
    devices: { type: [DeviceSchema], default: [] },
    // Accountant sub-accounts: the parent owner/admin account, the branch the
    // accountant is scoped to, the granted permission keys, and the app-side
    // accountant UUID (for attribution round-trip with the device mirror).
    owner: { type: Schema.Types.ObjectId, ref: 'User', default: null },
    branchId: { type: String, default: null },
    permissions: { type: [String], default: [] },
    localId: { type: String, default: null, index: true },
    // Branch sub-accounts: a BRANCH is itself a `role:'owner'` User that is a
    // CHILD of the creating top-level owner. parentOwner = null for a top-level
    // owner; parentOwner = the creating owner's _id for a branch. A branch keeps
    // role:'owner' so all owner-scoped sync/backup/account logic applies to its
    // OWN data mirror unchanged (its effectiveOwner is itself), but it INHERITS
    // the parent's subscription/features and is cascade-blocked by the parent.
    // A branch may NOT create sub-branches (parentOwner-set callers are rejected).
    parentOwner: { type: Schema.Types.ObjectId, ref: 'User', default: null, index: true },
  },
  { timestamps: true }
);

module.exports = mongoose.model('User', UserSchema);
