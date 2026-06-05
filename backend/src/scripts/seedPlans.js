'use strict';

/**
 * Manual seeder: `npm run seed`.
 * Connects to the DB, ensures default plans + bootstrap admin, then exits.
 *
 * NOTE: with USE_MEMORY_DB=true this seeds an ephemeral in-memory database that
 * disappears when the process ends — useful only as a sanity check. To persist,
 * set USE_MEMORY_DB=false and point MONGO_URI at a real MongoDB.
 */

const { connectDb, disconnectDb } = require('../config/db');
const { runSeed } = require('../bootstrap/seed');

(async () => {
  try {
    await connectDb();
    await runSeed();
    console.log('[seed] done');
    await disconnectDb();
    process.exit(0);
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error('[seed] failed', err);
    process.exit(1);
  }
})();
