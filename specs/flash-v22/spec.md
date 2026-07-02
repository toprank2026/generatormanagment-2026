# Flash v22 — Verification & polish batch (search, status dots, board payments, sync coverage, ordering, accountant separation, logout cleanup, dialog audit)

## Scope guard (from the request, verbatim intent)
**Do NOT change business logic, backend architecture, DB structure, sync strategy, or any
working behavior.** Fix/verify within the Flutter app layer; admin/owner panel + backend get
only the *suitable* (minimal, display-level) modifications if an item requires them.
Sync engine (outbox/triggers/drain) is untouchable per CLAUDE.md.

## Items

### 1. Search works in ALL subscriber lists
Verify (and fix where broken) the search box filters correctly in:
- All-subscribers list
- Paid list, Unpaid list (status-filtered lists)
- Subscribers reached through a Board (board-filtered list)
Search must compose with the active filters (status + board + category tab + branch) and
reset pagination to page 1 (canonical pattern).

### 2. Payment status indicator in all subscriber lists
Every subscriber row/card in every list shows a paid/unpaid indicator for the selected month:
- **Green = paid**, **Red = unpaid** (derived status — coverage = paid_amount + discount_value,
  same rule as `getByPaymentStatus` / `getDueAmount`; partial payment counts as unpaid).
- Must not break pagination performance (status resolved via the existing derived-status SQL,
  not per-row N+1 queries).

### 3. Collect payment via Boards screen path
Opening a subscriber through Boards → (circuits) → subscribers must allow payment collection
exactly like the Home path (same collect dialog, same month, accountant-only billing rule).
Verify the flow passes the right month/branch context and refreshes the list after collection.

### 4. Sync coverage for ALL data-modifying operations
Verify every mutation goes through repositories → SQLite (so the v2 outbox triggers capture it)
AND that a push is *nudged* after user-visible mutations (payments, subscriber/board/circuit
add/edit/delete, expenses, prices, settlements, refunds). No direct DB writes that bypass
triggers; no mutation path that leaves `pendingCount` stale without an auto-sync attempt.
**Do not touch the sync engine itself** — only wrapper-level "kick a sync after mutation".

### 5. Chronological ordering in all subscriber lists
All subscriber lists order by **creation date** (`created_at ASC, rowid ASC` — stable, language-
independent), replacing any `name`-based ordering (Arabic collation unreliable). Applies to:
all/paid/unpaid lists, board-scoped lists, search results.

### 6. Accountant data separation in reports (collections + expenses)
Admin/owner can view EACH accountant's collections and expenses independently, with no
overlap: reports screen gets (or is verified to have) a per-accountant filter driven by
`accountant_id` attribution on receipts/expenses. Accountants keep seeing only their own.
Backend/admin panel: only if a display-level tweak is needed (mirror is push-only).

### 7. Logout = complete local cleanup + progress indicator
User-initiated logout (after the v17 unsynced-guard passes) must wipe:
- SQLite business data + outbox (`deleteLocalData()` / `wipeAllTables()`)
- JWT + session cache (`SecureStore` token, `SessionCache`) — install-id persists by design
- SharedPreferences state that could leak across accounts (selected month/branch context,
  cached counters) — printer hardware prefs may persist (device-level, not account-level)
- In-memory GetX controller state (so the next login starts clean without app restart)
Show a blocking progress indicator during the wipe (respecting the SyncProgress gotcha:
`barrierDismissible:false`, close BEFORE snackbars, no PopScope(canPop:false)).
The v17 rule stays: logout still refuses while unsynced data exists / sync running.

### 9. Show the linked circuit on subscriber rows
Every subscriber row/card in the subscriber lists also displays the **circuit (جوزة)**
the subscriber is linked to (name/number), resolved without N+1 queries (batch/JOIN or a
cached id→name map). Applies to all lists: all/paid/unpaid/board-scoped/search.

### 8. App-wide loading/dialog audit
Every `Get.dialog` / loading overlay / `isLoading` flag:
- is dismissed on BOTH success and failure (try/finally)
- never stacks or hangs (latch-guarded where reentrant)
- disposes controllers/`ScrollController`s properly (no leaks)
- no snackbar-before-close (breaks `Get.isDialogOpen`)

## Acceptance
- `flutter analyze` 0 errors / 0 warnings; `flutter test` all green (translation parity incl.
  any new strings in BOTH maps); backend `npm test` green if backend touched.
- Change table produced; app pointed at Flash API (default); release APK built.
