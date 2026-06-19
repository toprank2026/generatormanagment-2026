'use strict';

const fs = require('fs');
const path = require('path');
const Backup = require('../models/Backup');
const env = require('../config/env');
const asyncHandler = require('../utils/asyncHandler');
const { serializeBackup } = require('../utils/serialize');
const { effectiveOwnerId } = require('../utils/effectiveOwner');
const { HttpError } = require('../middleware/error');

/** Absolute directory holding a user's backups. */
function userDir(userId) {
  return path.join(env.BACKUP_DIR, String(userId));
}

/** Resolve a backup file path, guarding against path traversal in `filename`
 *  (defense-in-depth in case a Backup record is ever tampered with). */
function backupFilePath(userId, filename) {
  const base = userDir(userId);
  const resolved = path.normalize(path.join(base, filename));
  if (resolved !== base && !resolved.startsWith(base + path.sep)) {
    throw new HttpError(400, 'Invalid backup file path', 'BACKUP_BAD_PATH');
  }
  return resolved;
}

/** Remove all but the newest MAX_BACKUPS for a user (file + db record). */
async function pruneOldBackups(userId) {
  const keep = env.MAX_BACKUPS;
  const all = await Backup.find({ user: userId }).sort({ createdAt: -1 });
  if (all.length <= keep) return;
  const stale = all.slice(keep);
  for (const b of stale) {
    const fp = backupFilePath(userId, b.filename);
    try {
      if (fs.existsSync(fp)) fs.unlinkSync(fp);
    } catch (e) {
      // eslint-disable-next-line no-console
      console.warn('[backup] failed to delete stale file', fp, e.message);
    }
    // eslint-disable-next-line no-await-in-loop
    await b.deleteOne();
  }
}

/** POST /api/backup (multipart) — file already written to disk by multer. */
const upload = asyncHandler(async (req, res) => {
  if (!req.file) {
    throw new HttpError(400, 'No file uploaded (expected field "file")', 'NO_FILE');
  }

  // Scope to the effective owner so an accountant operates on the OWNER's backup
  // namespace (matching sync/account effective-owner scoping); owners/admins use
  // their own id. NOTE: multer writes the file into env.BACKUP_DIR/<owner> via
  // the storage destination (also effectiveOwner-keyed — see routes/backup.js).
  const ownerId = effectiveOwnerId(req.user);
  const backup = await Backup.create({
    user: ownerId,
    filename: req.file.filename,
    size: req.file.size,
    note: req.body.note || null,
    appVersion: req.body.appVersion || null,
  });

  await pruneOldBackups(ownerId);

  res.status(201).json({ backup: serializeBackup(backup) });
});

/** GET /api/backup (auth) */
const list = asyncHandler(async (req, res) => {
  const backups = await Backup.find({ user: effectiveOwnerId(req.user) }).sort({ createdAt: -1 });
  res.status(200).json({ backups: backups.map(serializeBackup) });
});

/** GET /api/backup/:id/download (auth) — streams raw bytes. */
const download = asyncHandler(async (req, res) => {
  const ownerId = effectiveOwnerId(req.user);
  const backup = await Backup.findOne({ _id: req.params.id, user: ownerId });
  if (!backup) {
    throw new HttpError(404, 'Backup not found', 'BACKUP_NOT_FOUND');
  }

  const fp = backupFilePath(ownerId, backup.filename);
  if (!fs.existsSync(fp)) {
    throw new HttpError(404, 'Backup file missing on server', 'BACKUP_FILE_MISSING');
  }

  res.setHeader('Content-Type', 'application/octet-stream');
  res.setHeader('Content-Disposition', `attachment; filename="${backup.filename}"`);
  res.setHeader('Content-Length', backup.size);

  const stream = fs.createReadStream(fp);
  stream.on('error', (err) => {
    if (!res.headersSent) res.status(500);
    res.end();
    // eslint-disable-next-line no-console
    console.error('[backup] stream error', err);
  });
  stream.pipe(res);
});

/** DELETE /api/backup/:id (auth) */
const remove = asyncHandler(async (req, res) => {
  const ownerId = effectiveOwnerId(req.user);
  const backup = await Backup.findOne({ _id: req.params.id, user: ownerId });
  if (!backup) {
    throw new HttpError(404, 'Backup not found', 'BACKUP_NOT_FOUND');
  }

  const fp = backupFilePath(ownerId, backup.filename);
  try {
    if (fs.existsSync(fp)) fs.unlinkSync(fp);
  } catch (e) {
    // eslint-disable-next-line no-console
    console.warn('[backup] failed to delete file', fp, e.message);
  }
  await backup.deleteOne();

  res.status(200).json({ ok: true });
});

module.exports = { upload, list, download, remove, userDir };
