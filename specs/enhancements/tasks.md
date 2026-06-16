# Tasks — Generator Management Enhancements (v6)

Checklist for [plan.md](plan.md). `(Rn)` = requirement. Group letters = disjoint file-ownership
units for the post-checkpoint fan-out.

## Phase 0 — Quick wins (no schema)
- [ ] (R2) `circuits_screen.dart`: make add/edit `onConfirm` `async`; `await addCircuit/updateCircuit`; then `Get.back()`; show error + keep open on failure.
- [ ] (R2) `boards_screen.dart`: same await-then-close for add/edit board dialogs.
- [ ] (R3) `boards_screen.dart`: `GridView.builder` → `physics: const AlwaysScrollableScrollPhysics()`; verify scroll to last board.
- [ ] (R3) `circuits_screen.dart`: audit list physics; align if needed.
- [ ] (R1) `core_controller.dart`: `itemsPerPage`/`boardsPerPage`/`circuitsPerPage` → ~100; keep `loadMore` active (infinite scroll).
- [ ] (R1) `expense_controller.dart`: `expensesPerPage` → ~100.
- [ ] (R1) verify `subscribers/boards/circuits/expenses` screens render full lists & scroll.

## Phase 1 — Schema v6 (foundation, single author, checkpoint commit)
- [ ] `db_helper.dart`: `version` 5 → 6.
- [ ] `_onUpgrade` add `if (oldVersion < 6)`:
  - [ ] `subscribers.category TEXT` + backfill `'standard'`.
  - [ ] reshape `monthly_prices` → PK `month|branch|category` + `category` col; backfill standard; drop/recreate sync triggers in correct order.
  - [ ] `receipts.category_snapshot TEXT`.
  - [ ] (R7) deactivate legacy circuit duplicates (keep latest `created_at`, others `status='inactive'`, log).
  - [ ] (R7) `BEFORE INSERT` + `BEFORE UPDATE` triggers on `subscribers`: ABORT if a *different* active subscriber in same `branch_id` holds `circuit_id`.
- [ ] `_onCreate`: same final shape (category cols, category_snapshot, exclusivity triggers) for fresh installs.
- [ ] `syncedTables`: confirm `monthly_prices` still `'id'`; no new synced tables.
- [ ] (test) v6 migration test in `test/branch_isolation_test.dart` (or new `test/v6_migration_test.dart`).

## Phase 2 — Models + repos  · Group A (data layer)
- [ ] (R4) `core_models.dart` `Subscriber`: add `category` (ctor/toMap/fromMap; default standard).
- [ ] (R4) `billing_models.dart` `MonthlyPrice`: add `category`; `buildId(month, branchId, category)`; `id` getter.
- [ ] (R3/R4) `billing_models.dart` `Receipt`: add `categorySnapshot` (toMap/fromMap `category_snapshot`).
- [ ] (R4) `MonthlyPriceRepository.getByMonth(month, {branchId, category})` + `getAllCategories(month, branchId)`.
- [ ] (R7) `SubscriberRepository.isCircuitTaken(circuitId, branchId, {exceptId})`.
- [ ] (R8) `SubscriberRepository.nameExists(name, branchId, {exceptId})` (COLLATE NOCASE + trim).
- [ ] (R7/R8) `SubscriberRepository.insert/update`: throw typed `ValidationException` on taken circuit / duplicate name.
- [ ] (R5) `CircuitRepository`/query helper: list circuits with their occupied flag for the picker.

## Phase 3 — Controllers  · Groups B (billing/dashboard/reports) + C (subscriber)
- [ ] (R4) `billing_controller.dart` `setPrice(category, price)`; `getDueAmount`/`collectPayment` use `subscriber.category`; stamp `categorySnapshot`.
- [ ] (R10) `billing_controller.dart` `setPrice`: after save, `if (Get.isRegistered<DashboardController>()) Get.find<DashboardController>().loadStats()`.
- [ ] (R11) `dashboard_controller.dart`: add `selectedMonth` + `changeMonth()`; `loadStats` uses it.
- [ ] (R6/R9/R11) `dashboard_controller.dart`: category-aware `expected`; expose `monthlyRevenue`, `monthlyRemaining`.
- [ ] (R6/R9/R11) `reports_controller.dart`: category-aware expected; metrics per selected month.
- [ ] (R4/R7/R8) `core_controller.dart` `addSubscriber/updateSubscriber`: stamp category; catch validation errors → snackbar.

## Phase 4 — UI  · Groups C (subscriber UI) + D (expenses/date) + E (dashboard/reports/pricing) + F (translations)
- [ ] (R4) `add_subscriber_screen.dart`: category dropdown (commercial/standard/gold).
- [ ] (R5) `add_subscriber_screen.dart`: circuit picker excludes/disables taken circuits.
- [ ] (R7/R8) `add_subscriber_screen.dart`: inline validation + error messages.
- [ ] (R4) `subscriber_detail_screen.dart`: show category; due uses category price.
- [ ] (R4) `monthly_pricing_screen.dart`: 3 price inputs (one per category) for the month.
- [ ] (R11) `dashboard_screen.dart`: month picker (reuse pricing-screen pattern).
- [ ] (R6) `dashboard_screen.dart`: Monthly Revenue + Monthly Remaining cards.
- [ ] (R6/R9) `reports_screen.dart`: metrics tied to month (confirm rendering).
- [ ] (R12) `lib/views/widgets/date_field.dart`: new reusable text+picker widget (yyyy-MM / yyyy-MM-dd).
- [ ] (R12) wire `DateField` into expenses month selector, monthly-pricing selector, subscriber-detail selector, add-expense dialog.
- [ ] (R4/R6/R8…) `translations.dart`: ar/en for category labels, monthly_revenue, monthly_remaining, circuit_in_use, duplicate_name.

## Phase 5 — Backend + panels  · Group G (backend) + H (panels)
- [ ] (R6/R9/R11) `accountController.buildDashboard`: category-aware expected; return `monthlyRevenue`/`monthlyRemaining`.
- [ ] (R4) `adminController`: `SEARCH_FIELDS.subscribers += 'category'`; `labelFor` includes category.
- [ ] (R4) `serialize.js`: include category on subscribers/prices where serialized.
- [ ] (R4) `index.html`: `SYNC_COLUMNS.subscribers` += category column (admin + owner).
- [ ] (R4) `index.html` owner monthly-pricing surface: 3 category prices.
- [ ] (R6) `index.html` owner home/reports: Monthly Revenue & Remaining for the selected month.

## Phase 6 — Verify + ship
- [ ] `flutter analyze` 0 errors; `flutter test` green; `cd backend && npm test` green.
- [ ] Live self-test (seeded): categories+prices, dashboard month switch, price-change recalc (R10), socket exclusivity (R5/R7), duplicate-name (R8), monthly metrics (R6) — device + admin panel + owner panel.
- [ ] Confirm app on Tikrit production API.
- [ ] `flutter build apk --release`.
- [ ] `MILESTONES.md` entry; commit + push.
