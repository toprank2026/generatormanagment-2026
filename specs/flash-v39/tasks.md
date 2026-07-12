# Flash v39 — tasks

## Flutter data layer
- [x] T1 `SettlementRepository.listAllForOwner`: strict month clause (drop the
      `OR status='pending'` bypass); comment records the v39 owner decision.
- [x] T2 `SettlementRepository.history`: optional `month` param
      (`requested_at LIKE 'YYYY-MM%'`).
- [x] T3 `SettlementRepository.pendingCount`: optional `month` param.
- [x] T4 NEW `SettlementRepository.monthUnsettled(accountantId, month)` =
      max(0, valid receipts cash of month − approved cash/card settlements
      requested in month).

## Flutter UI/controller
- [x] T5 Admin settlements screen: 3 summary cards (total_settlements /
      net_expenses / net_profit); remove the pending-balance card + state.
- [x] T6 Admin screen: per-accountant breakdown uses monthUnsettled + month-scoped
      last-settlement chip; banner uses pendingCount(month).
- [x] T7 `SettlementController`: history scoped to the global pricing month
      (MonthController) + `_monthFollow` ever-worker (disposed in onClose).
- [x] T8 Translations: `net_expenses`, `time_am`, `time_pm` in BOTH maps.

## Item 6 — 12-hour display (display-only)
- [x] T9 `lib/utils/date_fmt.dart` (fmtDateTime12 / fmtTime12).
- [x] T10 Convert: admin settlements screen ×2, my wallet, backup, sync,
      payments, dashboard last-pull, bluetooth + USB receipt prints (ص/م).
- [x] T11 Owner panel `fmtDate`: `hour12:true`.

## Backend + owner panel
- [x] T12 `adminController.listUserData`: month param now also filters
      `entity==='settlements'` via `data.requested_at` prefix regex (additive).
- [x] T13 Panel `viewMySettlements`: pass `month` to fetchAllSettlements
      (server-side filter); `inMonth` safety-net switched to UTC prefix;
      cards relabeled إجمالي التسويات / صافي المصروفات / صافي الربح.

## Verification
- [x] T14 New `test/v39_settlement_month_test.dart` (history month filter, strict
      listAllForOwner, pendingCount month, monthUnsettled derivation + clamp).
- [x] T15 Backend test: settlements month filter on the data endpoint.
- [x] T16 flutter analyze clean; full Flutter + backend suites green.
- [x] T17 Adversarial review fleet on the diff; fix confirmed findings.
- [x] T18 MILESTONES.md entry; change table; Flash-API release APK; commit+push.
