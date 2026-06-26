'use strict';

const express = require('express');
const ctrl = require('../controllers/publicController');

const router = express.Router();

// PUBLIC — no requireAuth. A scanned receipt QR is viewable without a login.
router.get('/receipt/:uuid', ctrl.getPublicReceipt);
// PUBLIC — the same subscriber's other invoices (history) for a scanned receipt.
router.get('/receipt/:uuid/history', ctrl.getPublicReceiptHistory);
// PUBLIC — landing-page content (enabled banners + enabled promo video).
router.get('/landing', ctrl.getPublicLanding);

module.exports = router;
