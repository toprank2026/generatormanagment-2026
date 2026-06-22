'use strict';

/**
 * Serialisers that produce the exact JSON shapes defined in API_CONTRACT.md.
 * Centralised so every controller returns identical objects.
 */

function toIso(d) {
  if (!d) return null;
  const date = d instanceof Date ? d : new Date(d);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

/**
 * A subscription is *effectively active* only when its stored status is 'active'
 * AND it has not passed its expiry. `expiresAt` being null/absent means "no
 * expiry set" (treated as not-yet-expired). This is the single source of truth
 * for "is this plan still in force" — used by both serializeSubscription (which
 * downgrades the reported status to 'expired' once past expiry) and
 * planFeatures.featuresForUser (which stops granting plan features once expired).
 *
 * @param {object} sub  the subscription subdoc / plain object
 * @param {Date}   [now=new Date()]  override the clock (tests)
 * @returns {boolean}
 */
function isSubscriptionActive(sub, now = new Date()) {
  const s = sub || {};
  if (s.status !== 'active') return false;
  if (!s.expiresAt) return true;
  const exp = s.expiresAt instanceof Date ? s.expiresAt : new Date(s.expiresAt);
  if (Number.isNaN(exp.getTime())) return true; // unparseable -> treat as no expiry
  return exp.getTime() > now.getTime();
}

function serializeSubscription(sub) {
  const s = sub || {};
  // Report 'expired' when the stored status is 'active' but the plan has passed
  // its expiry, so clients (which key off the status string) stop treating it as
  // active. Other statuses pass through unchanged.
  const status =
    s.status === 'active' && !isSubscriptionActive(s) ? 'expired' : s.status || 'none';
  return {
    planCode: s.planCode || null,
    status,
    startedAt: toIso(s.startedAt),
    expiresAt: toIso(s.expiresAt),
  };
}

/**
 * @param {object} device   mongoose subdoc / plain object
 * @param {string} [currentDeviceId]  the deviceId of the calling device
 */
function serializeDevice(device, currentDeviceId) {
  const d = device || {};
  return {
    deviceId: d.deviceId,
    installId: d.installId || null,
    platform: d.platform || null,
    model: d.model || null,
    brand: d.brand || null,
    osVersion: d.osVersion || null,
    imei: d.imei || null,
    mac: d.mac || null,
    boundAt: toIso(d.boundAt),
    lastSeen: toIso(d.lastSeen),
    current: Boolean(currentDeviceId) && d.deviceId === currentDeviceId,
  };
}

/**
 * The Account object (auth + admin responses).
 * @param {object} user  mongoose User doc
 * @param {string} [currentDeviceId]  marks the calling device current:true
 */
function serializeAccount(user, currentDeviceId) {
  const devices = (user.devices || []).map((d) =>
    serializeDevice(d, currentDeviceId)
  );
  return {
    id: String(user._id || user.id),
    name: user.name,
    generatorName: user.generatorName || null,
    phone: user.phone || null,
    username: user.username,
    role: user.role || 'owner',
    // Accountant sub-account fields (null/[] for owners/admins).
    ownerId: user.owner ? String(user.owner) : null,
    // Branch sub-account: the parent top-level owner (null for a top-level owner).
    parentOwnerId: user.parentOwner ? String(user.parentOwner) : null,
    // Flash v13 Phase D: true for an INDEPENDENT branch gated on its own plan;
    // false for a top-level owner or a LEGACY (inheriting) branch.
    independentPlan: Boolean(user.independentPlan),
    branchId: user.branchId || null,
    permissions: Array.isArray(user.permissions) ? user.permissions : [],
    localId: user.localId || null,
    blocked: Boolean(user.blocked),
    createdAt: toIso(user.createdAt),
    subscription: serializeSubscription(user.subscription),
    devices,
  };
}

/**
 * Compact view of a BRANCH sub-account, as returned by the branch management
 * endpoints (POST/GET /api/account/branches). A branch is itself a
 * `role:'owner'` User whose parentOwner is the caller — this is the panel-facing
 * shape (no secrets), not a full Account / login response.
 */
function serializeBranch(user) {
  const u = user || {};
  return {
    id: String(u._id || u.id),
    generatorName: u.generatorName || u.name || null,
    name: u.name || null,
    phone: u.phone || null,
    username: u.username,
    parentOwnerId: u.parentOwner ? String(u.parentOwner) : null,
    // Flash v13 Phase D: an independent branch has its own plan/approval (the
    // panel surfaces its own subscription status); legacy branches inherit.
    independentPlan: Boolean(u.independentPlan),
    subscription: serializeSubscription(u.subscription),
    blocked: Boolean(u.blocked),
    createdAt: toIso(u.createdAt),
  };
}

function serializePlan(plan) {
  const p = plan || {};
  return {
    code: p.code,
    name: p.name,
    durationDays: p.durationDays,
    maxDevices: p.maxDevices,
    price: p.price ?? 0,
    description: p.description || '',
    active: p.active !== false,
    syncEnabled: p.syncEnabled !== false,
    backupEnabled: p.backupEnabled !== false,
    ownerPanelEnabled: p.ownerPanelEnabled !== false,
    multiBranchEnabled: p.multiBranchEnabled === true,
  };
}

function serializeBackup(backup) {
  const b = backup || {};
  return {
    id: String(b._id || b.id),
    size: b.size || 0,
    note: b.note || null,
    createdAt: toIso(b.createdAt),
  };
}

module.exports = {
  toIso,
  isSubscriptionActive,
  serializeSubscription,
  serializeDevice,
  serializeAccount,
  serializeBranch,
  serializePlan,
  serializeBackup,
};
