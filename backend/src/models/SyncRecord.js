'use strict';

const mongoose = require('mongoose');

const { Schema } = mongoose;

/**
 * A single mirrored business-data row pushed from an owner's device.
 *
 * The device stays the source of truth; this collection is a per-account mirror
 * the admin panel reads. Each record is keyed by (user, entity, localId) where
 * `localId` is the device's UUID for the row and `data` is the raw SQLite row
 * (snake_case fields). Tombstones set `deleted = true` and may omit `data`.
 */
const SyncRecordSchema = new Schema(
  {
    user: { type: Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    entity: { type: String, required: true },
    localId: { type: String, required: true },
    data: { type: Schema.Types.Mixed, default: null },
    deleted: { type: Boolean, default: false },
    // Device-supplied change time; drives the pull `since` query. We manage it
    // ourselves (not Mongoose timestamps) so it reflects the device clock.
    updatedAt: { type: Date },
  },
  // Track createdAt automatically but keep `updatedAt` device-controlled.
  { timestamps: { createdAt: true, updatedAt: false } }
);

// One mirrored row per (account, entity, localId).
SyncRecordSchema.index({ user: 1, entity: 1, localId: 1 }, { unique: true });

module.exports = mongoose.model('SyncRecord', SyncRecordSchema);
