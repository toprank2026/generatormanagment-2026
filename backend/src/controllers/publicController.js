'use strict';

const User = require('../models/User');
const SyncRecord = require('../models/SyncRecord');
const asyncHandler = require('../utils/asyncHandler');

/**
 * Receipt fields exposed publicly (scan-a-QR view). Whitelisted so the public
 * response never leaks raw mirror columns we don't intend to share.
 */
const PUBLIC_RECEIPT_FIELDS = [
  'receipt_no',
  'month',
  'amps_snapshot',
  'price_snapshot',
  'paid_amount',
  'remaining_after',
  'issued_at',
  'status',
];

/**
 * GET /api/public/receipt/:uuid  (PUBLIC — no auth)
 *
 * Resolves a receipt by its device UUID across ALL accounts' mirrors so a
 * scanned QR can be viewed without logging in. Returns the whitelisted receipt
 * fields plus the subscriber and generator names for display.
 *
 * Response: { found, receipt | null, subscriberName | null, generatorName | null }
 */
const getPublicReceipt = asyncHandler(async (req, res) => {
  const { uuid } = req.params;

  const rec = await SyncRecord.findOne({
    entity: 'receipts',
    localId: uuid,
    deleted: false,
  });

  if (!rec || !rec.data) {
    return res
      .status(200)
      .json({ found: false, receipt: null, subscriberName: null, generatorName: null });
  }

  const data = rec.data || {};
  const receipt = {};
  for (const field of PUBLIC_RECEIPT_FIELDS) {
    receipt[field] = data[field] ?? null;
  }

  // Subscriber name from the same account's mirror.
  let subscriberName = null;
  if (data.subscriber_id) {
    const sub = await SyncRecord.findOne({
      user: rec.user,
      entity: 'subscribers',
      localId: data.subscriber_id,
    });
    subscriberName = sub && sub.data ? sub.data.name ?? null : null;
  }

  // Generator name from the owning account.
  let generatorName = null;
  const owner = await User.findById(rec.user);
  if (owner) generatorName = owner.generatorName ?? null;

  res.status(200).json({ found: true, receipt, subscriberName, generatorName });
});

module.exports = { getPublicReceipt };
