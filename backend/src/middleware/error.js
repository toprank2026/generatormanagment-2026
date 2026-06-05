'use strict';

/**
 * A small helper to throw HTTP errors with a status + optional machine code.
 * Usage: throw new HttpError(403, 'Account blocked', 'BLOCKED');
 */
class HttpError extends Error {
  constructor(status, message, code) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

// 404 for unmatched routes (must be mounted after all routes).
function notFound(req, res) {
  res.status(404).json({ message: `Not found: ${req.method} ${req.originalUrl}` });
}

// Central error middleware. Always emits { message, code? } per the contract.
// eslint-disable-next-line no-unused-vars
function errorHandler(err, req, res, next) {
  let status = err.status || err.statusCode || 500;
  let message = err.message || 'Internal server error';
  let code = err.code;

  // Mongoose validation / cast errors -> 400.
  if (err.name === 'ValidationError') {
    status = 400;
    message = Object.values(err.errors || {})
      .map((e) => e.message)
      .join(', ') || message;
  } else if (err.name === 'CastError') {
    status = 400;
    message = `Invalid ${err.path}`;
  } else if (err.code === 11000) {
    // Duplicate key (e.g. username / plan code).
    status = 409;
    const field = Object.keys(err.keyValue || {})[0] || 'field';
    message = `${field} already exists`;
    code = 'DUPLICATE';
  }

  if (status >= 500) {
    // Log unexpected errors server-side.
    // eslint-disable-next-line no-console
    console.error('[error]', err);
  }

  const payload = { message };
  if (code) payload.code = code;
  res.status(status).json(payload);
}

module.exports = { HttpError, notFound, errorHandler };
