'use strict';

const path = require('path');
const dotenv = require('dotenv');

// Load .env from the backend root (one level up from src/config).
dotenv.config({ path: path.resolve(__dirname, '..', '..', '.env') });

function bool(value, fallback) {
  if (value === undefined || value === null || value === '') return fallback;
  return String(value).toLowerCase() === 'true';
}

function int(value, fallback) {
  const n = parseInt(value, 10);
  return Number.isFinite(n) ? n : fallback;
}

const BACKUP_DIR_RAW = process.env.BACKUP_DIR || './backups';
// Directory holding admin-uploaded landing assets (banner images). Served
// publicly at /uploads (see server.js). Resolved to an absolute path below.
const UPLOADS_DIR_RAW = process.env.UPLOADS_DIR || './uploads';

// Insecure defaults that MUST NOT survive into production. The dev defaults are
// kept (so local/test runs work with zero config), but `validateSecrets()` —
// called at boot — fails fast in production if these are still in place.
const DEFAULT_JWT_SECRET = 'change-me-in-production-please';
const DEFAULT_ADMIN_PASSWORD = 'admin123';

const env = {
  PORT: int(process.env.PORT, 4000),

  USE_MEMORY_DB: bool(process.env.USE_MEMORY_DB, true),
  MONGO_URI: process.env.MONGO_URI || 'mongodb://127.0.0.1:27017/moldati',

  JWT_SECRET: process.env.JWT_SECRET || DEFAULT_JWT_SECRET,
  JWT_EXPIRES: process.env.JWT_EXPIRES || '30d',

  ADMIN_USERNAME: process.env.ADMIN_USERNAME || 'admin',
  ADMIN_PASSWORD: process.env.ADMIN_PASSWORD || DEFAULT_ADMIN_PASSWORD,

  // Resolve the backup dir to an absolute path rooted at the backend folder.
  BACKUP_DIR: path.isAbsolute(BACKUP_DIR_RAW)
    ? BACKUP_DIR_RAW
    : path.resolve(__dirname, '..', '..', BACKUP_DIR_RAW),

  // Resolve the uploads dir to an absolute path rooted at the backend folder.
  UPLOADS_DIR: path.isAbsolute(UPLOADS_DIR_RAW)
    ? UPLOADS_DIR_RAW
    : path.resolve(__dirname, '..', '..', UPLOADS_DIR_RAW),

  MAX_BACKUPS: int(process.env.MAX_BACKUPS, 10),

  NODE_ENV: process.env.NODE_ENV || 'development',
};

/**
 * Validate security-critical secrets.
 *
 * In production (`NODE_ENV==='production'`) this FAILS FAST: it throws when
 * JWT_SECRET is unset/blank or still the placeholder, and when ADMIN_PASSWORD is
 * unset/blank or still the well-known default. Throwing here (called from the
 * server's `start()`) prevents the process from ever serving a usable but
 * insecure token / bootstrap admin.
 *
 * Outside production the defaults are allowed but a warning is logged so the gap
 * is visible. Returns the list of problems found (empty when all good); throws
 * the same list joined when in production and `throwOnFail` (default) is set.
 *
 * @param {boolean} [throwOnFail=true]
 * @returns {string[]} problems detected
 */
function validateSecrets(throwOnFail = true) {
  // Read NODE_ENV LIVE (not the cached env.NODE_ENV snapshot) so a process that
  // sets NODE_ENV after require — and the test suite — sees the current mode.
  const isProduction = (process.env.NODE_ENV || env.NODE_ENV) === 'production';
  const problems = [];

  const secret = process.env.JWT_SECRET || '';
  if (!secret.trim() || secret === DEFAULT_JWT_SECRET) {
    problems.push(
      'JWT_SECRET is missing or set to the insecure default — set a strong, unique JWT_SECRET.'
    );
  }

  const adminPw = process.env.ADMIN_PASSWORD || '';
  if (!adminPw.trim() || adminPw === DEFAULT_ADMIN_PASSWORD) {
    problems.push(
      'ADMIN_PASSWORD is missing or set to the insecure default (admin123) — set a strong ADMIN_PASSWORD.'
    );
  }

  if (problems.length === 0) return problems;

  if (isProduction) {
    if (throwOnFail) {
      throw new Error(
        '[env] Refusing to start in production with insecure secrets:\n  - ' +
          problems.join('\n  - ')
      );
    }
  } else {
    // eslint-disable-next-line no-console
    console.warn(
      '[env] WARNING: insecure secret defaults in use (allowed outside production):\n  - ' +
        problems.join('\n  - ')
    );
  }
  return problems;
}

module.exports = env;
module.exports.DEFAULT_JWT_SECRET = DEFAULT_JWT_SECRET;
module.exports.DEFAULT_ADMIN_PASSWORD = DEFAULT_ADMIN_PASSWORD;
module.exports.validateSecrets = validateSecrets;
