'use strict';

const Plan = require('../models/Plan');
const { HttpError } = require('../middleware/error');

/**
 * Identity of a device is keyed primarily off the OS-stable `deviceId`.
 *
 * Reinstall-safety: the app-generated `installId` changes on every reinstall /
 * data-clear, but the same physical handset keeps the same OS `deviceId`. So we
 * match on `deviceId` FIRST — a reinstall on the same phone is recognised as the
 * SAME device (refreshes the binding) instead of being treated as a brand-new
 * device that would trip DEVICE_LIMIT. `installId` is only a fallback for the
 * (rare) case where one side has no `deviceId`.
 */
function sameDevice(existing, incoming) {
  // Primary: same OS-stable deviceId -> same physical handset (ignore installId).
  if (existing.deviceId && incoming.deviceId) {
    return existing.deviceId === incoming.deviceId;
  }
  // Fallback: no deviceId on one side, but matching app-generated installId.
  if (existing.installId && incoming.installId) {
    return existing.installId === incoming.installId;
  }
  return false;
}

/** Returns the effective max device count for a user's ACTIVE plan (default 1). */
async function maxDevicesFor(user) {
  const sub = user.subscription || {};
  if (sub.status === 'active' && sub.planCode) {
    const plan = await Plan.findOne({ code: sub.planCode });
    if (plan && Number.isFinite(plan.maxDevices)) return plan.maxDevices;
  }
  // No active plan: still allow the single calling device so login works during
  // trial / pending. The active-plan limit is what the contract enforces.
  return 1;
}

/**
 * Upserts a device fingerprint into user.devices.
 * - Existing device: refresh fields + lastSeen.
 * - New device: enforce the active plan's maxDevices, else 403 DEVICE_LIMIT.
 * Mutates `user` in place (does NOT save). Returns the affected subdoc.
 */
async function upsertDevice(user, incoming) {
  if (!incoming || !incoming.deviceId) {
    throw new HttpError(400, 'device.deviceId is required', 'VALIDATION');
  }

  const now = new Date();
  const existing = user.devices.find((d) => sameDevice(d, incoming));

  if (existing) {
    existing.installId = incoming.installId || existing.installId;
    existing.deviceId = incoming.deviceId || existing.deviceId;
    existing.platform = incoming.platform || existing.platform;
    existing.model = incoming.model || existing.model;
    existing.brand = incoming.brand || existing.brand;
    existing.osVersion = incoming.osVersion || existing.osVersion;
    if (incoming.imei !== undefined) existing.imei = incoming.imei || existing.imei;
    if (incoming.mac !== undefined) existing.mac = incoming.mac || existing.mac;
    existing.lastSeen = now;
    return existing;
  }

  const limit = await maxDevicesFor(user);
  if (user.devices.length >= limit) {
    throw new HttpError(
      403,
      `Device limit reached (${limit}). Unbind another device first.`,
      'DEVICE_LIMIT'
    );
  }

  user.devices.push({
    deviceId: incoming.deviceId,
    installId: incoming.installId || null,
    platform: incoming.platform || null,
    model: incoming.model || null,
    brand: incoming.brand || null,
    osVersion: incoming.osVersion || null,
    imei: incoming.imei || null,
    mac: incoming.mac || null,
    boundAt: now,
    lastSeen: now,
  });

  return user.devices[user.devices.length - 1];
}

module.exports = { sameDevice, maxDevicesFor, upsertDevice };
