# Spec-Kit — Multi-Branch Support

**Feature:** Multi-Branch for a Generator Owner organization
**Status:** Specification (no code)
**Type:** Additive feature — no refactor, no rename, no architecture redesign
**Author:** generated from full project inspection (7-agent read-only audit of schema, sync, backend, auth, dashboards, data layer, backup/offline)

---

## 1. Overview & business goal

A **Generator Owner** account today manages a single set of business data (boards/circuits/subscribers, monthly prices, receipts, refunds, expenses). The business goal is to let **one Owner account manage multiple branches** under the same organization, each branch keeping its own operational data, while the Owner can still see **consolidated** figures across all branches.

```
Owner (organization = the cloud account / JWT)
├── Main Branch      ← all existing data migrates here
├── Branch A
├── Branch B
└── Branch C
```

This is delivered as a **purely additive** capability that re-uses the exact pattern just shipped for **accountants** (a synced sub-entity table + an `*_id` column on business tables + an "acting" selector + optional scope filters). Nothing existing is renamed, refactored, or redesigned.

## 2. Scope

**In scope (additive only):**
- A `branches` synced entity owned by the organization.
- A nullable `branch_id` on every business table.
- An **active-branch** selector (mirrors the existing acting-user layer) + an **All-branches** consolidated mode.
- Branch-aware scoping on reads, branch stamping on writes.
- Branch management UI (owner-only), branch selector (Flutter), branch filter + count (owner panel + admin panel), per-branch and consolidated reports.
- A backward-compatible migration that places all existing data into an auto-created **Main Branch**.

**Out of scope (explicitly preserved, untouched):**
- The sync engine internals, the cloud-backup mechanism, device binding, subscription/plan flow.
- The accountant feature (branches are an *orthogonal* axis; both coexist).
- Any rename of existing modules, tables, columns, routes, or controllers.
- Any change to records that have no branch (they behave as **Main Branch**).

## 3. Glossary

| Term | Meaning |
|---|---|
| **Organization** | The existing cloud Owner account (one JWT, one server mirror, one `moldati.db`). Unchanged. |
| **Branch** | A named partition of the organization's operational data. New synced entity. |
| **Main Branch** | The default branch auto-created per organization; all pre-existing data belongs to it. |
| **Active branch** | The branch currently selected on a device — scopes reads + stamps writes. Mirrors the existing "acting user". |
| **Consolidated** | The Owner viewing **All branches** at once (no branch filter) for reporting. |

---

## 4. Current-state architecture summary *(Deliverable 1 — from inspection)*

**Stack.** Offline-first Flutter (GetX MVC) app "Flash" (`generatormanagment`) → repositories → `DbHelper` (SQLite `moldati.db`, **version 4**). A Node/Express/MongoDB backend owns auth, subscription/plans, device binding, opaque cloud DB backups, and a **read-only per-account sync mirror**. A single-file Arabic-RTL admin SPA (`backend/public/admin/index.html`) has an **ADMIN** area and an **OWNER** self-service area (`#/my`).

**Local schema (`lib/data/db_helper.dart`, v4).** Business tables: `boards`, `circuits`, `subscribers`, `monthly_prices` (PK=`month`), `receipts` (PK=`uuid`, sequential `receipt_no`), `refunds`, `expenses`; plus local-only `users` (credentials, **not synced**) and synced `accountants` (server-visible identity). `sync_outbox` + AFTER INSERT/UPDATE/DELETE triggers per synced table capture **only `(entity, op, pk)`**. `syncedTables = {boards, circuits, subscribers, monthly_prices, receipts, refunds, expenses, accountants}`. Migrations: v1→v2 (sync infra), v2→v3 (`accountant_id` on boards/circuits/subscribers/expenses + `accountants` table), v3→v4 (`permissions` on users/accountants). `_addColumn` does idempotent `ALTER TABLE … ADD COLUMN` (catches duplicate).

**Sync engine.** `SyncController` drains `sync_outbox`; `SyncService.push` **reads the FULL row by PK** (`db.query`) and POSTs it to `/api/sync/push`; `pull` writes rows back with `ConflictAlgorithm.replace`. The mirror is `SyncRecord {user, entity, localId, data, deleted, updatedAt}`, keyed by the JWT account. Plan-gated by `canSync`. ⇒ **A new column or new synced table propagates automatically** with no sync-engine change.

**Backend.** `accountController.buildDashboard(userId, counts, month, accountantId?)` aggregates the mirror per owner, with an optional accountant filter; `getMyStats` reads `?month=` + `?accountantId=`; `listUserData`/`getMyData` serve per-entity data (accepts any entity); `adminController` exposes per-owner data screens (`SEARCH_FIELDS`, `labelFor`, `STAT_ENTITIES` include `accountants`). Account model: `role` (owner|admin), JWT, device binding, `subscription.features {sync, backup, ownerPanel}`.

**Auth + acting-user.** Login is online (JWT) → cached for offline launch. An **acting-user layer** sits on top: accountants are local sub-users who sign in offline (`loginAsAccountant`), become `currentUser`, drive `scopeAccountantId` + `can(perm)`, and the selection is **persisted** (SharedPreferences) and restored on launch. `UserSwitchScreen` switches owner⇄accountant.

**Data layer.** Repositories accept an **optional `accountantId`** on reads/counts/sums (`null` = all). Controllers pass `auth.scopeAccountantId`; creates stamp attribution; deletes are scope-aware; `getNextReceiptNumber` is **global**. `ever(auth.currentUser)` re-scopes controllers on switch.

**Dashboards.** Flutter bottom-nav (Dashboard / Pricing / Expenses / Reports / Settings); dashboard cards navigate to boards/subscribers; Reports has an owner-only **accountant filter + count card**. Owner panel `#/my` mirrors this; Admin area has per-owner synced-data tabs (incl. `accountants`) + a per-owner dashboard with the accountant filter.

**Backup / offline.** `SettingsController` uploads/restores the **entire `moldati.db` file** (so any new table/column is included automatically). Offline-first throughout; `deleteLocalData` wipes the synced business tables + outbox.

**Sharing model just shipped (accountants).** Boards/circuits/subscribers are **shared**; receipts/expenses + their reports are **per-accountant** (receipt attributed to the collecting accountant). This is the direct precedent for branch scoping.

---

## 5. Gap analysis *(Deliverable 2)*

| # | Capability needed for Multi-Branch | Exists today? | Gap |
|---|---|---|---|
| G1 | A branch entity owned by the org | ❌ | Add synced `branches` table (template: `accountants`). |
| G2 | Each business record tagged to a branch | ❌ | Add nullable `branch_id` to the 7 business tables (template: `accountant_id`). |
| G3 | Sync carries branch data | ✅ (whole-row) | **None** — add `branches` to `syncedTables`; `branch_id` rides along. |
| G4 | Backup carries branch data | ✅ (whole-DB) | **None.** |
| G5 | "Active branch" selection on device | ⚠️ partial | Generalize the acting-user pattern → an active-branch state + selector. |
| G6 | Branch-scoped reads / branch-stamped writes | ⚠️ partial | Add optional `branchId` to repo reads (template: `accountantId`); stamp active branch on create. |
| G7 | Per-branch receipt numbering | ❌ (global) | Decision D-3: scope `getNextReceiptNumber` by branch (recommended) or keep global. |
| G8 | Backend per-branch + consolidated stats | ⚠️ partial | Add optional `branchId` to `buildDashboard`/`getMyStats` (template: `accountantId`). |
| G9 | Branch filter/count in panels; branches data tab | ❌ | Add to admin SPA + owner panel (template: accountant filter/count + `accountants` tab). |
| G10 | Migration of existing single-branch owners | ❌ | Auto-create **Main Branch**, assign legacy rows, re-enqueue for sync. |
| G11 | Branch isolation + cross-branch consolidation rules | ❌ | Define + enforce (this spec, §7–8). |

**Conclusion:** the smallest possible change is a **1:1 reuse of the accountant pattern** plus a migration. No engine, auth-protocol, backup, or architecture change is required.

---

## 6. Data ownership model *(required)*

```
Organization (cloud account / JWT / server mirror / moldati.db)   ← unchanged, the security & ownership boundary
  ├── owns →  Branches[]            (new synced entity)
  ├── owns →  Accountants[]         (existing synced sub-users — org-level)
  └── owns →  Business records      (each now carries branch_id  AND  accountant_id)
                 every record belongs to exactly one Branch (branch_id) within the org
```

- **The organization remains the only security/ownership boundary.** Branches do **not** create a new tenant; they are an *intra-account partition*. All branch data still lives under one JWT, one mirror, one DB file. This is what keeps the change additive and the backend/auth untouched.
- **A record's owner = the organization; its partition = its `branch_id`.** `branch_id == null` ⇒ Main Branch (legacy/default).
- **Branches and accountants are orthogonal axes.** A receipt has *both* `branch_id` (which branch) and `accountant_id` (who collected). Reports can slice by either or both.

## 7. Branch isolation rules *(required)*

1. **Every business record belongs to exactly one branch** (`branch_id`, defaulting to Main Branch).
2. **Reads are scoped to the active branch** for everyone except the Owner in consolidated mode.
3. **Writes stamp the active branch.** Creating a board/circuit/subscriber/receipt/expense/price assigns the device's active `branch_id`.
4. **No cross-branch leakage in branch mode:** while a branch is active, lists, dashboards, payment history, and reports show only that branch's rows. (Shared-vs-scoped semantics for boards/subscribers are inherited from the accountant decision and applied *within* a branch.)
5. **Receipt numbering** is unique **within a branch** (Decision D-3 recommended) so each branch has a clean sequence.
6. **Branch management (create/rename/disable) is Owner-only.** Accountants cannot create or switch organization-level branches (Decision D-2).
7. **Monthly price** is per-branch (each branch may price differently) — `monthly_prices` PK changes from `month` to `(month, branch_id)` conceptually; see plan §2 for the backward-compatible approach.

## 8. Consolidated reporting *(required)*

- The Owner has an **"All branches"** selection (the consolidated mode). In this mode no `branch_id` filter is applied and every figure (subscribers, collected, expenses, paid/unpaid, net) aggregates across all branches.
- Selecting a specific branch scopes every figure to that branch.
- The Owner panel + Reports screen gain a **branch picker** (All / Main / A / B / C) exactly like the accountant filter, and a **branch count** card.
- The Admin panel gains a **per-branch filter** and a **branches** data tab so support can inspect any owner's branches.
- Consolidated + per-branch can compose with the existing accountant filter (e.g. "Branch A, accountant Ahmed").

---

## 9. User scenarios

- **S1 — Owner creates branches.** Owner opens *Branches* (new screen), adds "Branch A/B/C". Existing data is already under "Main Branch".
- **S2 — Owner works in a branch.** Owner selects an active branch; the whole app (dashboard, boards, subscribers, pricing, expenses, reports) now reflects that branch. Creating data tags it to that branch.
- **S3 — Owner consolidated view.** Owner selects *All branches* in Reports/dashboard and sees organization-wide totals.
- **S4 — Accountant in a branch.** An accountant is bound to a home branch (Decision D-2); on sign-in their active branch is fixed to it; they collect payments tagged with `branch_id` (their branch) + `accountant_id` (themselves).
- **S5 — Offline.** All of S1–S4 work fully offline; branch data syncs when online and is included in cloud backup with no extra steps.
- **S6 — Existing customer upgrades.** App update runs v4→v5; a "Main Branch" appears containing all prior data; the user sees no behavioral change until they add a second branch.

## 10. Functional requirements (by layer)

- **Flutter app:** branch model/repo; active-branch state + persisted selection; branch selector (app bar) + Branches management screen (owner-only); branch-scoped reads + branch-stamped writes; per-branch receipt numbering; re-scope controllers on branch switch.
- **Owner dashboard (panel `#/my`):** branch picker (All + each) + branch count card; per-branch and consolidated figures; composes with accountant filter.
- **Admin dashboard:** `branches` synced-data tab (list/search), branch count in stats, optional per-branch filter on a user's data + dashboard.
- **Authentication:** unchanged protocol; branch selection is local state layered on the existing session (no new login, no new token claim required).
- **Authorization/permissions:** branch CRUD + switching = Owner-only; accountant bound to a branch; see permission model (plan §6).
- **SQLite:** v4→v5 migration; `branches` table; `branch_id` on 7 tables; Main-Branch backfill.
- **MongoDB backend:** `branches` flows into the existing mirror; `buildDashboard`/`getMyStats` accept `?branchId`; admin/account data endpoints branch-aware; **no schema change to `SyncRecord`**.
- **Sync engine:** **no change** (whole-row push + replace pull already carry `branch_id` and the `branches` table).
- **Offline mode:** branch create/select/scope all work offline; selection persisted.
- **Online sync:** branch rows + `branch_id` columns push/pull like any other synced data.
- **Cloud backup:** **no change** (whole `moldati.db` already contains branches).
- **Reporting:** per-branch + consolidated; composes with accountant scope.
- **Migration:** §plan-4; backward compatible; idempotent.

## 11. Non-functional requirements

- **Backward compatibility:** an un-migrated/older client (no branch awareness) reads all rows regardless of `branch_id` ⇒ behaves exactly as today (effectively consolidated). A migrated client with a single (Main) branch behaves exactly as today.
- **No refactor / no rename:** all additions are new columns, a new table, new optional params, and new screens. Existing signatures keep working (new params are optional, default = consolidated).
- **Offline-first preserved:** no new online dependency; branch logic is local + synced like accountants.

## 12. Acceptance criteria (high level)

1. Fresh install (v5): one **Main Branch** exists; behavior identical to today.
2. Existing install upgrades v4→v5: a Main Branch is created and **all prior rows** are assigned to it and appear under it; no data loss; no duplicate.
3. Owner can create/rename/disable branches (owner-only) and switch active branch; an accountant cannot.
4. With Branch A active, only Branch A data shows everywhere; creating data tags Branch A.
5. "All branches" shows correct consolidated totals = sum of per-branch.
6. Receipt numbers are unique within each branch (per Decision D-3).
7. Branch data syncs to the mirror; the owner panel branch filter returns correct per-branch and consolidated figures; the admin panel lists branches.
8. Cloud backup → restore preserves all branches and `branch_id` values.
9. All existing automated tests stay green; new branch tests prove isolation, consolidation, migration, and per-branch numbering.
10. Rolling back to the pre-branch app leaves data intact and readable (branch_id ignored).

## 13. Open decisions (require Owner sign-off)

- **D-1 — Shared vs per-branch infrastructure within a branch.** Recommended: boards/circuits/subscribers are **per-branch** (a branch is a separate location with its own boards). Receipts/expenses already per-accountant; now also per-branch.
- **D-2 — Accountant ↔ branch binding.** Recommended: each accountant is bound to **one home branch** (`branch_id` on `accountants`/`users`); their active branch is fixed. Alternative: accountants are org-wide and pick a branch.
- **D-3 — Receipt numbering.** Recommended: **per-branch** sequence (`getNextReceiptNumber(branchId)`); keeps each branch's receipts clean. Alternative: keep global.
- **D-4 — Monthly price.** Recommended: **per-branch** price (`monthly_prices` keyed by `(month, branch_id)`). Alternative: org-global price shared by all branches.

> Defaults above are assumed by `plan.md`/`tasks.md`; changing a decision changes only the corresponding task, not the overall design.
