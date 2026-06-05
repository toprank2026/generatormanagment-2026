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

const env = {
  PORT: int(process.env.PORT, 4000),

  USE_MEMORY_DB: bool(process.env.USE_MEMORY_DB, true),
  MONGO_URI: process.env.MONGO_URI || 'mongodb://127.0.0.1:27017/moldati',

  JWT_SECRET: process.env.JWT_SECRET || 'change-me-in-production-please',
  JWT_EXPIRES: process.env.JWT_EXPIRES || '30d',

  ADMIN_USERNAME: process.env.ADMIN_USERNAME || 'admin',
  ADMIN_PASSWORD: process.env.ADMIN_PASSWORD || 'admin123',

  // Resolve the backup dir to an absolute path rooted at the backend folder.
  BACKUP_DIR: path.isAbsolute(BACKUP_DIR_RAW)
    ? BACKUP_DIR_RAW
    : path.resolve(__dirname, '..', '..', BACKUP_DIR_RAW),

  MAX_BACKUPS: int(process.env.MAX_BACKUPS, 10),

  NODE_ENV: process.env.NODE_ENV || 'development',
};

module.exports = env;
