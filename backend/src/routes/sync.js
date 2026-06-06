'use strict';

const express = require('express');
const { requireAuth } = require('../middleware/auth');
const ctrl = require('../controllers/syncController');

const router = express.Router();

// Every sync route requires a valid JWT (the owner's account).
router.use(requireAuth);

// Device → server mirror.
router.post('/push', ctrl.push);
// Server → device (new-device restore).
router.get('/pull', ctrl.pull);

module.exports = router;
