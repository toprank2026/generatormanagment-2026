'use strict';

const mongoose = require('mongoose');

const { Schema } = mongoose;

const PlanSchema = new Schema(
  {
    code: { type: String, required: true, unique: true, trim: true },
    name: { type: String, required: true, trim: true },
    durationDays: { type: Number, required: true, default: 30 },
    maxDevices: { type: Number, required: true, default: 1 },
    price: { type: Number, default: 0 },
    description: { type: String, default: '' },
    active: { type: Boolean, default: true },
    // Per-plan capability flags (default true so existing plans keep all
    // capabilities). Resolved live from the account's active plan.
    syncEnabled: { type: Boolean, default: true },
    backupEnabled: { type: Boolean, default: true },
    ownerPanelEnabled: { type: Boolean, default: true },
  },
  { timestamps: true }
);

module.exports = mongoose.model('Plan', PlanSchema);
