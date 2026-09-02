'use strict';

/**
 * v44 — the mirror-side twin of the app's frozen-amps + status rules
 * (DbHelper.effectiveAmps / CorrectionRepository.dueDeltaFor). Lives in its
 * own module because BOTH accountController and adminController need it and a
 * controller-to-controller require is circular (the export was undefined at
 * load time — the v44 review's carry-forward tests caught it).
 *
 *   ampsFor(sid, liveAmps): the amps IN FORCE for `month` — the `old_amps` of
 *     the EARLIEST decided correction (status approved / refund_due /
 *     completed / carried_forward, old_amps set) whose month >= `month`,
 *     ordered by (month, requested_at, id) exactly like DbHelper.effectiveAmps;
 *     else the live value. With `month` null, always the live value.
 *   statusOf(correctionId): the correction's current status ('' if unknown),
 *     so a ledger row can be counted only while its correction is in the
 *     terminal state it represents (STATUS-AWARE folds — a double-close race
 *     can never settle a credit twice).
 */
const FROZEN_STATUSES = new Set(['approved', 'refund_due', 'completed', 'carried_forward']);

function buildFrozenAmps(correctionRows, month) {
  const statusById = new Map();
  const bySubscriber = new Map();
  for (const r of correctionRows || []) {
    const d = r.data || {};
    const id = d.id != null ? String(d.id) : String(r.localId);
    const st = String(d.status || 'pending');
    statusById.set(id, st);
    if (month == null) continue;
    if (!FROZEN_STATUSES.has(st)) continue;
    if (d.old_amps == null || d.old_amps === '') continue;
    const m = String(d.month || '');
    if (!m || m < month) continue;
    const sid = d.subscriber_id != null ? String(d.subscriber_id) : '';
    if (!sid) continue;
    const list = bySubscriber.get(sid) || [];
    list.push({ month: m, at: String(d.requested_at || ''), id, oldAmps: Number(d.old_amps) });
    bySubscriber.set(sid, list);
  }
  const earliest = new Map();
  for (const [sid, list] of bySubscriber) {
    list.sort((a, b) =>
      a.month < b.month ? -1 : a.month > b.month ? 1
        : a.at < b.at ? -1 : a.at > b.at ? 1
          : a.id < b.id ? -1 : a.id > b.id ? 1 : 0
    );
    earliest.set(sid, list[0].oldAmps);
  }
  return {
    ampsFor(sid, liveAmps) {
      const v = earliest.get(sid != null ? String(sid) : '');
      return Number.isFinite(v) ? v : liveAmps;
    },
    statusOf(correctionId) {
      return statusById.get(correctionId != null ? String(correctionId) : '') || '';
    },
  };
}

module.exports = { buildFrozenAmps, FROZEN_STATUSES };
