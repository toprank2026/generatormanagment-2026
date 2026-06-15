# Spec-Kit — Multi-Branch Technical Plan

Companion to `spec.md`. Covers the *how*: proposed architecture, data model, migration, API changes, sync/backup, permissions, risk, rollback. **No code** — signatures shown are illustrative shapes only.

Guiding principle: **clone the accountant pattern, substitute `branch`.** Every item below has a working precedent shipped in this codebase, which is why the change is low-risk and additive.

---

## 1. Proposed Multi-Branch architecture *(Deliverable 3)*

Three additive layers, each mirroring an existing one:

1. **Identity layer — `branches` synced table** (mirror of `accountants`). Holds the org's branches as server-visible identities (`id`, `name`, `code?`, `is_main`, `active`, `created_at`). Synced via the existing engine; the panels resolve branch names from it.
2. **Attribution layer — `branch_id` column** on every business table (mirror of `accountant_id`). Nullable; `null` ⇒ Main Branch. Carried by whole-row sync + whole-DB backup with no engine change.
3. **Selection layer — "active branch"** (mirror of the acting-user). A `Rxn<Branch> currentBranch` on a small `BranchController` (or alongside `AuthController`), persisted in SharedPreferences, restored on launch, with a `scopeBranchId` getter (`null` = consolidated / All). Controllers `ever(currentBranch)` re-load — identical to the existing `ever(auth.currentUser)`.

```
                       Organization (cloud account)  ── unchanged
                                  │
        ┌─────────────────────────┼──────────────────────────┐
   branches[] (NEW synced)   accountants[] (existing)    business rows
        │                                                  branch_id  + accountant_id
        └── active branch (device-local, persisted) ──► scopes reads + stamps writes
                                                          (All = consolidated)
```

**Why this is the smallest change:** the sync engine, `SyncRecord`, cloud backup, auth protocol, device binding, and subscription flow are **untouched**. Only additive: 1 table, 7 nullable columns, 1 small selection controller, optional scope params, and UI.

## 2. Data model (schema additions, v4 → v5)

New synced table:
```
branches ( id TEXT PK, name TEXT, code TEXT, is_main INTEGER DEFAULT 0,
           active INTEGER DEFAULT 1, created_at TEXT DEFAULT CURRENT_TIMESTAMP )
```
New nullable column `branch_id TEXT` on: **boards, circuits, subscribers, receipts, refunds, expenses, monthly_prices**.

`syncedTables` gains `branches → id` (so `_createSyncInfra` auto-creates its triggers). Models gain a `branchId` field with `toMap/fromMap` (mirror of how `accountantId` was added to `Board/Circuit/Subscriber/Expense/Receipt`). New `Branch` model (mirror of `Accountant`) + `BranchRepository` (mirror of `AccountantRepository`, but no credentials — branches are pure identities).

Decision-dependent:
- **D-4 monthly_prices:** to make price per-branch without breaking the `month` PK or the sync `localId`, change the device PK to a composite **`(month, branch_id)`** via a new table shape on v5, or (lower-risk, recommended) keep `monthly_prices` as-is and add `branch_id`, making the effective key `(month, branch_id)` enforced in the repo + sync `localId = "<month>|<branchId>"`. The simplest backward-compatible path is the latter (legacy rows = `branch_id` Main).
- **D-3 receipt_no:** `getNextReceiptNumber(branchId)` = `MAX(receipt_no) WHERE branch_id = ?` + 1 (per-branch sequence).

## 3. Database migration plan *(Deliverable 4)*

`_onUpgrade` gains a v4→v5 branch (mirror of the v2→v3 accountant branch):

1. `CREATE TABLE IF NOT EXISTS branches (...)`.
2. `_addColumn(t, 'branch_id', 'TEXT')` for boards, circuits, subscribers, receipts, refunds, expenses, monthly_prices (idempotent; safe on mixed installs).
3. Add `branches` to `syncedTables` (so a fresh v5 `_onCreate` includes it) and call `_createSyncInfra(db)` (idempotent `IF NOT EXISTS`) so the `branches` triggers are created.
4. **One-time Main-Branch bootstrap (per device, idempotent):** if no branch exists, insert a `branches` row `{id: <uuid>, name: 'Main Branch'/'الفرع الرئيسي', is_main: 1, active: 1}`.
5. **Backfill legacy rows:** `UPDATE <table> SET branch_id = <mainId> WHERE branch_id IS NULL` for the 7 tables.
   - ⚠️ **Sync-flood caveat (CLAUDE.md gotcha):** these UPDATEs fire the AFTER-UPDATE triggers → the whole dataset is enqueued to `sync_outbox` and re-pushed on next sync. This is acceptable (it also fixes the pre-v3 "rows never synced until edited" gap) but for large datasets do the backfill **inside one transaction and then delete the `sync_outbox` rows it generated** (the same purge pattern `SyncService.pull` already uses), and instead **enqueue a single re-push** or rely on the next normal sync. Prefer NULL-means-Main at read/scope time to avoid any backfill at all (see fallback below).
   - **Fallback (zero-migration option):** treat `branch_id IS NULL` as Main Branch in every scope clause (app + backend `inScope`), so legacy rows need **no UPDATE** and **no re-sync**. The Main Branch row is still created so it can be selected/labeled. This is the lowest-risk path and is the recommended default; the explicit backfill is optional/cosmetic.
6. **Backward compatibility:** fresh installs run `_onCreate` at v5 (all columns + `branches` present, with a Main Branch seeded on first run). Existing v2/v3/v4 installs run the cumulative `_onUpgrade` branches in order. A restored **v4 backup** opened by a v5 binary auto-upgrades; a **v5 backup** opened by a v4 binary keeps `branch_id`/`branches` as inert extra data (SQLite ignores unknown columns/tables on read paths that don't select them).

## 4. API changes *(Deliverable 5)* — backend (`backend/src`)

All additive and optional (omitting the param = today's behavior = consolidated):
- **`accountController.buildDashboard(userId, counts, month, accountantId?, branchId?)`** — add a `branchId` param; reuse the existing `inScope` JS-filter pattern (the accountant filter already does this) so that when `branchId` is set, every figure scopes to `data.branch_id === branchId` **OR** (`branch_id` absent ⇒ Main). Consolidated (`branchId` null) = all branches.
- **`getMyStats`** — read `?branchId=` (validated string) and pass it through; also surface `counts.branches` (add `'branches'` to `STAT_ENTITIES`) for the branch-count card.
- **`getMyData` / `listUserData`** — already entity-agnostic; `entity=branches` works for free. Add `branches` to `adminController.SEARCH_FIELDS` (`['name','code']`) and `labelFor` (return `data.name`) for clean rendering.
- **`SyncRecord`, `syncController` (push/pull), `authController`, `User`/`Plan` models, device binding, subscription routes — NO CHANGE.**
- **Optional (admin):** a per-owner branch filter param on the admin data/stats endpoints (mirror of the accountant filter), or compute client-side in the SPA.

## 5. Sync & backup changes *(Deliverable 6)*

- **Sync engine: NONE.** `SyncService.push` reads the full row by PK (so `branch_id` is included) and `pull` writes with `ConflictAlgorithm.replace`. Adding `branches` to `syncedTables` makes it sync like any entity. `deleteLocalData` should add `branches` to the wiped set (it already iterates synced business tables) — minor, additive.
- **Backup: NONE.** Cloud backup uploads/restores the **entire `moldati.db`** file; the `branches` table and all `branch_id` values are included automatically. Restore-then-relogin already rebuilds state.
- **One consideration:** the v4→v5 backfill (if chosen over the NULL-means-Main fallback) generates outbox rows → a larger first push after upgrade. Mitigate with the transaction+purge pattern or prefer the fallback.

## 6. Permission model *(Deliverable 7)*

Reuses `AuthController` (cloud role owner|admin) + the acting-user `can(perm)` layer.

| Action | Owner / admin | Accountant |
|---|---|---|
| Create / rename / disable a branch | ✅ | ❌ (owner-only) |
| Switch active branch freely (incl. *All branches* consolidated) | ✅ | ❌ — locked to home branch (D-2) |
| See consolidated (cross-branch) reports | ✅ | ❌ — only their home branch |
| CRUD business data | ✅ (in active branch) | per existing `Perm.*`, **within their home branch only** |
| Collect payment / print | ✅ | ✅ (stamps `branch_id`=home, `accountant_id`=self) |

- Branch management is a new **owner-only** screen (gate with `auth.isAdmin`, exactly like the accountants screen).
- The active-branch selector shows *All branches* + each branch for the owner; for an accountant it is fixed to their `branch_id` (no selector, no consolidated).
- **No change to the auth protocol, JWT, or backend authorization** — branch authorization is enforced in the same client acting-layer + the owner-only mirror scoping already in place.

## 7. Authentication / authorization / local-storage / offline impact (cross-cut)

- **Authentication:** unchanged. No new token, claim, or login step. The active branch is **device-local state** layered on the existing session (same as the acting user). Optional convenience: persist `active_branch_id` next to `acting_user_id` in SharedPreferences.
- **Authorization:** as §6 — additive client gating; the server still scopes the mirror to the JWT account.
- **Local storage (SQLite):** +1 table, +7 nullable columns, +1 SharedPreferences key. No destructive change.
- **Offline:** branch create/select/scope/stamp all run offline; selection persisted + restored (mirror of acting-user restore).
- **Online sync:** branch rows + columns flow through the unchanged engine.

## 8. Risk analysis *(Deliverable 8)*

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Migration re-sync flood (backfill UPDATE enqueues whole dataset) | Med | Perf/data spike on first sync | Prefer **NULL-means-Main** fallback (no backfill); else transaction + outbox purge. |
| R2 | A read path forgets the branch scope → cross-branch leakage | Med | Wrong data shown | Single `scopeBranchId` source + the `ever(currentBranch)` reload; mirror the accountant scoping checklist; add isolation tests. |
| R3 | Receipt-number collision if D-3 changed on existing data | Low | Duplicate receipt no. | Per-branch `MAX+1`; existing receipts keep their numbers (all in Main). New branches start fresh. |
| R4 | `monthly_prices` PK/`localId` change breaks sync identity (D-4) | Med | Price sync conflicts | Use composite `localId = month|branchId`; legacy rows = `month|main`; never change existing `month`-only rows in place without re-mapping. |
| R5 | Accountant×branch interaction confusion (two scope axes) | Med | Mis-scoped reports | Define precedence (branch filter ∧ accountant filter compose); document in spec §8; test combined filters. |
| R6 | Backend not redeployed → panel branch filter/count missing | Med | Panel lacks branch view (app still fine) | App is offline-first and works without backend; ship app + backend together; feature-flag the panel UI on `counts.branches`. |
| R7 | Older client after partial rollout reads new data | Low | Sees all branches (consolidated) | Acceptable + safe by design (no scope = consolidated); no crash, no data loss. |
| R8 | Pre-v3 legacy rows still missing from mirror | Low | Some old rows not in panel | Same pre-existing gap; the Main-Branch backfill (if chosen) also closes it. |

## 9. Rollback strategy *(Deliverable 9)*

The feature is **forward-compatible and reversible** because every change is additive + nullable:

1. **App rollback (deploy previous app version):** the old binary has no branch awareness → it reads all rows ignoring `branch_id` and never opens the `branches` table. Result: the user sees **all data consolidated** (today's behavior). **No data loss, no schema downgrade needed** — SQLite keeps the extra column/table inertly. (SQLite has no DROP COLUMN need; leaving `branch_id`/`branches` is harmless.)
2. **Backend rollback:** the `?branchId` params are optional; reverting `buildDashboard`/`getMyStats`/admin handlers to the pre-branch version simply ignores them and returns consolidated figures. `branches` rows remain in the mirror as inert extra data.
3. **Panel rollback:** remove the branch picker/tab; the rest of the SPA is unaffected (branch is just unfetched).
4. **Data integrity on rollback:** because `branch_id IS NULL`/Main is treated as "no partition", rolled-back clients and servers converge to the consolidated all-data view with full integrity.
5. **Kill-switch:** gate the entire active-branch UI behind a single flag (e.g. `branchesEnabled = branchCount > 1` or a remote/plan flag); when off, the app behaves exactly as pre-branch even on a v5 schema.

**Net:** rollback at any layer degrades gracefully to today's single-(consolidated)-view behavior with no data loss and no destructive migration.
