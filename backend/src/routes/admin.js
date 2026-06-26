'use strict';

const fs = require('fs');
const express = require('express');
const multer = require('multer');
const { body } = require('express-validator');
const env = require('../config/env');
const { requireAuth, requireAdmin } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const ctrl = require('../controllers/adminController');
const landingCtrl = require('../controllers/landingController');
const { HttpError } = require('../middleware/error');

const router = express.Router();

// Every admin route requires a valid JWT + admin role.
router.use(requireAuth, requireAdmin);

// ---- Banner image upload (multipart) ----
// Disk storage: UPLOADS_DIR/<timestamp>-<rand>.<ext>. Images only, 10 MB cap.
const bannerStorage = multer.diskStorage({
  destination(req, file, cb) {
    fs.mkdir(env.UPLOADS_DIR, { recursive: true }, (err) => cb(err, env.UPLOADS_DIR));
  },
  filename(req, file, cb) {
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const rand = Math.random().toString(36).slice(2, 8);
    const ext = (file.originalname.match(/\.[a-z0-9]+$/i) || ['.jpg'])[0].toLowerCase();
    cb(null, `banner-${stamp}-${rand}${ext}`);
  },
});
const bannerUpload = multer({
  storage: bannerStorage,
  limits: { fileSize: 10 * 1024 * 1024 }, // 10 MB cap
  fileFilter(req, file, cb) {
    if (/^image\//.test(file.mimetype)) return cb(null, true);
    return cb(new HttpError(400, 'Only image uploads are allowed', 'NOT_AN_IMAGE'));
  },
});

// ---- Users ----
router.get('/users', ctrl.listUsers);
router.post(
  '/users',
  [
    body('name').isString().trim().notEmpty().withMessage('name is required'),
    body('username').isString().trim().notEmpty().withMessage('username is required'),
    body('password').isString().isLength({ min: 4 }).withMessage('password must be at least 4 chars'),
    body('role').optional().isIn(['owner', 'admin']).withMessage('invalid role'),
  ],
  validate,
  ctrl.createUser
);
router.get('/users/:id', ctrl.getUser);
router.delete('/users/:id', ctrl.deleteUser);

// Latest data uploaded from the apps across all accounts (dashboard home).
router.get('/recent-data', ctrl.recentData);

// Synced business data mirror for one owner (?entity=subscribers).
router.get('/users/:id/data', ctrl.getUserData);
// Hard-delete a single mirrored row (the mirror is otherwise read-only).
router.delete('/users/:id/data/:entity/:localId', ctrl.deleteUserData);

router.put(
  '/users/:id/blocked',
  [body('blocked').isBoolean().withMessage('blocked must be boolean')],
  validate,
  ctrl.setBlocked
);
router.put(
  '/users/:id/plan',
  [
    body('planCode').isString().trim().notEmpty().withMessage('planCode is required'),
    body('status').optional().isIn(['none', 'pending', 'active', 'rejected', 'expired']),
  ],
  validate,
  ctrl.setPlan
);
router.post('/users/:id/approve-plan', ctrl.approvePlan);
router.post('/users/:id/reject-plan', ctrl.rejectPlan);
router.delete('/users/:id/devices/:deviceId', ctrl.unbindDevice);

// ---- Plans ----
router.get('/plans', ctrl.listPlans);
router.put(
  '/plans',
  [
    body('code').isString().trim().notEmpty().withMessage('code is required'),
    body('name').optional().isString(),
    body('durationDays').optional().isInt({ min: 1 }),
    body('maxDevices').optional().isInt({ min: 1 }),
    body('price').optional().isNumeric(),
    body('active').optional().isBoolean(),
    body('syncEnabled').optional().isBoolean(),
    body('backupEnabled').optional().isBoolean(),
    body('ownerPanelEnabled').optional().isBoolean(),
    body('multiBranchEnabled').optional().isBoolean(),
  ],
  validate,
  ctrl.upsertPlan
);
router.delete('/plans/:code', ctrl.deletePlan);

// ---- Landing: advertisement banners (admin CRUD + image upload) ----
router.get('/banners', landingCtrl.listBanners);
router.post('/banners', bannerUpload.single('image'), landingCtrl.createBanner);
router.put('/banners/:id', bannerUpload.single('image'), landingCtrl.updateBanner);
router.delete('/banners/:id', landingCtrl.deleteBanner);

// ---- Landing: promo video (singleton) ----
router.get('/landing-video', landingCtrl.getLandingVideo);
router.put(
  '/landing-video',
  [
    body('url').optional({ nullable: true }).isString(),
    body('enabled').optional().isBoolean(),
  ],
  validate,
  landingCtrl.setLandingVideo
);

module.exports = router;
