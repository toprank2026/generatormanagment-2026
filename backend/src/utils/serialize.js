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

function serializeSubscription(sub) {
  const s = sub || {};
  return {
    planCode: s.planCode || null,
    status: s.status || 'none',
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
    blocked: Boolean(user.blocked),
    createdAt: toIso(user.createdAt),
    subscription: serializeSubscription(user.subscription),
    devices,
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
  serializeSubscription,
  serializeDevice,
  serializeAccount,
  serializePlan,
  serializeBackup,
};
