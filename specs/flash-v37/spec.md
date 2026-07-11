# Flash v37 — Spec (app-side only; NO backend changes; fully backward-compatible)

Production constraint (owner): no backend/schema/API/data changes; no behavior
changes beyond preventing the incorrect scenarios below.

## Item 1+2 — amps edit shows a Circuit error / "works offline, fails online"
Root cause (confirmed in code): `_validateSubscriber` re-checks name uniqueness
and circuit occupancy on EVERY edit. A pre-existing data duplicate (e.g. a
deleted-then-recreated subscriber sharing the circuit — the documented
production incident) makes `isCircuitTaken` fire even though the user only
changed the AMPS, surfacing a misleading `circuit_in_use` snackbar. It looks
"online-only" because the duplicate row arrives via mirror pull; a device that
never pulled it edits fine offline.
**Fix**: on an EDIT, validate name uniqueness ONLY when the name changed and
circuit occupancy ONLY when the circuit changed (new subscribers keep both
checks). Amps edits then never trip circuit/name errors; the amps message
(`amps_invalid`) still fires for a bad amps value.

## Item 3 — settled subscribers/receipts must be locked
- Receipt refund of a settled receipt: **already blocked** (v31 lock —
  `isLockedBySettlement`) — verified, no change.
- NEW: block BILLING-RELEVANT subscriber edits (amps or category changed) when
  the subscriber has a VALID receipt for the CURRENT global month inside an
  ACTIVE (pending/approved) settlement → `edit_blocked_settled` message.
  Name/phone/board fixes stay allowed (harmless to settled figures).

## Item 4 — Net Revenue vs settlement totals (explanation only, no code)
Reports' صافي الربح = receipts-collected − expenses (billing month). The
settlements screen's صافي الإيرادات = APPROVED settlements − expenses (request
month). They differ by exactly (a) cash collected but not yet settled (the
الرصيد غير المسوّى card) and (b) request-date vs billing-month timing. This is
recognition-basis, not an error; settling before month-close closes the gap.

## Item 5 — negative wallet can never appear
Scenarios: (a) settled receipt deleted → blocked since v35; (b) settled receipt
reversed → blocked since v31; (c) TRANSIENT: the local fallback wallet counts
only the PULLED (month-scoped) receipts against ALL-TIME settlements → shows a
negative until the server figure/pull catches up (the owner's −14,000 → 0
screenshots); (d) historical data damaged before the guards (the −520,000 row).
**Fix**: clamp the DISPLAYED cash/card balances at 0 in SettlementController
(server + local paths); the raw collected/settled sub-figures stay visible.
Requesting a settlement already requires balance > 0.

## Verification
analyze 0/0; flutter test green; adversarial review; change table; Flash API
default; release APK; commit+push.
