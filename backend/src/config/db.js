'use strict';

const mongoose = require('mongoose');
const env = require('./env');

let memoryServer = null;

/**
 * Connect to MongoDB. When USE_MEMORY_DB=true, an in-process
 * mongodb-memory-server instance is started and used (no external Mongo
 * required). Otherwise a real MongoDB at MONGO_URI is used.
 */
async function connectDb() {
  mongoose.set('strictQuery', true);

  let uri = env.MONGO_URI;

  if (env.USE_MEMORY_DB) {
    // Lazy require so production deployments need not install the dev dep.
    // eslint-disable-next-line global-require
    const { MongoMemoryServer } = require('mongodb-memory-server');
    memoryServer = await MongoMemoryServer.create();
    uri = memoryServer.getUri();
    console.log('[db] using in-memory MongoDB');
  }

  await mongoose.connect(uri);
  console.log(`[db] connected (${env.USE_MEMORY_DB ? 'memory' : uri})`);

  return mongoose.connection;
}

async function disconnectDb() {
  await mongoose.disconnect();
  if (memoryServer) {
    await memoryServer.stop();
    memoryServer = null;
  }
}

module.exports = { connectDb, disconnectDb };
