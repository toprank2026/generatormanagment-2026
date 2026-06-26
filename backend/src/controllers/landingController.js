'use strict';

const fs = require('fs');
const path = require('path');
const Banner = require('../models/Banner');
const LandingContent = require('../models/LandingContent');
const env = require('../config/env');
const asyncHandler = require('../utils/asyncHandler');
const { HttpError } = require('../middleware/error');

const VALID_RATIOS = ['1:1', '2:1', '3:1'];

/** Absolute path of a stored banner file, guarded against path traversal. */
function bannerFilePath(imagePath) {
  const base = env.UPLOADS_DIR;
  const resolved = path.normalize(path.join(base, imagePath));
  if (resolved !== base && !resolved.startsWith(base + path.sep)) {
    throw new HttpError(400, 'Invalid banner file path', 'BANNER_BAD_PATH');
  }
  return resolved;
}

/** Best-effort delete of a stored banner image file (ignore missing). */
function unlinkBannerFile(imagePath) {
  if (!imagePath) return;
  try {
    const fp = bannerFilePath(imagePath);
    if (fs.existsSync(fp)) fs.unlinkSync(fp);
  } catch (e) {
    // eslint-disable-next-line no-console
    console.warn('[landing] failed to delete banner file', imagePath, e.message);
  }
}

/** Public absolute URL for a stored banner image. */
function bannerImageUrl(imagePath) {
  return imagePath ? `/uploads/${imagePath}` : null;
}

/** Admin-facing banner shape (includes id + imagePath + imageUrl). */
function serializeBanner(b) {
  return {
    id: String(b._id || b.id),
    imagePath: b.imagePath,
    imageUrl: bannerImageUrl(b.imagePath),
    ratio: b.ratio || '2:1',
    enabled: b.enabled !== false,
    order: b.order || 0,
    createdAt: b.createdAt ? new Date(b.createdAt).toISOString() : null,
  };
}

/** Parse a boolean-ish multipart field ("true"/"false"/"1"/"0"). */
function parseBool(v, fallback) {
  if (v === undefined || v === null || v === '') return fallback;
  if (typeof v === 'boolean') return v;
  const s = String(v).toLowerCase();
  return s === 'true' || s === '1' || s === 'yes' || s === 'on';
}

// ---------------------------------------------------------------------------
// Banners — admin CRUD
// ---------------------------------------------------------------------------

/** GET /api/admin/banners — list all (admin screen). Newest order first. */
const listBanners = asyncHandler(async (req, res) => {
  const banners = await Banner.find({}).sort({ order: 1, createdAt: 1 });
  res.status(200).json({ banners: banners.map(serializeBanner) });
});

/** POST /api/admin/banners (multipart) — image file written by multer. */
const createBanner = asyncHandler(async (req, res) => {
  if (!req.file) {
    throw new HttpError(400, 'No image uploaded (expected field "image")', 'NO_FILE');
  }
  const ratio = VALID_RATIOS.includes(req.body.ratio) ? req.body.ratio : '2:1';
  const banner = await Banner.create({
    imagePath: req.file.filename,
    ratio,
    enabled: parseBool(req.body.enabled, true),
    order: Number.isFinite(Number(req.body.order)) ? Number(req.body.order) : 0,
  });
  res.status(201).json({ banner: serializeBanner(banner) });
});

/** PUT /api/admin/banners/:id — edit ratio/enabled/order (+ optional new image). */
const updateBanner = asyncHandler(async (req, res) => {
  const banner = await Banner.findById(req.params.id);
  if (!banner) {
    throw new HttpError(404, 'Banner not found', 'BANNER_NOT_FOUND');
  }
  if (req.body.ratio !== undefined) {
    if (!VALID_RATIOS.includes(req.body.ratio)) {
      throw new HttpError(400, 'Invalid ratio', 'BANNER_BAD_RATIO');
    }
    banner.ratio = req.body.ratio;
  }
  if (req.body.enabled !== undefined) {
    banner.enabled = parseBool(req.body.enabled, banner.enabled);
  }
  if (req.body.order !== undefined && req.body.order !== '' && Number.isFinite(Number(req.body.order))) {
    banner.order = Number(req.body.order);
  }
  // Optional new image: swap the file and delete the old one.
  if (req.file) {
    const oldPath = banner.imagePath;
    banner.imagePath = req.file.filename;
    await banner.save();
    unlinkBannerFile(oldPath);
    return res.status(200).json({ banner: serializeBanner(banner) });
  }
  await banner.save();
  return res.status(200).json({ banner: serializeBanner(banner) });
});

/** DELETE /api/admin/banners/:id — remove record + image file. */
const deleteBanner = asyncHandler(async (req, res) => {
  const banner = await Banner.findById(req.params.id);
  if (!banner) {
    throw new HttpError(404, 'Banner not found', 'BANNER_NOT_FOUND');
  }
  const { imagePath } = banner;
  await banner.deleteOne();
  unlinkBannerFile(imagePath);
  res.status(200).json({ ok: true });
});

// ---------------------------------------------------------------------------
// Promo video — admin manage (singleton)
// ---------------------------------------------------------------------------

/** GET /api/admin/landing-video — current video setting for the admin screen. */
const getLandingVideo = asyncHandler(async (req, res) => {
  const doc = await LandingContent.getSingleton();
  res.status(200).json({
    video: { url: doc.videoUrl || '', enabled: !!doc.videoEnabled },
  });
});

/** PUT /api/admin/landing-video { url, enabled } — empty url disables. */
const setLandingVideo = asyncHandler(async (req, res) => {
  const doc = await LandingContent.getSingleton();
  const url = typeof req.body.url === 'string' ? req.body.url.trim() : '';
  doc.videoUrl = url;
  // An empty url forces disabled regardless of the enabled flag.
  doc.videoEnabled = url ? parseBool(req.body.enabled, true) : false;
  await doc.save();
  res.status(200).json({
    video: { url: doc.videoUrl || '', enabled: !!doc.videoEnabled },
  });
});

// ---------------------------------------------------------------------------
// Public landing payload (banners + video) — used by publicController.
// ---------------------------------------------------------------------------

/** Auto-detect the video provider from its watch URL. */
function detectProvider(url) {
  const u = String(url || '').toLowerCase();
  if (u.includes('youtube.com') || u.includes('youtu.be')) return 'youtube';
  if (u.includes('vimeo.com')) return 'vimeo';
  return 'direct';
}

/** Build the public landing payload: enabled banners (sorted) + enabled video. */
async function buildLandingPayload() {
  const banners = await Banner.find({ enabled: true }).sort({ order: 1, createdAt: 1 });
  const doc = await LandingContent.getSingleton();
  let video = null;
  if (doc.videoEnabled && doc.videoUrl) {
    video = { url: doc.videoUrl, provider: detectProvider(doc.videoUrl) };
  }
  return {
    banners: banners.map((b) => ({
      id: String(b._id),
      imageUrl: bannerImageUrl(b.imagePath),
      ratio: b.ratio || '2:1',
      order: b.order || 0,
    })),
    video,
  };
}

module.exports = {
  listBanners,
  createBanner,
  updateBanner,
  deleteBanner,
  getLandingVideo,
  setLandingVideo,
  buildLandingPayload,
  detectProvider,
  serializeBanner,
  bannerImageUrl,
};
