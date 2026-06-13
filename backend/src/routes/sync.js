'use strict';

const express = require('express');
const { requireAuth } = require('../middleware/auth');
const { requireFeature } = require('../middleware/requireFeature');
const ctrl = require('../controllers/syncController');

const router = express.Router();

// Every sync route requires a valid JWT (the owner's account).
router.use(requireAuth);
// Online data sync is a per-plan capability; reject when the active plan lacks it.
router.use(requireFeature('sync'));

// Device → server mirror.
router.post('/push', ctrl.push);
// Server → device (new-device restore).
router.get('/pull', ctrl.pull);

module.exports = router;
