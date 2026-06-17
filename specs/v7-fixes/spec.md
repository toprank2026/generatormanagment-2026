# Spec — v7 Fix Batch (Moldati Owner)

Source: owner to-do list (2026-06-17). Scope = Flutter app + admin panel + owner panel + backend, kept consistent.

Status legend: ✅ already satisfied (verify only) · 🟡 partial (gap noted) · 🔴 new work.

## Requirements

### R1 — Duplicate board/feed names rejected 🔴
Boards (لوحات) and circuits/feeds (جوزة) must not allow duplicate names **within a branch** (circuits: within a board). Mirrors existing subscriber per-branch unique-name behavior. App-layer validation only (no DB constraint), surfaced as a red snackbar; the dialog stays open on failure.

### R2 — Monthly pricing is month-scoped + everyone unpaid by default ✅ (verify)
Adding a monthly price applies only to that month, and all subscribers start **unpaid** for the new month. Already true: `monthly_prices` PK is `<month>|<branchId>|<category>`, and paid/unpaid is *derived* (`getByPaymentStatus`) — once a non-zero price exists and no receipts are collected, due > 0 ⇒ everyone unpaid. No code change; add a regression test that locks this in.

### R3 — "Add Subscriber" only on the All Subscribers screen 🟡
The Add-Subscriber FAB currently renders for every variant of `SubscribersScreen`. Hide it when `widget.filter != null` (i.e. Paid / Unpaid lists). All-list (and board-scoped list) keep it.

### R4 — Three required pricing categories (Gold / Regular / Commercial) 🟡
Due-calc, collection, snapshots already work identically for all three categories. Gap: the Monthly Pricing screen silently skips empty/invalid fields. Make all three inputs **required + numeric (> 0)** via a `Form`; abort the save (no partial write) if any is missing; save all three atomically.

### R5 — Category tab bar on All / Paid / Unpaid screens 🔴
Add a `TabBar` (All · Gold · Regular · Commercial) to `SubscribersScreen`. Filter by category. Thread an optional `category` through `CoreController.loadSubscribers`/`loadFilteredSubscribers`/`loadMore` and `SubscriberRepository.getAll` (named where — easy) + `getByPaymentStatus` (raw positional-arg SQL — careful: add the arg in the same position as the clause).

### R6 — Subscriber opened from Home uses Home's month 🔴 (part of R9)
Opening a subscriber must use the globally-selected month. Today `SubscriberDetailScreen.initState` hard-resets the month to `now()`. Fixed by the global month source (R9).

### R7 — Branch switch clears local/cached data, then pulls from server 🔴
On switching branch (online + sync enabled): push pending → clear local synced data → pull account mirror → reload all controllers, behind a **blocking progress overlay** so a large pull cannot crash the UI. Offline / sync-disabled: fall back to a local-only switch with a notice (offline-first must not strand the user with an empty branch). Pull is account-wide; the active-branch filter scopes the UI to the selected branch (true server-side per-branch pull is deferred — branch_id lives inside the opaque mirror `data`).

### R7b — Loading UI for large sync push & pull 🔴
Large push and pull (including the R7 switch and the dashboard pull-latest) show a non-dismissible progress overlay with status text so the app stays responsive.

### R8 — Accountant is a real backend sub-account, logs in via Login screen 🔴
Today an accountant is a local SQLite credential (`users`) + a synced identity (`accountants`), entered via an in-app offline profile switch. New model:
- Backend `User` gains role `accountant`, an `owner` ref (parent admin/owner account), a `branchId`, a `permissions[]`, and a `localId` (the app-side accountant UUID, for attribution round-trip).
- Owner creates an accountant from the app → registers a **backend** sub-account (online) tied to a branch, in addition to the existing local identity row (kept for mirror attribution).
- The accountant logs in through the normal **Login screen** (`/api/auth/login`, bcrypt). Accountant sessions do **not** consume the owner's device limit and **inherit the owner's subscription/features**.
- Sync/data scoping uses an **effective-owner id** (`role==='accountant' ? owner : _id`) so the accountant reads/writes the owner's mirror. After login the app pulls the owner's data for its branch.

### R9 — Month selection only on Monthly Pricing; Home shows it read-only; propagated everywhere 🔴
Create a permanent `MonthController` (mirrors `BranchController`) as the single source of truth. Monthly Pricing screen is the **only** place that mutates it. Dashboard banner month becomes **read-only** (no picker). Dashboard stats, subscriber detail, payment history, billing, and the paid/unpaid filtered lists all read the shared month and react via `ever()`.

## Panels / backend consistency
- Mirror is whole-row, schema-agnostic ⇒ category / branch_id / accountant_id ride along automatically.
- Panel: add a **category** column to `SYNC_COLUMNS.monthly_prices` (and `category_snapshot` to receipts); add `category` to `SEARCH_FIELDS.monthly_prices`.
- R8 needs real backend modeling + owner-panel/admin visibility of accountant sub-accounts.
- Doc: CLAUDE.md says "SQLite version 2" — it is actually **version 6**; correct it.

## Out of scope / deferred
- Server-side per-branch pull (promoting branch_id to a top-level SyncRecord column + backfill).
- Backfill of pre-v6 mirror rows lacking `category`.
- Printing the category label on receipts (optional polish; charged price is already correct).
