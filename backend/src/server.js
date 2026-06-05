'use strict';

const fs = require('fs');
const path = require('path');
const express = require('express');
const cors = require('cors');
const morgan = require('morgan');

const env = require('./config/env');
const { connectDb } = require('./config/db');
const { runSeed } = require('./bootstrap/seed');
const { notFound, errorHandler } = require('./middleware/error');

const authRoutes = require('./routes/auth');
const subscriptionRoutes = require('./routes/subscription');
const deviceRoutes = require('./routes/device');
const backupRoutes = require('./routes/backup');
const adminRoutes = require('./routes/admin');

function buildApp() {
  const app = express();

  app.use(cors());
  app.use(express.json({ limit: '2mb' }));
  app.use(express.urlencoded({ extended: true }));
  app.use(morgan(env.NODE_ENV === 'production' ? 'combined' : 'dev'));

  // Health check.
  app.get('/api/health', (req, res) => res.json({ ok: true, ts: new Date().toISOString() }));

  // API routes.
  app.use('/api/auth', authRoutes);
  app.use('/api/subscription', subscriptionRoutes);
  app.use('/api/device', deviceRoutes);
  app.use('/api/backup', backupRoutes);
  app.use('/api/admin', adminRoutes);

  // Static assets served to the app (images) and the admin SPA.
  const imagesDir = path.join(__dirname, '..', 'images');
  app.use('/app-images', express.static(imagesDir));

  // Admin single-page app at /admin (hash-routed; serve index.html for the
  // root and any sub-path so client routing works).
  const adminDir = path.join(__dirname, '..', 'public', 'admin');
  app.use('/admin', express.static(adminDir));
  app.get(/^\/admin(\/.*)?$/, (req, res, next) => {
    const indexFile = path.join(adminDir, 'index.html');
    if (fs.existsSync(indexFile)) return res.sendFile(indexFile);
    return next();
  });

  // 404 + central error handler (must be last).
  app.use(notFound);
  app.use(errorHandler);

  return app;
}

async function start() {
  // Ensure the backup directory exists before serving uploads.
  fs.mkdirSync(env.BACKUP_DIR, { recursive: true });

  await connectDb();
  await runSeed();

  const app = buildApp();
  app.listen(env.PORT, () => {
    // eslint-disable-next-line no-console
    console.log(`[server] Moldati accounts backend listening on http://localhost:${env.PORT}`);
    console.log(`[server] admin panel: http://localhost:${env.PORT}/admin`);
  });
}

// Only auto-start when run directly (allows tests to import buildApp).
if (require.main === module) {
  start().catch((err) => {
    // eslint-disable-next-line no-console
    console.error('[server] failed to start', err);
    process.exit(1);
  });
}

module.exports = { buildApp, start };
