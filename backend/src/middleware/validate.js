'use strict';

const { validationResult } = require('express-validator');

/**
 * Runs after a chain of express-validator checks. If any failed, responds
 * 400 with the contract error shape using the first message.
 */
function validate(req, res, next) {
  const result = validationResult(req);
  if (result.isEmpty()) return next();
  const first = result.array({ onlyFirstError: true })[0];
  return res.status(400).json({
    message: first ? first.msg : 'Validation failed',
    code: 'VALIDATION',
  });
}

module.exports = { validate };
