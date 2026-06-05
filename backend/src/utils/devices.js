'use strict';

const Plan = require('../models/Plan');
const { HttpError } = require('../middleware/error');

/**
 * Identity of a device is keyed off installId + deviceId. Two payloads refer to
 * the same physical binding when both match (installId is app-generated and the
 * primary key; deviceId is the OS-stable id).
 */
function sameDevice(existing, incoming) {
  const sameInstall =
    existing.installId && incoming.installId
      ? existing.installId === incoming.installId
      : false;
  const sameDeviceId =
    existing.deviceId && incoming.deviceId
      ? existing.deviceId === incoming.deviceId
      : false;
  // If both ids are present, require both to match; otherwise fall back to
  // whichever id is available so we never duplicate the same handset.
  if (existing.installId && incoming.installId && existing.deviceId && incoming.deviceId) {
    return sameInstall && sameDeviceId;
  }
  return sameInstall || sameDeviceId;
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
