'use strict';

const express = require('express');
const ctrl = require('../controllers/publicController');

const router = express.Router();

// PUBLIC — no requireAuth. A scanned receipt QR is viewable without a login.
router.get('/receipt/:uuid', ctrl.getPublicReceipt);

module.exports = router;
