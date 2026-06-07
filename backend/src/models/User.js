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
    role: { type: String, enum: ['owner', 'admin'], default: 'owner' },
    blocked: { type: Boolean, default: false },
    subscription: { type: SubscriptionSchema, default: () => ({}) },
    devices: { type: [DeviceSchema], default: [] },
  },
  { timestamps: true }
);

module.exports = mongoose.model('User', UserSchema);
