'use strict';

const bcrypt = require('bcryptjs');
const Plan = require('../models/Plan');
const User = require('../models/User');
const env = require('../config/env');

const DEFAULT_PLANS = [
  {
    code: 'trial',
    name: 'Trial',
    durationDays: 14,
    maxDevices: 1,
    price: 0,
    description: 'Free 14-day trial on a single device.',
    active: true,
  },
  {
    code: 'monthly',
    name: 'Monthly',
    durationDays: 30,
    maxDevices: 1,
    price: 10000,
    description: 'Monthly subscription for one device.',
    active: true,
  },
  {
    code: 'yearly',
    name: 'Yearly',
    durationDays: 365,
    maxDevices: 2,
    price: 100000,
    description: 'Yearly subscription, up to two devices.',
    active: true,
  },
];

/** Ensure the default plans exist (create missing ones; never overwrite edits). */
async function ensurePlans() {
  for (const p of DEFAULT_PLANS) {
    // eslint-disable-next-line no-await-in-loop
    const existing = await Plan.findOne({ code: p.code });
    if (!existing) {
      // eslint-disable-next-line no-await-in-loop
      await Plan.create(p);
      console.log(`[seed] created plan "${p.code}"`);
    }
  }
}

/** Ensure a bootstrap admin from ADMIN_* env vars exists. */
async function ensureAdmin() {
  // Defense-in-depth: never seed/refresh the bootstrap admin in production with
  // a missing/default ADMIN_PASSWORD. (server start() already fails fast via
  // env.validateSecrets(); this also guards a seed invoked outside start().)
  if (env.NODE_ENV === 'production') env.validateSecrets();

  const username = String(env.ADMIN_USERNAME).toLowerCase();
  const existing = await User.findOne({ username });
  if (existing) {
    // Make sure the configured account always has admin role + is unblocked.
    if (existing.role !== 'admin' || existing.blocked) {
      existing.role = 'admin';
      existing.blocked = false;
      await existing.save();
    }
    return;
  }

  const passwordHash = await bcrypt.hash(env.ADMIN_PASSWORD, 10);
  await User.create({
    name: 'Administrator',
    username,
    passwordHash,
    role: 'admin',
    subscription: { status: 'none', planCode: null },
    devices: [],
  });
  console.log(`[seed] created bootstrap admin "${username}"`);
}

/** Run all seeders. Safe to call on every boot (idempotent). */
async function runSeed() {
  await ensurePlans();
  await ensureAdmin();
}

module.exports = { runSeed, ensurePlans, ensureAdmin, DEFAULT_PLANS };
