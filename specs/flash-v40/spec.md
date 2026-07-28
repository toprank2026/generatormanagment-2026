# Flash v40 — Tariff Month as the accounting reference (future-month billing)

## Owner request
Collecting a FUTURE month's subscriptions (e.g. tariff month = August, today =
2026-07-28) must book every financial figure into the TARIFF month, never the
transaction/upload date. Transaction timestamps stay untouched (audit history).
Fully backward compatible: no historical-data edits, no breaking migrations,
existing deployments keep working; legacy rows keep legacy behavior.
(The spec said "Laravel backend" — the actual backend is Node/Express; adapted.)

## What the mapping fleet proved (5 read-only agents)
**Already tariff-month-correct — NO changes needed:**
- Receipts are stamped `month = MonthController.selectedMonth` at collection
  (billing_controller.dart:326); `issued_at` is display/ordering/lock-only.
- EVERY receipt-based figure keys on the `receipts.month` column: paid/unpaid +
  remaining derivation, dashboard, reports, payments list, subscriber rows/due,
  boards counts, collected/discount sums, backend `buildDashboard`
  (`data.month` equality), sync pull (`receiptsMonth` → `data.month`), panel
  reports + statements (statement shows `d.month` beside the historical date).
- Monthly prices: keyed by month; future-month pricing already works.
- Expenses: date-prefix bucket, but v36 `defaultExpenseDate` lands new expenses
  INSIDE the global month (Aug 1 when collecting for August in July).
- Wallet balances + `hasPending` + the reversal/edit locks: ALL-TIME /
  timestamp-based BY DESIGN — an August receipt collected July 28 is correctly
  locked by a July 29 settlement request (the wallet it drained is all-time).
  Must NOT be month-scoped (would reopen the negative-wallet incident).
- Future month selection: the pricing screen picker and the panel month
  chevrons can both reach future months already.

**THE GAP — settlements bucket by the request TIMESTAMP (requested_at prefix):**
- `settlements` has no month column; `requestSettlement` stamps only UTC now.
- All five v39 month-scoped queries (listAllForOwner, approvedSumForMonth,
  pendingCount, monthUnsettled's settled side, history) + backend
  `listUserData` settlements month filter + panel `inMonth()` use the
  requested_at prefix. So an August-money settlement requested July 28 lands in
  JULY: Total Settlement card, per-accountant approved, Net Profit, histories,
  pending banner — while `monthUnsettled`'s collected side (receipts.month)
  says August still holds unsettled cash. Exactly the reported defect.

## Design
1. **New nullable `settlements.month` TEXT column** — SQLite v13→v14 additive
   migration (idempotent `_addColumn` + inline `_onCreate` DDL). Stamped at
   request time from the global tariff month. Rides to the Mixed mirror
   automatically (whole-row push); backend decide() `$set`s only specific
   fields so the stamp survives approval; Flutter decide() updates via
   `toMap()` which now carries it.
2. **Effective settlement month** = `COALESCE(month, substr(requested_at,1,7))`
   — every month-scoped settlement query switches to equality on this
   expression. Legacy rows (month NULL) keep EXACTLY their current bucketing;
   new rows use the tariff month. No data rewritten, ever.
3. **Backend** settlements month filter becomes month-first with legacy
   fallback: `$or: [{data.month: M}, {data.month: null, data.requested_at:
   ^M}]`, composed under `$and` (never clobbers the q-search `$or`).
4. **Panel** `inMonth()` prefers `d.month`, falls back to the requested_at
   prefix; admin synced-data grid shows the new month column.
5. **Sync compatibility** (same pattern as v12 `method` / v13 `payment_note`):
   new app pulling legacy rows → month NULL → fallback ✓. Old app pulling a
   new stamped row → **the WHOLE pull fails** (one transaction — no entity
   updates on that device, every retry, until the APK is updated; push still
   works and the server mirror is never harmed). Review-verified blast radius:
   an old-APK device must NOT switch branches during the rollout (push→clear→
   pull would leave it empty until updated). ROLLOUT RULE: update every device
   of an account together, BEFORE the first settlement is requested on v40.
   Precedented trade-off of the whole-row mirror; the sync engine itself is
   untouched (standing rule). Optional future hardening: column-filtered /
   per-record-isolated pull applies, which would close this window for all
   future schema additions.

## Acceptance arithmetic (asserted in tests)
Tariff month 2026-08, today 2026-07-28: collect 15,000 → receipt
{month:'2026-08', issued_at:'2026-07-28…'}; settle → request
{month:'2026-08', requested_at:'2026-07-29…'}, approve:
- Total Settlement AUG = 15,000; JUL = 0 (was: inverted).
- monthUnsettled AUG = 15,000−15,000 = 0; JUL = 0−0 = 0 (was: AUG phantom 15k).
- Histories/pending banner show the request under AUG.
- July's receipt-side reports unchanged; lock still holds (timestamps).
- Mixed DB: a legacy (unstamped) settlement keeps bucketing by requested_at.

## Out of scope / explicitly unchanged
Receipts/prices/expenses bucketing, wallet endpoints + balances, locks,
`hasPending`, sync engine (push/pull/outbox/triggers), decide() flows,
statements/public endpoints, historical rows.
