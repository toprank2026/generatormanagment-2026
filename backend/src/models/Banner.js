'use strict';

const mongoose = require('mongoose');

const { Schema } = mongoose;

/**
 * A landing-page advertisement banner. The uploaded image lives on disk (served
 * statically — see server.js `/uploads`); `imagePath` is the stored file path
 * relative to the uploads dir, surfaced publicly as an absolute `imageUrl`.
 */
const BannerSchema = new Schema(
  {
    // Stored file path/name on disk (relative to the banners uploads dir).
    imagePath: { type: String, required: true },
    // Aspect ratio the landing page should honour when rendering the banner.
    ratio: { type: String, enum: ['1:1', '2:1', '3:1'], default: '2:1' },
    enabled: { type: Boolean, default: true },
    order: { type: Number, default: 0 },
  },
  { timestamps: { createdAt: 'createdAt', updatedAt: false } }
);

module.exports = mongoose.model('Banner', BannerSchema);
