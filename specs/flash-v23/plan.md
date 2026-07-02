# Flash v23 — PLAN (execution order, project knowledge, verification)

> Companion to `spec.md`. Read both fully before editing. This file tells you HOW to execute
> safely in THIS repo; `spec.md` tells you WHAT to build; `tasks.md` is the checklist.

## A. Execution order (dependency-driven)

Work in this order — later phases depend on earlier ones and the riskiest SQL work happens
while context is freshest:

| Phase | Scope | Spec § | Why this order |
|---|---|---|---|
| 1 | Repo/SQL work: paid-unpaid pagination params usage, `getByBoard` limit/offset, `pricesForMonthByBranch` + `ampsByBranchCategory` | 8.1, 8.2, 2.3 | Touches `_paymentStatusFrom` siblings — do it first, verify with tests immediately (R-SQL-ARGS) |
| 2 | Controller/UI pagination: filtered + board list paging, settlements loadMore | 8.1–8.3 | Depends on phase 1 signatures |
| 3 | Reports fixes (app): atomic loadReport, consolidated expected, payments refunded style, donut center, dead GaugeChart, stale texts | 2.2 (app text), 2.3–2.6 | Isolated to reports files |
| 4 | Reports fixes (backend+SPA): `expected` in payload + SPA use, unpriced-month=UNPAID | 2.1, 2.2 | Backend tests written alongside |
| 5 | Password flows: EditAccountScreen current-password, backend WRONG_PASSWORD ×2, accountant-reset owner-auth | 3.2, 3.3 | App+backend pairs — do each pair together |
| 6 | Import/export polish | 3.1 | Independent |
| 7 | Month picker (numeric) + expenses date format | 5 | Independent, pure UI |
| 8 | Printers: QR constants, SafeArea sheets, await alignment, test print | 6 | Independent, pure UI + services |
| 9 | Device binding: error code threading, recover-device wiring, current-device label, cancel-unbind | 4 | Touches AuthController login tail — refactor shared tail carefully |
| 10 | Owner panel: expenses filter/columns/total + generic entity details | 7, 9 | SPA + additive backend params |
| 11 | Conflict hardening: profile-switch guard, tombstone delete | 10 | Last — needs calm review of auth/sync wrappers |
| 12 | Full verification + MILESTONES + change table + release APK | 11 | Always last |

After EACH phase: `flutter analyze` must be 0/0 before moving on (backend phases: `node --check`
on edited files, `npm test` after phases 4, 5, 10, 11).

## B. Project knowledge you MUST internalize (hard-won, all verified)

### B1. GetX landmines (these have each caused real production bugs here)
- `Obx(() => cond ? A : B)` where `cond` short-circuits before reading an observable →
  **grey ErrorWidget over the whole screen in release builds**. Always read the observable
  first (`auth.isAdmin` is safe today because it reads `currentUser.value` internally — don't
  reorder it).
- `Get.back()` while ANY snackbar is visible closes the snackbar and RETURNS (GetX 4.7.3
  `extension_navigation.dart:825-828`) — the dialog stays open. Dialogs opened with a builder
  context must close via `Navigator.of(context).pop(...)`; confirm-dialogs opened via
  `Get.defaultDialog` close via `Navigator.of(context, rootNavigator: true).pop()` (v22
  pattern — see `subscriber_detail_screen._showDeleteConfirm` for the reference
  implementation).
- Show snackbars ONLY AFTER closing dialogs/overlays. `SyncProgress` (blocking overlay) must
  be hidden in `finally`, never wrapped in `PopScope(canPop:false)`.
- Busy latches: every awaited write behind a dialog button needs `busy` state + disabled
  button + `if (context.mounted)` around post-await UI calls (reference:
  `accountants_screen._showEditDialog` after v22).

### B2. SQL discipline
- `_paymentStatusFrom` positional args: inner receipts `month[,branch][,receiptAccountant]`,
  mp `month`, outer `[accountant][branch][category][query×2]`. When you add pagination usage
  you are NOT changing this SQL — only passing the existing `limit/offset` params. If you DO
  touch the SQL, update the doc comment at core_repositories.dart:527-529 (it is stale re: v22
  params — fixing that comment is welcome).
- `getByBoard` gains `int? limit, int? offset` — mirror `getAll`'s implementation
  (query() named params, `limit: limit, offset: offset` only when non-null → keep current
  behavior for existing callers that don't pass them).
- New aggregates (`ampsByBranchCategory`, `pricesForMonthByBranch`) are ADDITIVE methods —
  never modify the existing `ampsByCategory`/`pricesForMonth`.

### B3. Sync engine fence (R-ENGINE)
Files you may READ but never MODIFY: `lib/data/db_helper.dart` (triggers/outbox/schema),
`lib/core/sync_service.dart`, `backend/src/controllers/syncController.js` push/pull internals.
The tombstone fix (spec §10.2) lives in `adminController.deleteUserData` — that is NOT the
engine; it just writes the same document shape the engine already understands.

### B4. Translation parity
`test/widget_test.dart` fails if a key exists in one map only. Every new key in spec.md is
listed in tasks.md — add each to BOTH maps in `lib/utils/translations.dart` in the same edit.
Search for existing keys before inventing new ones (`'wrong_password'`, `'this_device'`,
`'logout_blocked_unsynced'`, `'refunded'` likely exist — verify with grep).

### B5. Print services
- `PrinterPrefs` is a static cache primed by `load()` at startup; print services read it
  synchronously. New printer-related settings MUST go through it.
- USB timeouts are layered: Dart `.timeout(75s)` > native 60s permission watchdog — keep the
  order. `UsbPrintService._busy` throws `Exception('usb_busy')` on overlap — any new print
  entry point (the test-print tile) must catch and surface it like the existing dispatchers.
- QR constants are self-contained: the centering math derives from the constant; change the
  number only.

### B6. Backend conventions
- Endpoint contract lives in `backend/API_CONTRACT.md` — update it for every changed/extended
  endpoint (profile currentPassword, accountants ownerPassword, device?current=, expenses
  month/totalAmount, recover-device app usage note).
- Error shape: `res.status(code).json({ message, code })` — reuse existing codes where
  possible; new code introduced by this batch: `WRONG_PASSWORD` (401).
- Tests: `node --test` under `backend/test/`, in-memory Mongo; follow an existing test file's
  structure (e.g. `recover_device.test.mjs`) — each new backend behavior in spec.md names its
  required test.
- The SPA (`backend/public/admin/index.html`) is ONE big vanilla-JS file, Arabic-only strings,
  hash routing via the `routes` table (~:1030), API wrappers in the `API` object (~:578-607).
  New dash payload fields need graceful fallbacks for older backends (existing pattern).

### B7. Device binding facts (don't re-derive)
- Matching is deviceId-FIRST (OS-stable SSAID/IDFV); installId is a fallback. Reinstalls
  refresh, they don't consume slots.
- Accountants are device-exempt at login. Branch accounts are NOT exempt.
- A 2xx login response is the ONLY place a token is stored; DEVICE_LIMIT 403 stores nothing.
- `recover-device` evicts by `lastSeen` LRU and is owner/admin-role only.

### B8. Multi-agent usage (if you parallelize)
- Read-only mapping and adversarial review fan-outs are encouraged; EDITING agents must work
  on disjoint files and are FORBIDDEN from running git commands (R-GIT). Shared files
  (core_repositories, core_controller, auth_controller, settings_controller, translations,
  index.html) must be edited by the main session serially.

## C. Verification recipe (per phase and final)

```bash
# Flutter (after every phase)
flutter analyze                       # must be 0 errors / 0 warnings
flutter test                          # all green; parity test guards translations

# Backend (after phases 4, 5, 10, 11)
node --check backend/src/controllers/<edited>.js
cd backend && npm test

# Scale smoke (after phase 2; requires a device/emulator)
#   Settings → Local backup → Import → tools/TestData.backup (password 1234)
#   then: All/Paid/Unpaid/board lists scroll+search; reports open; let the big push settle.

# Final
flutter build apk --release           # ships on Flash API by default
```

Definition of done = spec.md §11 checklist complete, change table written, commit HELD until
the user confirms ("commit and push" per the established workflow).
