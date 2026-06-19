'use strict';

const fs = require('fs');
const path = require('path');
const express = require('express');
const multer = require('multer');
const env = require('../config/env');
const { requireAuth } = require('../middleware/auth');
const { requireFeature } = require('../middleware/requireFeature');
const { effectiveOwnerId } = require('../utils/effectiveOwner');
const { upload, list, download, remove } = require('../controllers/backupController');

const router = express.Router();

router.use(requireAuth);
// Cloud backup is a per-plan capability; reject every backup endpoint when off.
router.use(requireFeature('backup'));

// Disk storage: BACKUP_DIR/<ownerId>/<timestamp>-moldati.db. Keyed by the
// EFFECTIVE owner so an accountant writes into the owner's namespace (matching
// the controller's list/download/delete/prune scoping).
const storage = multer.diskStorage({
  destination(req, file, cb) {
    const dir = path.join(env.BACKUP_DIR, String(effectiveOwnerId(req.user)));
    fs.mkdir(dir, { recursive: true }, (err) => cb(err, dir));
  },
  filename(req, file, cb) {
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    cb(null, `${stamp}-moldati.db`);
  },
});

const uploadMw = multer({
  storage,
  limits: { fileSize: 200 * 1024 * 1024 }, // 200 MB safety cap
});

router.post('/', uploadMw.single('file'), upload);
router.get('/', list);
router.get('/:id/download', download);
router.delete('/:id', remove);

module.exports = router;
