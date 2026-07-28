# Flash v40 — tasks

## Schema + model + stamping
- [ ] T1 DbHelper: `version: 14`; `month TEXT` in the `_onCreate` settlements
      DDL; `if (oldVersion < 14) _addColumn(settlements, month, TEXT)`.
- [ ] T2 Settlement model: nullable `month` field (constructor/toMap/fromMap).
- [ ] T3 `requestSettlement`: stamp `month: MonthController.selectedMonth`.

## Effective-month queries (COALESCE(month, substr(requested_at,1,7)))
- [ ] T4 `listAllForOwner` month clause.
- [ ] T5 `approvedSumForMonth`.
- [ ] T6 `pendingCount(month:)`.
- [ ] T7 `monthUnsettled` settled side.
- [ ] T8 `history(month:)`.

## Backend + panel
- [ ] T9 `adminController.listUserData` settlements month filter → month-first
      with requested_at fallback, composed under `$and`.
- [ ] T10 Panel `viewMySettlements.inMonth()` prefers `d.month`.
- [ ] T11 Panel admin synced-data grid (SYNC_COLUMNS.settlements): show month.

## Verification
- [ ] T12 Flutter: extend v39 test with the v40 acceptance scenario (stamped
      Aug settlement requested in July → buckets Aug everywhere; monthUnsettled
      Aug/Jul both 0 after approval; mixed legacy row unchanged; cross-month
      lock pin: July-28 receipt locked by July-29 request).
- [ ] T13 Backend: extend settlements.test.mjs (data.month row buckets by
      month; legacy row falls back to requested_at; composition with relField).
- [ ] T14 Suites green (Flutter + backend), analyze clean; CLAUDE.md schema
      gotcha updated to v14.
- [ ] T15 Adversarial review fleet on the uncommitted diff; fix confirmed.
- [ ] T16 MILESTONES entry; change table; Flash-API release APK; commit+push.
