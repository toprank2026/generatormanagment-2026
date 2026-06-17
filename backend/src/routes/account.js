'use strict';

const express = require('express');
const { requireAuth } = require('../middleware/auth');
const { requireFeature } = require('../middleware/requireFeature');
const { HttpError } = require('../middleware/error');
const ctrl = require('../controllers/accountController');
const accountantCtrl = require('../controllers/accountantAccountController');

const router = express.Router();

// Owner self-service: any authenticated role, always scoped to the JWT user.
router.use(requireAuth);

/** Only an owner or admin may manage accountant sub-accounts. */
function requireOwnerOrAdmin(req, res, next) {
  const role = req.user && req.user.role;
  if (role !== 'owner' && role !== 'admin') {
    return next(new HttpError(403, 'Owner or admin access required', 'FORBIDDEN'));
  }
  return next();
}

// Accountant sub-account management (owner|admin). Registered BEFORE the
// ownerPanel feature gate so it does not depend on that capability flag.
router.post('/accountants', requireOwnerOrAdmin, accountantCtrl.createAccountant);
router.get('/accountants', requireOwnerOrAdmin, accountantCtrl.listAccountants);
router.put('/accountants/:id', requireOwnerOrAdmin, accountantCtrl.updateAccountant);
router.delete('/accountants/:id', requireOwnerOrAdmin, accountantCtrl.deleteAccountant);

// The owner self-service panel is a per-plan capability; 403 when disabled.
router.use(requireFeature('ownerPanel'));

// Read-only view of the caller's own synced mirror (?entity=subscribers).
router.get('/data', ctrl.getMyData);
// Per-entity counts of the caller's non-deleted mirrored rows.
router.get('/stats', ctrl.getMyStats);
// The caller's most recently uploaded records (owner home "latest uploads").
router.get('/recent', ctrl.getMyRecent);

module.exports = router;
