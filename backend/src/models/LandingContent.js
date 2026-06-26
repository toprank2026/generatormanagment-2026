'use strict';

const mongoose = require('mongoose');

const { Schema } = mongoose;

/**
 * Singleton document holding miscellaneous landing-page content that isn't a
 * banner. Currently: the single promo video (url + enabled flag). Always read /
 * written via `getSingleton()` so there is exactly one row.
 */
const LandingContentSchema = new Schema(
  {
    // A fixed key so we can upsert the one-and-only document.
    key: { type: String, default: 'singleton', unique: true },
    videoUrl: { type: String, default: '' },
    videoEnabled: { type: Boolean, default: false },
  },
  { timestamps: true }
);

/** Fetch (or lazily create) the one settings document. */
LandingContentSchema.statics.getSingleton = async function getSingleton() {
  let doc = await this.findOne({ key: 'singleton' });
  if (!doc) {
    doc = await this.create({ key: 'singleton' });
  }
  return doc;
};

module.exports = mongoose.model('LandingContent', LandingContentSchema);
