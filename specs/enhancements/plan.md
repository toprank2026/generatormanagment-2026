# Plan — Generator Management Enhancements (v6)

Implementation strategy for the 12 requirements in [spec.md](spec.md). Sequenced so the
risky/foundational schema work lands first and everything else builds on it.

## Phasing

### Phase 0 — Quick wins (no schema, low risk) — *can ship alone*
Fixes that are isolated UI/controller changes; do these first to de-risk and deliver value fast.
- **R2** await the dialog write before `Get.back()` (circuits + boards add/edit).
- **R3** add `AlwaysScrollableScrollPhysics()` to the boards `GridView` (and audit circuits list).
- **R1** raise page sizes to ~100 across the 4 list controllers and keep `loadMore` active (infinite scroll loads the rest) — per confirmed D1.
- **R12** add a reusable `DateField` (text + picker) widget and wire the 3 month selectors +
  add-expense dialog.

### Phase 1 — Schema v6 migration (foundational, breaking)
`db_helper.dart`: version 5→6; `_onUpgrade` `if (oldVersion < 6)`:
1. `subscribers.category` (default `'standard'`) + backfill.
2. `monthly_prices` reshape to `id = month|branch|category` + `category` column + backfill standard.
3. `receipts.category_snapshot`.
4. Deactivate legacy circuit duplicates (D6), then add the two `subscribers` exclusivity triggers.
5. `_createSyncInfra` re-applied for reshaped `monthly_prices` (triggers drop/recreate ordering as in v5).
Add/extend the v6 migration test (mirrors the v4→v5 test in `branch_isolation_test.dart`).

### Phase 2 — Models + repositories (data layer)
- `Subscriber.category`; `MonthlyPrice` category + `buildId(month, branch, category)`;
  `Receipt.categorySnapshot`.
- `MonthlyPriceRepository.getByMonth(month, {branchId, category})` + a
  `getAllCategories(month, branchId)` helper (one row per category) to avoid N+1.
- `SubscriberRepository`: `isCircuitTaken(circuitId, branchId, {exceptId})`,
  `nameExists(name, branchId, {exceptId})`; enforce in `insert/update` (throw typed errors).
- `ReceiptRepository.getCollectedSum` already month+branch scoped → reused for Monthly Revenue.

### Phase 3 — Controllers (business logic)
- `BillingController`: `setPrice(category, price)`; `getDueAmount`/`collectPayment` use
  `subscriber.category`; stamp `categorySnapshot`; **`setPrice` → reload dashboard (R10)**.
- `DashboardController`: add `selectedMonth` + `changeMonth()`; category-aware expected (R11);
  expose `monthlyRevenue` + `monthlyRemaining` (R6/R9).
- `ReportsController`: category-aware expected; ensure the two metrics surface per month.
- `CoreController.addSubscriber/updateSubscriber`: surface circuit-taken + duplicate-name errors
  as snackbars; stamp `category`.

### Phase 4 — UI (screens + widgets)
- `add_subscriber_screen`: category dropdown; circuit picker filters out taken circuits (R5);
  inline validation for R7/R8.
- `monthly_pricing_screen`: 3 price inputs (one per category) for the selected month.
- `dashboard_screen`: month picker (R11) + the two new metric cards (R6).
- `reports_screen`: ensure metrics tied to month; category context.
- `subscriber_detail_screen`: show category; due uses category price.
- `translations.dart`: add ar/en for `category`, `commercial/standard/gold`, `monthly_revenue`,
  `monthly_remaining`, validation messages, `circuit_in_use`, `duplicate_name`.

### Phase 5 — Backend + panels
- `accountController.buildDashboard`: category-aware expected; return `monthlyRevenue`/
  `monthlyRemaining`; keep month + branch scoping.
- `adminController`: `SEARCH_FIELDS.subscribers` += `category`; `labelFor` shows category.
- `serialize`: include category where subscribers/prices are serialized.
- `index.html` (admin + owner): subscribers table category column; monthly-pricing shows 3
  category prices; home/reports show Monthly Revenue & Remaining for the selected month.

### Phase 6 — Verify + ship
- `flutter analyze` 0 errors; `flutter test` + `cd backend && npm test` green (add v6 migration,
  category pricing, circuit-uniqueness, duplicate-name, monthly-metrics tests).
- **Self-test live** (own seeded data): run backend in-memory, seed 3 categories + prices + a few
  subscribers; exercise dashboard month switching, price-change recalc, socket exclusivity,
  duplicate-name rejection, on the device + admin/owner panels.
- Confirm the app is on the **Tikrit production API** (default `https://generator.tikritstore.shop`).
- `flutter build apk --release`.

## How this gets built (re: "spawn 50 agents")

50 *simultaneous editors* on this codebase would collide — `db_helper.dart`,
`core_controller.dart`, `dashboard_controller.dart`, and `index.html` are each touched by several
requirements, and this repo's CLAUDE.md records a prior parallel run that ran `git` and **reverted
uncommitted edits**. So we parallelize the *safe* way:

1. **Phase 1 (schema) is done first and alone** — it's the shared foundation; everything depends on
   the v6 columns. One author, committed as a checkpoint.
2. **After the checkpoint, fan out by _disjoint file ownership_** — group the remaining work into
   non-overlapping file sets (e.g. "billing+pricing", "dashboard+reports", "subscriber UI+validation",
   "expenses+DateField", "backend", "panels", "translations", "tests"). Each group is one worktree-
   isolated agent so edits can't clobber each other; results merge cleanly.
3. **Editing agents are forbidden from running `git`** (per the CLAUDE.md gotcha); the orchestrator
   commits.
4. **Adversarial verify pass** after merge (like the v5 audit that caught the cross-branch due bug):
   re-read each requirement's code to confirm correctness + isolation.

This achieves the parallelism you want without the data-loss risk of 50 racing editors.

## Risks (top)
- **monthly_prices PK reshape** (D2) must match server expectations — the mirror stores `localId`;
  reshaped rows re-push as new ids; old `month|branch` rows become orphaned on the server (harmless,
  push-only mirror). Document.
- **Circuit-exclusivity trigger** turns silent `INSERT OR REPLACE` into `ABORT` — wrap multi-row sync
  pulls in transactions; ensure pull doesn't trip the trigger (pull writes whole rows incl. status).
  → trigger must allow same-id replace; only block a *different* id holding the circuit.
- **Category default** ('standard') keeps every legacy subscriber billing exactly as before until the
  owner sets commercial/gold prices → no behavior change on upgrade.
- **Show-all (D1)** perf at very large N — acceptable for current scale; revisit if needed.

## Test plan (new/changed)
- v6 migration: legacy subscriber → category `standard`; legacy price → `month|branch|standard`;
  circuit dupes deactivated; triggers reject a 2nd active subscriber on a circuit.
- Pricing: 3 categories priced independently; due = amps×price[category]; receipt snapshots category.
- Validation: circuit-taken rejected; duplicate name (case/space-insensitive, per branch) rejected.
- Metrics: Monthly Revenue / Remaining correct per month; setPrice recalcs dashboard.
- Backend: `stats` returns the two metrics + category-aware expected; `data?entity=subscribers`
  carries category.
