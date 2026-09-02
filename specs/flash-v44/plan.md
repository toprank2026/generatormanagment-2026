# Flash v44 — plan

## Approach

Extend, never restructure. Every rule lands as a fold into an expression that already
exists, so an account with no corrections is byte-identical to v43.1:

1. **Money rule** — narrow `adjustmentTotal` (and the backend twins) to `refund_return`
   only. The increase stops being cash. No schema, no new endpoint on the sync path.
2. **Due rule** — one new shared SQL expression (`correctionDueDelta`) beside the existing
   `effectiveAmps`, dropped into the same six sites; one Dart twin for `getDueAmount`.
   Paid/unpaid stays DERIVED, so the "customer becomes unpaid" behaviour is automatic.
3. **Carry-forward** — a second terminal close for a decrease, reusing the ledger with
   `month` = target month and a new TEXT status value. Guarded transition first, then the
   append, deterministic id (same shape as approve/refund-paid on both app and backend).
4. **Visibility** — a Corrections tab on the Subscribers screen (swap the body before the
   existing `GetBuilder`, never touch the subscriber list), a settlement badge in the
   panel, `settlementStatus` on the list endpoint.
5. **UI** — both amber notices become one collapsible shell.

## Process

Map (already known from v43) → implement directly (coupled money code) → tests rewritten
to the new semantics + new tests → 10-dimension adversarial review with 3-lens refutation
→ fix confirmed findings → APK → commit → push → table.

## Risks called out

- **Whitelist trap** (`.all` / `CORRECTION_STATUSES`) — hit during implementation; now a
  `CLAUDE.md` gotcha with a regression test (carry-forward status round-trips).
- **Old clients** — a v43 APK normalises `credit_applied` → `correction_increase`; the
  review's sync dimension is asked to judge whether that degradation is acceptable.
- **Test fixtures** with far-future `updated_at` beat re-pushes under last-edit-wins; the
  backend helper prices the month off mirrored amps instead.
