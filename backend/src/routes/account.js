'use strict';

const express = require('express');
const { requireAuth } = require('../middleware/auth');
const { requireFeature } = require('../middleware/requireFeature');
const ctrl = require('../controllers/accountController');

const router = express.Router();

// Owner self-service: any authenticated role, always scoped to the JWT user.
router.use(requireAuth);
// The owner self-service panel is a per-plan capability; 403 when disabled.
router.use(requireFeature('ownerPanel'));

// Read-only view of the caller's own synced mirror (?entity=subscribers).
router.get('/data', ctrl.getMyData);
// Per-entity counts of the caller's non-deleted mirrored rows.
router.get('/stats', ctrl.getMyStats);
// The caller's most recently uploaded records (owner home "latest uploads").
router.get('/recent', ctrl.getMyRecent);

module.exports = router;
