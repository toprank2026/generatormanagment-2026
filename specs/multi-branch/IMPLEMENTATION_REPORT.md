# Multi-Branch — Implementation Report

**Feature:** Multi-Branch support for "Flash" (generatormanagment).
**Model:** Full isolation — each branch is an independent ERP instance under one
owner account. Switching a branch switches the **whole system context**, it is
not a filter over shared data.
**Approach:** Additive only. No existing architecture, sync engine, or business
logic was refactored. Legacy data is mapped into a default **Main Branch**.

Approved decisions implemented: **D-1** independent data per branch · **D-2** a
user/accountant belongs to one branch · **D-3** invoice/receipt numbering is
independent per branch · **D-4** pricing/subscription rules vary per branch.

---

## 1. What changed (by layer)

### 1.1 SQLite schema — `lib/data/db_helper.dart` (version 4 → **5**)
- New **`branches`** table (`id, name, code, is_main, active, created_at`) — a
  synced *identity* table, exactly like `accountants` (no credentials).
- **`branch_id TEXT`** column added to every per-branch business table:
  `boards, circuits, subscribers, receipts, refunds, expenses`.
- **`monthly_prices` reshaped** for per-branch pricing (D-4): the primary key
  moved from `month` to a synthetic **`id = "<month>|<branchId>"`** plus a
  `branch_id` column, so two branches can price the same month independently.
- `syncedTables` gains `branches` and `monthly_prices` is re-keyed to `id` — the
  whole-row sync/backup engine therefore carries the new table/columns
  automatically (**no engine change**).
- **v4→v5 migration** (`_onUpgrade`): creates `branches`, adds `branch_id` to the
  six tables, recreates the `monthly_prices` table (drop triggers → rename →
  create new shape → recreate sync infra → copy rows as `"<month>|main"`), then
  **backfills** every legacy row with `branch_id = 'main'`. These UPDATEs go
  through the sync triggers, so `branch_id` propagates to the server mirror on
  the next sync. `DbHelper.kMainBranchId = 'main'` is the fixed Main id.

### 1.2 Models — `lib/data/models/`
- New `branch_model.dart` (`Branch` + `isMainBranch`).
- `branch_id` added to `Board`, `Circuit`, `Subscriber` (core_models), `Receipt`
  (billing_models), `Expense` (expense_model).
- `MonthlyPrice` gains `branchId` + `static buildId(month, branchId)` + the
  synthetic `id` getter used as the table PK and sync localId.

### 1.3 Branch context layer
- `lib/data/repositories/branch_repository.dart` — `ensureMain()` (idempotent
  seed of `id='main'`), `create/update/delete/getAll/getById/count`. **Delete
  cascades** the branch's entire isolated data set (boards/circuits/subscribers/
  receipts+refunds/expenses/prices) in one transaction; the **Main Branch is
  protected** (never deletable).
- `lib/controllers/branch_controller.dart` (registered **permanent** in
  `app_binding.dart`) — holds the active branch:
  - `scopeBranchId` → branch id for **reads** (`null` = consolidated / All).
  - `writeBranchId` → branch id to **stamp** on creates (never null; falls back
    to Main).
  - `setBranch()` / `setConsolidated()` persist the choice
    (`active_branch_id`); `addBranch/editBranch/removeBranch` are the owner CRUD
    wrappers. On launch it defaults to Main immediately (no un-scoped flash) then
    restores the saved branch.

### 1.4 Data-layer scoping (the isolation contract) — repos + controllers
Every read repository method gained an optional **`branchId`** parameter that
**composes** with the existing `accountantId` (both `null`-safe, clause-builder
style). Controllers pass `BranchController.scopeBranchId` on reads, stamp
`writeBranchId` on creates, and add an `ever(branchController.currentBranch)`
listener so a branch switch reloads the screen — the same pattern already used
for the acting-user switch.

| Surface | Read scoped by branch | Create stamps branch |
|---|---|---|
| Boards / Circuits / Subscribers (`CoreController`) | ✅ | ✅ |
| Receipts + per-branch numbering (`BillingController`) | ✅ | ✅ (`getNextReceiptNumber(branchId)` = per-branch MAX+1, **D-3**) |
| Monthly price (`BillingController`) | ✅ (`getByMonth(month, branchId)`) | ✅ (synthetic id, **D-4**) |
| Expenses (`ExpenseController`) | ✅ | ✅ |
| Dashboard (`DashboardController`) | ✅ all figures | — |
| Reports (`ReportsController`) | ✅ all figures (+ existing accountant filter) | — |

> Boards/circuits/subscribers remain **shared across accountants within a
> branch** (the prior accountant model), so they are scoped by **branch only**;
> receipts/expenses are scoped by **branch + accountant** (two axes).

### 1.5 Flutter UI (owner-only, plan-gated)
- `lib/views/screens/branches_screen.dart` — Branches management (create / edit /
  delete / activate). Gated on `auth.isAdmin && auth.canMultiBranch`; reached
  from **Settings → الفروع**.
- `lib/views/widgets/branch_selector.dart` — the dashboard **active-branch
  selector** (card → bottom sheet listing branches + "All branches
  (consolidated)" for the owner + a "manage" shortcut). Renders **only** when
  `auth.canMultiBranch`; single-branch owners see nothing.
- Settings gains a Branches tile; the dashboard shows the selector under the
  banner. New EN/AR strings in `translations.dart`.

### 1.6 Per-plan gating (Multi-Branch is an upgrade)
- Backend `Plan.multiBranchEnabled` (default **false** — opt-in, unlike the
  default-true sync/backup/ownerPanel flags), surfaced through
  `planFeatures.featuresForUser` → `account.subscription.features.multiBranch` →
  `AuthController.canMultiBranch`. Admin plan editor toggle + plan-list chip +
  plan-card check/cross.

### 1.7 Backend + admin/owner panels
- `accountController.buildDashboard()` / `getMyStats` accept **`?branchId`**:
  branch is the outer partition (every Mongo query scoped to it), accountant
  stays the inner money scope; the per-branch price is matched by
  `data.month` + `data.branch_id`.
- `adminController`: `branches` added to `SEARCH_FIELDS` + `labelFor`;
  `branch_id` (and `accountant_id`) added to the drill-down whitelist.
- `accountController.STAT_ENTITIES` gains `branches`.
- Admin SPA (`backend/public/admin/index.html`): `branches` added to
  `SYNC_ENTITIES` / `OWNER_ENTITIES` / `SYNC_COLUMNS`, a **branches stat card**,
  a **branch filter** dropdown on the owner reports (shown once >1 branch
  exists), and `API.myStats(month, accountantId, branchId)`.

---

## 2. How it works (runtime)

1. **Launch** — `BranchController` defaults to Main, `ensureMain()` seeds the
   `branches` row, then the last active branch is restored. With a plan that
   lacks Multi-Branch, the owner silently stays on Main and no branch UI shows.
2. **Reads** — controllers pass `scopeBranchId`; SQLite returns only the active
   branch's rows. The dashboard/reports recompute per branch.
3. **Writes** — new boards/circuits/subscribers/receipts/expenses/prices are
   stamped with `writeBranchId`; receipt numbers and month prices are per-branch.
4. **Switch branch** — the selector calls `setBranch()`; `ever()` listeners
   reload every screen → the entire app context swaps (not a filter).
5. **Consolidated** — the owner can pick "All branches" (`scopeBranchId == null`)
   for cross-branch **reporting only**.
6. **Sync / backup** — unchanged. Whole-row push carries `branch_id` + the
   `branches` rows; whole-DB backup carries everything. The admin/owner panels
   read the mirror and can scope the dashboard by `?branchId`.
7. **New device / restore** — `SyncService.pull` (ConflictAlgorithm.replace)
   restores branches + branch-stamped rows as-is.

---

## 3. Testing & verification

**Automated — all green.**

- `flutter analyze` → **0 errors** (only pre-existing info/style lints; one
  unrelated unused-import warning in `expenses_screen.dart`).
- `flutter test` → **73 passed** (was 61). New `test/branch_isolation_test.dart`
  (12 tests):
  - branch read scoping for boards / circuits / subscribers / collected sum /
    expenses total / paid-unpaid counts;
  - **per-branch receipt numbering** (each branch keeps its own 1..N) — D-3;
  - **per-branch monthly price** (same month, different price; synthetic id) — D-4;
  - **branch delete cascade** removes only that branch's data; Main is protected;
  - **branch + accountant** scopes compose on receipts;
  - **v4→v5 migration**: legacy boards/subscribers backfilled to `branch_id='main'`,
    `monthly_prices` reshaped to `"<month>|main"`, `branches` table seeded.
- `cd backend && npm test` → **70 passed** (was 67). New
  `backend/test/branch_stats.test.mjs` (3 tests) boots a real Express server and
  proves `/api/account/stats?branchId=` isolates each branch (own price /
  subscribers / paid-unpaid / collected / expenses / boards), the no-filter call
  is consolidated, and `counts.branches` is reported — i.e. the exact data path
  the **owner panel** and **admin panel** consume.

**Workflow coverage (app · owner panel · admin panel).** The three surfaces all
read through the same scoped repositories (app) and `/api/account` +
`/api/admin` endpoints (panels) that the automated tests above exercise
end-to-end, including the v4→v5 migration that every existing install will run.
A live device click-through and a live-server panel click-through were **not**
performed in this environment (no emulator/live backend session here); the
behaviour each surface depends on is covered by the isolation, migration, and
branch-stats tests.

---

## 4. Notes / limitations

- **Consolidated pricing is approximate.** With `branchId == null` and different
  per-branch prices for a month, the price lookup returns one branch's row, so
  the consolidated "expected/price" figure is indicative. Collected/expenses
  totals are exact sums. Normal operation always has a concrete active branch.
- **Legacy mirror rows** pushed before v5 carry no `branch_id`; the v5 backfill
  re-stamps and re-syncs them to `main` on the next sync (an accepted, one-time
  re-sync of existing rows).
- **No engine changes** were required — branch isolation rides entirely on the
  existing whole-row sync + whole-DB backup.
