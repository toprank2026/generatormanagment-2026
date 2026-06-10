'use strict';

const { adminEvents } = require('../utils/events');

/**
 * Server-Sent Events stream for the admin panel.
 *
 * Holds the connection open and pushes admin events as they happen:
 *   - 'user_registered' -> `event: user_registered\ndata: <json>\n\n`
 * A heartbeat comment is sent every ~25s to keep proxies / the browser from
 * dropping an idle connection. All listeners + the heartbeat timer are cleaned
 * up when the client disconnects.
 *
 * Auth is enforced by the route (admin via ?token=) before this runs.
 */
function streamAdminEvents(req, res) {
  res.set({
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });
  // Disable proxy buffering (e.g. nginx) so events flush immediately.
  res.set('X-Accel-Buffering', 'no');
  if (typeof res.flushHeaders === 'function') res.flushHeaders();

  // Initial comment so the client knows the stream is open.
  res.write(': connected\n\n');

  const onUserRegistered = (payload) => {
    res.write('event: user_registered\n');
    res.write(`data: ${JSON.stringify(payload)}\n\n`);
  };

  adminEvents.on('user_registered', onUserRegistered);

  // Heartbeat keeps the connection alive through idle periods.
  const heartbeat = setInterval(() => {
    res.write(':hb\n\n');
  }, 25000);

  req.on('close', () => {
    clearInterval(heartbeat);
    adminEvents.removeListener('user_registered', onUserRegistered);
    res.end();
  });
}

module.exports = { streamAdminEvents };
