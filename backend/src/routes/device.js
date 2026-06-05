'use strict';

const express = require('express');
const { body } = require('express-validator');
const { list, bind, unbind } = require('../controllers/deviceController');
const { validate } = require('../middleware/validate');
const { requireAuth } = require('../middleware/auth');

const router = express.Router();

router.use(requireAuth);

router.get('/', list);
router.post(
  '/bind',
  [
    body('device').isObject().withMessage('device is required'),
    body('device.deviceId').isString().trim().notEmpty().withMessage('device.deviceId is required'),
  ],
  validate,
  bind
);
router.delete('/:deviceId', unbind);

module.exports = router;
