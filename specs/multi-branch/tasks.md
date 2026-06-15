# Spec-Kit — Multi-Branch Implementation Plan (tasks)

*(Deliverable 10.)* Ordered, additive, each phase compiles + tests green before the next. Every task names its file and the **accountant precedent** to copy. **No code here — this is the work breakdown.** Phases are sequenced by dependency (schema → models → selection → scoping → UI → backend → migration/test → rollout).

Legend: 🟦 Flutter · 🟩 Backend · 🟪 Admin/Owner SPA · ✅ verification gate.

---

## Phase 0 — Decisions & flag (½ day)
- T0.1 Confirm decisions **D-1…D-4** (spec §13) with the Owner. Defaults: per-branch infra, accountant bound to home branch, per-branch receipt numbering, per-branch price.
- T0.2 Define the kill-switch: branch UI active only when `branchCount > 1` (single-branch orgs see no change).

## Phase 1 — Schema v4→v5 + models + repository  🟦
*(Precedent: accountant v2→v3 migration + `accountant_model.dart` + `accountant_repository.dart`.)*
- T1.1 `lib/data/db_helper.dart`: bump `version` 4→5; add `_onUpgrade(<5)` branch: `CREATE TABLE IF NOT EXISTS branches(...)`, `_addColumn('branch_id','TEXT')` on boards/circuits/subscribers/receipts/refunds/expenses/monthly_prices, add `branches→id` to `syncedTables`, call `_createSyncInfra`.
- T1.2 `db_helper.dart` `_onCreate`: add `branch_id` to the 7 CREATE TABLEs + the `branches` CREATE (fresh installs).
- T1.3 Main-Branch bootstrap (idempotent, on upgrade + fresh): seed one `is_main` branch if none. (Choose NULL-means-Main fallback ⇒ **no backfill UPDATE**; else add the transaction+purge backfill — plan §3.)
- T1.4 `lib/data/models/`: add `branchId` to Board/Circuit/Subscriber (`core_models.dart`), Receipt/MonthlyPrice (`billing_models.dart`), Expense (`expense_model.dart`); new `branch_model.dart` (mirror `accountant_model.dart`).
- T1.5 New `lib/data/repositories/branch_repository.dart` (mirror `accountant_repository.dart`, no credentials): `getAll/getById/count/create/update/delete`, `mainBranch()`.
- ✅ G1: `flutter analyze` 0 errors; new `test/branch_migration_test.dart` proves v4→v5 adds columns + a Main Branch + (NULL-means-Main) legacy rows resolve to Main.

## Phase 2 — Active-branch selection layer  🟦
*(Precedent: acting-user in `auth_controller.dart` + `user_switch_screen.dart`.)*
- T2.1 New `lib/controllers/branch_controller.dart` (registered in `app_binding.dart`): `Rxn<Branch> currentBranch`, `List<Branch> branches`, `String? get scopeBranchId` (null = All/consolidated), `setBranch()/loadBranches()`, persist `active_branch_id` (SharedPreferences), restore on launch; default = Main for owner, home-branch for accountant.
- T2.2 Owner-only **branch selector** (app bar / drawer entry) with *All branches* + each branch; accountant: fixed to home branch (no selector).
- ✅ G2: switching branch updates `scopeBranchId`; selection persists across relaunch.

## Phase 3 — Branch scoping (reads) + stamping (writes) + numbering  🟦
*(Precedent: the `accountantId` scope params already in the repos/controllers.)*
- T3.1 Repos: add optional `branchId` to reads/counts/sums in `core_repositories.dart`, `billing_repositories.dart`, `expense_repository.dart` (same `branchId == null ? noWhere : 'branch_id = ?'` shape, with NULL-means-Main handling).
- T3.2 `getNextReceiptNumber(branchId)` → `MAX(receipt_no) WHERE branch_id = ?` + 1 (D-3).
- T3.3 Controllers (`core/billing/expense/dashboard/reports`): pass `branchController.scopeBranchId` to reads; stamp the active `branch_id` on every create (boards/circuits/subscribers/receipts/expenses/prices); `ever(branchController.currentBranch)` re-loads (mirror `ever(auth.currentUser)`).
- T3.4 Compose with accountant scope: a read may pass both `branchId` + `accountantId`.
- ✅ G3: new `test/branch_scoping_test.dart` (mirror `accountant_scoping_test.dart`): create in Branch A vs B, reads scoped, consolidated = all, per-branch receipt numbering, delete is branch-aware.

## Phase 4 — Owner UI: branch management + reports/dashboard  🟦
- T4.1 New `lib/views/screens/branches_screen.dart` (owner-only; mirror `accountants_screen.dart`): create/rename/enable-disable branch; reachable from a Settings tile.
- T4.2 Reports + dashboard: owner-only **branch filter** (All + each) + a **branch count** card (mirror the accountant filter/count in `reports_screen.dart`); per-branch + consolidated.
- T4.3 (D-2) accountant create/edit: add a **home-branch** picker (`branch_id` on the accountant) in `accountants_screen.dart`.
- ✅ G4: device walk-through — owner creates branches, switches, sees scoped + consolidated; accountant locked to home branch.

## Phase 5 — Backend + panels  🟩🟪
*(Precedent: the accountant filter in `accountController.buildDashboard` + the `accountants` tab in the SPA.)*
- T5.1 `accountController.js`: add `branchId` param to `buildDashboard` (reuse `inScope`, NULL-means-Main); `getMyStats` reads `?branchId=`; add `'branches'` to `STAT_ENTITIES` (count).
- T5.2 `adminController.js`: add `'branches'` to `SEARCH_FIELDS` + `labelFor`.
- T5.3 SPA `index.html`: add `'branches'` to `SYNC_ENTITIES` + `OWNER_ENTITIES` (+ a `SYNC_COLUMNS` def) for a branches tab; add a **branch filter** + count card on the owner `#/my` reports/dashboard (mirror the accountant filter at the existing `accountantId` site); optional admin per-owner branch filter.
- T5.4 `SyncRecord.js`, `syncController.js`, auth, routes — **no change** (confirm).
- ✅ G5: live API check — push branches + branch-tagged data; `?branchId=A` scopes money, consolidated sums across branches, `counts.branches` correct; SPA shows branches tab + filter (mirror the accountant live-verify already done).

## Phase 6 — Migration, sync/backup verification, tests  🟦🟩
- T6.1 Verify upgrade path on a real v4 DB (seed → upgrade → Main Branch + legacy rows resolve to Main; no loss/dup).
- T6.2 Verify sync: branch rows + `branch_id` push/pull (whole-row) with no engine change; `deleteLocalData` includes `branches`.
- T6.3 Verify cloud backup → restore preserves branches + `branch_id`.
- T6.4 Full suites green (Flutter + backend) + new branch tests; `flutter analyze` 0 errors.

## Phase 7 — Rollout & rollback rehearsal
- T7.1 Ship app + backend together; gate panel branch UI on `counts.branches`.
- T7.2 Rehearse rollback (plan §9): deploy prior app → confirm consolidated read, no loss; revert backend `branchId` handling → consolidated.
- T7.3 Docs: update `CLAUDE.md` (schema v5 + branches) + `MILESTONES.md`; reconnect app to production API.

---

## Effort & sequencing (rough)
| Phase | Theme | Est. |
|---|---|---|
| 0 | Decisions + flag | 0.5d |
| 1 | Schema/models/repo | 1.5d |
| 2 | Active-branch layer | 1d |
| 3 | Scoping/stamping/numbering | 1.5d |
| 4 | Owner UI | 2d |
| 5 | Backend + panels | 1.5d |
| 6 | Migration + tests + sync/backup verify | 1.5d |
| 7 | Rollout/rollback | 0.5d |

**~10 working days**, fully additive, each phase independently shippable behind the kill-switch.

## Coverage map → required spec sections
Flutter (P1–4) · Owner dashboard (P4/P5 panel) · Admin dashboard (P5) · Auth (none — P2 local layer) · Authz/permissions (P2/P4, plan §6) · SQLite (P1) · MongoDB (P5) · Sync engine (none — P6 verify) · Offline (P2/P3) · Online sync (P6) · Cloud backup (none — P6 verify) · Reporting (P4/P5) · Migration (P1/P6, plan §3) · Data-ownership model (spec §6) · Branch isolation (spec §7, P3) · Consolidated reporting (spec §8, P4/P5).
