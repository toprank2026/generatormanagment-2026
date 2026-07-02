'use strict';

const asyncHandler = require('../utils/asyncHandler');
const { serializeDevice } = require('../utils/serialize');
const { upsertDevice } = require('../utils/devices');
const { HttpError } = require('../middleware/error');

/** GET /api/device (auth)
 *  v23 (§4.3): optional ?current=<deviceId> marks the caller's OWN device so the
 *  app can label "(this device)" and warn before unbinding it. Additive — old
 *  clients that omit it get `current:false` for every row (prior behavior). */
const list = asyncHandler(async (req, res) => {
  const current = typeof req.query.current === 'string' ? req.query.current : undefined;
  const devices = (req.user.devices || []).map((d) => serializeDevice(d, current));
  res.status(200).json({ devices });
});

/** POST /api/device/bind (auth) — enforces plan maxDevices on new devices. */
const bind = asyncHandler(async (req, res) => {
  const { device } = req.body;
  const subdoc = await upsertDevice(req.user, device);
  await req.user.save();
  res.status(200).json({ device: serializeDevice(subdoc, device.deviceId) });
});

/** DELETE /api/device/:deviceId (auth) — unbind a device. */
const unbind = asyncHandler(async (req, res) => {
  const { deviceId } = req.params;
  const before = req.user.devices.length;
  req.user.devices = req.user.devices.filter((d) => d.deviceId !== deviceId);
  if (req.user.devices.length === before) {
    throw new HttpError(404, 'Device not found', 'DEVICE_NOT_FOUND');
  }
  await req.user.save();
  res.status(200).json({ ok: true });
});

module.exports = { list, bind, unbind };
