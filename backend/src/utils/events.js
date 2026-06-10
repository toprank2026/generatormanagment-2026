'use strict';

const { EventEmitter } = require('events');

/**
 * Process-wide event bus for admin-facing real-time events (SSE).
 *
 * A single module-level EventEmitter that survives for the lifetime of the Node
 * process. Producers (e.g. authController.register) emit events; the SSE handler
 * (controllers/eventsController) subscribes and streams them to connected admin
 * panels. Events currently emitted:
 *   - 'user_registered' : { id, name, username, phone, generatorName, createdAt }
 */
const adminEvents = new EventEmitter();
// Many admin browsers may be connected at once; lift the default 10-listener cap.
adminEvents.setMaxListeners(0);

module.exports = { adminEvents };
