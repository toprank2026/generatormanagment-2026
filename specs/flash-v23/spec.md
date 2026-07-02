# Flash v23 — Quality & Professionalism Batch (SPEC)

> **Execution target:** Claude Opus 4.8, working in this repository with `CLAUDE.md` loaded.
> **Read this whole file + `plan.md` + `tasks.md` BEFORE touching any code.**
> Every anchor below was verified against the working tree at commit `0ec2670` (Flash v22).

---

## 0. What this app is (30-second primer)

"Moldati Owner" / **Flash** — a Flutter + GetX app for managing a private electricity-generator
business (subscribers, boards, circuits/جوزة, per-amp monthly billing, expenses, thermal-printed
receipts), bilingual `ar_AR`/`en_US`, **offline-first** with a per-account server mirror
(`backend/` Node/Express/Mongo; admin+owner SPA in `backend/public/admin/index.html`).
Strict MVC: **View → Controller → Repository → DbHelper (SQLite)**. All local writes are captured
by SQLite triggers into `sync_outbox` and pushed to `/api/sync/push`; the mirror is what the
admin/owner panel reads. The production API is `https://generator.ecommerceflash.com` (the default
in `lib/core/api_config.dart` — a plain `flutter build apk --release` ships pointed at it).

## 1. NON-NEGOTIABLE RULES (violating any of these = failed batch)

1. **R-PRESERVE (user's item 9):** Do NOT change business logic, DB schema, backend architecture,
   sync strategy, or ANY working behavior. Only fix what this spec names. The owner runs a live
   business on this system with real customers.
2. **R-ENGINE:** The sync engine is UNTOUCHABLE: `DbHelper._createSyncInfra` triggers/outbox,
   `lib/core/sync_service.dart` push/pull drain, `backend/src/controllers/syncController.js`
   push/pull core. Fixes live at the WRAPPER level (controllers, guards, UI) or in non-sync
   backend endpoints.
3. **R-SQL-ARGS:** `SubscriberRepository._paymentStatusFrom` (lib/data/repositories/
   core_repositories.dart:530-593) and its siblings are RAW POSITIONAL-ARG SQL. Every `?`'s arg
   must be appended in exactly matching order: inner receipts `month[,branch][,receiptAccountant]`,
   `mp` join `month`, outer `[accountant][branch][category][query×2]`. This SQL is shared by
   `getByPaymentStatus`, `countByPaymentStatus`, `paidSubscriberIds` — a mistake ripples into
   subscriber lists, dots, and reports.
4. **R-I18N:** Every new user-facing string goes in BOTH `en_US` and `ar_AR` maps in
   `lib/utils/translations.dart`, or `test/widget_test.dart` parity tests fail. The SPA panel is
   Arabic-only hardcoded strings (no parity test there).
5. **R-GETX:** (a) An `Obx` builder must read an observable BEFORE any short-circuit condition.
   (b) `Get.back()` while a snackbar is open closes the SNACKBAR, not the dialog — close dialogs
   via `Navigator.of(context).pop()` on the dialog's own context (the v22 pattern), and show
   snackbars only AFTER the close. (c) Never wrap `Get.dialog` in `PopScope(canPop:false)`.
6. **R-GIT:** If you spawn parallel agents, they must NEVER run git state-changing commands
   (a prior run lost work to an agent's `git reset`). Coupled edits (shared controllers/repos)
   are done directly by the main session, not by parallel agents.
7. **R-VERIFY:** Batch is done only when: `flutter analyze` = 0 errors/0 warnings;
   `flutter test` all green; `cd backend && npm test` all green (add tests for changed backend
   endpoints); release APK built (`flutter build apk --release`, ships on Flash API by default);
   `MILESTONES.md` entry added; change table written for the user. Commit ONLY after the user
   confirms testing (hold the commit; user says "commit and push").

---

## 2. ITEM 1 — Reports: fix real errors, keep semantics

The v23 mapping audit found these CONFIRMED defects. Fix exactly these; the "known caveats" at
the end of this section are DOCUMENTED semantics — do NOT "fix" them.

### 2.1 Owner-panel "expected" card is arithmetically WRONG (mixed tariffs)
- `backend/src/controllers/accountController.js` `buildDashboard` computes a category-aware
  `expected` internally (:178, :192) but never returns it; the SPA recomputes
  `expected = totalAmps × pricePerAmp(standard)` at `backend/public/admin/index.html:2473` —
  wrong whenever gold/commercial tariffs differ, and inconsistent with its own المتبقي card
  (:2492 uses the category-aware `totalDue`).
- **Fix:** add `expected` to the buildDashboard payload (:213-237); in the SPA use
  `dash.expected` with a fallback to the old computation when the field is absent (the SPA
  already follows this optional-field pattern for older backends). Add/extend a backend test
  (`backend/test/`) asserting `expected` equals Σ ampsByCategory×price for a mixed-tariff seed.

### 2.2 App ↔ panel divergence on an UNPRICED month
- App SQL: missing `(month,branch,category)` price row ⇒ subscriber counted **UNPAID**
  (core_repositories.dart:590, deliberate audit fix). Backend `buildDashboard`: missing price ⇒
  due=0 ⇒ counted **PAID** (accountController.js:190-198). Same month shows `0 paid / N unpaid`
  in-app vs `N paid / 0 unpaid` on the panel.
- **Fix:** align the BACKEND to the app rule (app is the source of truth): a subscriber whose
  category has no price row for the month counts UNPAID in `paidCount`/`paidByCategory`.
  Update the stale comment at accountController.js:52-53. Backend test: unpriced month ⇒
  paidCount=0.
- Also update the STALE app-side text: the banner comment at
  `lib/views/screens/reports_screen.dart:96-98` and the `'no_price_for_month'` translation
  (translations.dart:220 en / :695 ar) still say "nothing is due / everyone shows as paid" —
  since the audit fix the truth is "subscribers count as UNPAID until a price is set".
  Reword BOTH language values accordingly (R-I18N).

### 2.3 Consolidated (All-branches) app view: last-row-wins price collapse
- `MonthlyPriceRepository.pricesForMonth(month, branchId: null)` flattens all branches into one
  `{category: price}` map, last row wins (billing_repositories.dart:51-55). ReportsController
  then computes a WRONG `expectedTotal` for multi-branch owners with different tariffs
  (reports_controller.dart:114-123). The backend already fixed this exact bug with a
  `'<branch>|<category>'` keyed map (accountController.js:113-135).
- **Fix (app):** in the consolidated case ONLY (`_branchScope == null`), compute
  `expectedTotal` per-branch: add a NEW repo method (e.g.
  `MonthlyPriceRepository.pricesForMonthByBranch(month)` returning
  `Map<branchId, Map<category, price>>` — do NOT change `pricesForMonth`'s signature/behavior,
  other callers depend on it) and a branch-aware amps aggregate
  (`SubscriberRepository.ampsByBranchCategory()` — GROUP BY branch_id, category), then
  `expected = Σ_branch Σ_cat amps[b][c] × price[b][c]`. When a single branch is active,
  keep the existing math untouched. Check whether `DashboardController` has the same
  consolidated-expected math and fix it the same way IF it does (verify first; do not touch
  otherwise).

### 2.4 Payments list shows refunded receipts indistinguishably
- `ReceiptRepository.getByMonth` has no status filter (billing_repositories.dart:169-191);
  `payments_screen.dart:135-141` renders every `paidAmount` bold green. `payment_history_screen`
  already has the refunded grey style (:275, :318-323) to copy.
- **Fix (display-only):** do NOT add a status filter to `getByMonth` (callers audit risk;
  R-PRESERVE). Instead copy the refunded styling into `payments_screen` rows: refunded rows get
  the greyed style + a small 'refunded'.tr marker (key exists? verify; if new — both maps).

### 2.5 loadReport partial-failure leaves mixed stale/new figures
- All 9 figures assign one-by-one inside a single try (reports_controller.dart:96-202); a mid-way
  throw is swallowed by `print()` — screen shows a mix of old and new months.
- **Fix:** compute all figures into LOCAL variables first, assign to the `.obs` fields only after
  the whole computation succeeds (single atomic "commit" block at the end of the try); on catch,
  keep previous values AND show one error snackbar `'report_failed'` (new key, both maps).

### 2.6 Optional polish (do it — small, display-only)
- Donut center under an active accountant filter shows branch-wide `totalSubscribers`
  (reports_screen.dart:144-146) while the segments are filter-scoped: change the center text to
  `paidCount + unpaidCount` (always equals the visible segments; no behavior change when no
  filter).
- Delete dead `GaugeChart` (report_charts.dart:22-140, zero references since v14) — verified
  orphan; removal is safe.

### 2.7 DOCUMENTED semantics — DO NOT change (list them in the change table as "reviewed, by design")
- `remainingTotal` under an accountant filter is inflated (expected stays branch-wide) — matches
  the backend panel; there is no per-accountant "expected" concept in the data model.
- `netProfit` mixes billing-month revenue with calendar-month expenses — mirrored identically
  on the backend; changing it would rewrite historical reports (R-PRESERVE).
- Historical months drift with current subscriber amps/category (reports aggregate current rows,
  not receipt snapshots) — identical on backend; snapshot-based reports are out of scope.
- Reports month is intentionally separate state from the global `MonthController` (R9 invariant:
  the global month is mutated only from Monthly Pricing).
- `pricePerAmp` = standard category as representative (banner + header only; expected is
  category-aware).

---

## 3. ITEM 2 — Import/Export + password flows

### 3.1 Import/export quality (`SettingsController` + `LocalBackupService`)
Current state: export = owner-password-gated (verifyOwnerPassword) SHA256-CTR encrypted
`.backup` of boards+circuits+subscribers, shared via share sheet (settings_controller.dart:441-467);
import = FilePicker with NO extension filter, MAC-verified password, upsert-replace, poke + reload
(:469-518). Fix:
1. **FilePicker extension filter:** `pickFiles(type: FileType.custom, allowedExtensions: ['backup'], dialogTitle: ...)`
   so users can't pick random files (import path :474-475).
2. **Distinguish error cases:** today BOTH `FormatException('not_a_valid_backup')` and
   `('wrong_password_or_corrupted')` surface as the same `'backup_wrong_password'` snackbar
   (:500-511). Split the catch on `e.message` and show `'not_a_valid_backup'` (new key, both
   maps: "This file is not a valid Flash backup" / Arabic equivalent) vs the existing
   wrong-password message.
3. **Password dialog validation:** `_askBackupPassword` (:412-429) confirm button must be
   disabled until the field is non-empty (a StatefulBuilder local); trim the returned value.
4. **Success detail:** after import, the snackbar shows only a total; extend to per-table counts
   (e.g. "boards 20 · circuits 60 · subscribers 1000" — numeric, no new translation needed
   beyond the existing labels; reuse `'boards'`/`'circuits'`/`'subscribers_title'` keys).
5. **Export filename:** append the date: `<safeName>-yyyyMMdd.backup`
   (local_backup_service.dart:80-83) — pure filename change, format/envelope UNTOUCHED
   (v:1 files must keep importing).
6. **Trim consistency:** trim passwords at all three entry points (backup dialog, accountant
   edit dialog already trims, `EditAccountScreen` sends untrimmed `_password.text` at
   edit_account_screen.dart:62 — trim it).

### 3.2 Admin (owner) self password change — require the CURRENT password
Current: `EditAccountScreen` (edit_account_screen.dart) has NO old-password field;
`PUT /api/account/profile` (accountController.js:406-455) changes the bcrypt hash on the JWT
alone. Fix (additive, both layers):
1. **App:** add a `current_password` field (obscured, `'current_password'` new key both maps)
   that is REQUIRED only when the new-password field is non-empty. Validation: new password
   length ≥ 4 (parity with accountant-create's rule, accountantAccountController.js:63-65).
2. **Backend (authoritative):** `updateMyProfile` accepts `currentPassword`; when `password` is
   being set, verify `bcrypt.compare(currentPassword, user.passwordHash)` → on mismatch respond
   `401 { code: 'WRONG_PASSWORD', message: ... }` and change nothing. Old clients that don't send
   `currentPassword` while setting a password must ALSO get 401 (that's the point of the fix).
   Backend test: change-with-wrong-old → 401; change-with-correct-old → 200 + new token works.
3. **App pre-check (UX):** before calling the API, if a local owner hash exists
   (`verifyOwnerPassword`, auth_controller.dart:753-758), pre-validate and show
   `'wrong_password'` immediately; REMEMBER the caveat: `verifyOwnerPassword` returns TRUE when
   no hash is stored — the backend check is the real gate.
4. **Error mapping:** surface the 401 WRONG_PASSWORD as `'wrong_password'.tr` (key exists),
   not the generic message.

### 3.3 Accountant password change by admin — require authorization
User's requirement: "requiring the old password before allowing access to change it to the new
password." The admin does not know the accountant's old password; the professional reading is:
**the admin must re-enter THEIR OWN password to authorize the reset.** Implement:
1. **App (`accountants_screen._showEditDialog`, :287+):** when the save is pressed AND the
   password field is non-empty, first show a small owner-password prompt (obscured field, title
   `'confirm_identity'` — new key both maps: "Confirm your password" / "أكد كلمة مرورك").
   Verify with `verifyOwnerPassword` when a hash exists; ALWAYS also send it to the backend
   (see 2). Cancel → abort the save, dialog stays open. Keep the existing v22 busy latch +
   Navigator.pop pattern (R-GETX).
2. **Backend (`PUT /api/account/accountants/:id`, accountantAccountController.js:120-135):**
   when `password` is present, require `ownerPassword` in the body and
   `bcrypt.compare(ownerPassword, req.user.passwordHash)` → mismatch/absent ⇒
   `401 WRONG_PASSWORD`, no changes applied. Non-password edits (name/active/permissions)
   need NO authorization change. Enforce new password length ≥ 4 (parity with create).
   Backend tests for both paths.
3. **Local mirror order note:** `SettingsController.updateAccountant` is backend-first then
   local (settings_controller.dart:283-296) — keep that order; the new 401 aborts before any
   local write, which is exactly right.

---

## 4. ITEM 3 — Device binding, professional lifecycle

Current model (all verified): fingerprint = installId (secure storage, survives normal logout) +
OS-stable deviceId (SSAID/IDFV); backend matches deviceId-FIRST so reinstalls refresh instead of
consuming a slot (devices.js:16-26); plans: trial/monthly=1 device, yearly=2; accountants are
fully device-exempt; wipe-logout unbinds + clears installId (online-gated); `recover-device`
endpoint exists, is tested, and has ZERO app callers. Fixes:

### 4.1 DEVICE_LIMIT shows as "account disabled" (critical UX bug)
- `login_screen.dart:48-49` maps ANY 403 to `'account_disabled'`; the `DEVICE_LIMIT` code in
  `ApiException.body` is discarded (api_client.dart:131-135).
- **Fix:** thread the error `code` through `AuthController.login`'s failure map (add
  `'code': e.code` — check ApiException exposes it; if not, parse from body) and in the login
  screen show a dedicated message for `DEVICE_LIMIT` (`'device_limit_msg'` new key both maps:
  "This account is already linked to another device" / Arabic) — then offer recovery (4.2).

### 4.2 Wire the existing `recover-device` endpoint (move-account-to-this-device)
- `POST /api/auth/recover-device` (authController.js:162-215; API_CONTRACT.md:108-123): validates
  credentials, evicts the least-recently-seen binding, binds this device, returns `{token, account}`.
- **Fix (app):** on a DEVICE_LIMIT login failure, show a dialog:
  `'device_limit_recover_q'` (new key both maps: "Move this account to this device? The other
  device will be unlinked.") → on confirm call a new
  `AuthRepository.recoverDevice(username, password)` (same request shape as login incl. the
  `device` object) → on success continue EXACTLY like a successful login (reuse the login
  post-processing: cache account, `_setAccount`, residue guard, pulls — factor the shared tail
  of `AuthController.login` into a private helper so both paths run identical code).
  Role note: the endpoint is owner/admin-only (accountants never hit DEVICE_LIMIT).
- **Backend lastSeen fairness (small, additive):** `/auth/me` should refresh the matching
  device's `lastSeen` (match via the SAME `sameDevice` util using a `X-Install-Id`/body? —
  simplest correct: refresh lastSeen inside `upsertDevice` calls only; if /auth/me has no device
  info, SKIP this sub-item entirely rather than invent a new header). Decide by reading
  `authController.me` — if no device fingerprint is available there, drop this sub-item (note it
  in the change table as "not feasible without contract change").

### 4.3 `(this device)` label never renders + own-device unbind guard
- `GET /api/device` serializes WITHOUT `currentDeviceId` (deviceController.js:9-12) so
  `current` is always false; the settings sheet (settings_screen.dart:692-701) can never label
  the current device, and users can silently unbind their own device.
- **Fix (backend):** `list()` must resolve the caller's current device: the app should send its
  `deviceId` as a query param (`GET /api/device?current=<deviceId>` — additive, old clients
  unaffected) and `serializeDevice(d, current)` accordingly. **Fix (app):**
  `DeviceRepository.list()` passes the collected deviceId; the sheet then shows
  `(this_device)` (key exists) and the unbind confirm for the CURRENT device gets a stronger
  warning line (`'unbind_current_warn'` new key both maps: "This is THIS device — you will be
  signed out of syncing until next login").
- Note: unbinding the current device does not kill the session (data routes don't check device
  membership — documented Phase-2 gap; do NOT add such checks now, R-PRESERVE).

### 4.4 Slot leak when the residue guard cancels a login
- `AuthController.login` binds server-side at `_auth.login()` (:300) BEFORE
  `_guardCrossAccountResidue` can cancel (:324-327); cancel calls `logout()` (non-wipe) which
  does NOT unbind — the aborted account keeps this device in its slot.
- **Fix:** in the cancel branch, before `logout()`, best-effort
  `DeviceRebind.apply(rebind: false)` (unbinds + clears installId; online is guaranteed here
  since login just succeeded). Keep it try/catch silent.

### 4.5 Reviewed, by design (document in change table; NO code change)
- v18 create-branch/create-accountant rebind confirm re-binds the same owner device (does not
  free a slot on the new account) — kept for its informational UX.
- Offline wipe-logout cannot unbind (silently skipped) — recovery now exists via 4.2.
- Deviceless web-panel login bypasses binding (documented Phase-2 monetization gap).
- Plan downgrade never evicts existing devices (refresh path skips the limit check).

---

## 5. ITEM 4 — Numeric month picker (Monthly Pricing screen)

Current: `showDatePicker` full DAY picker (monthly_pricing_screen.dart:185-207) — users must pick
an arbitrary day and see month NAMES in the Material dialog. Everywhere else the app already
displays the raw numeric `yyyy-MM`.

**Fix:** replace the `showDatePicker` call with a custom numeric month-year dialog:
- Layout: header row `[<]  2026  [>]` (year stepper, chevrons; RTL-safe — use explicit
  `Icons.chevron_left/right` with directional semantics like reports_screen.dart:266-268 does)
  above a `GridView.count(crossAxisCount: 4)` of 12 buttons labeled `1`..`12` (NUMERALS ONLY —
  the user explicitly wants "month six (6) instead of June").
- Selected month+year highlighted (current selection parsed from
  `controller.selectedMonth.value`).
- Tap a month ⇒ `Get.find<MonthController>().setMonth(DateFormat('yyyy-MM').format(DateTime(year, m)))`
  then `Navigator.of(context).pop()` (R-GETX close pattern). Bounds: years 2020–2030 (same as
  the old picker).
- The `MonthController.setMonth` contract is sacred (single mutation point, `yyyy-MM` string) —
  everything downstream re-binds automatically.
- New translation keys as needed (e.g. `'select_month'` if not present — check first) in BOTH maps.
- **Secondary numeric-date polish (same intent):** `expenses_screen.dart:315` uses
  `DateFormat('MMM d')` with NO locale → English month names inside the Arabic UI. Change to a
  numeric format `DateFormat('yyyy-MM-dd')`. Do NOT touch `payment_history_screen.dart:302`
  (already locale-aware) unless the user later asks.

---

## 6. ITEM 5 — Printers: lifecycle, QR size, safe-area sheets

### 6.1 QR size reduction ("slightly")
Three independent constants; change ALL of them:
- `lib/utils/bluetooth_print_service.dart:201` — `const double qr = 190;` → `160`.
- `lib/utils/usb_print_service.dart:284` — `const double qr = 190;` → `160`.
  (Centering/canvas math derives from the constant in both — no other edits needed.)
- `lib/utils/pdf_service.dart:109-114` — BarcodeWidget `width/height: 75` → `65`.

### 6.2 Bottom sheets must respect the system bottom inset (safe area)
`Get.bottomSheet` is called with no params and NO SafeArea in FOUR sheets in
`lib/views/screens/settings_screen.dart`: USB picker (:756-801), Bluetooth picker (:803-869),
local backup (:514-546), manage devices (:646-725).
**Fix each:** wrap the sheet's `Container` child in `SafeArea(top: false, child: ...)` AND give
the Container `padding: EdgeInsets.only(bottom: MediaQuery.of(Get.context!).viewPadding.bottom)`
is NOT needed if SafeArea is used — SafeArea alone suffices; keep the rounded top corners on the
OUTER container so the radius isn't clipped. For the Bluetooth sheet specifically, bound the
device list: wrap the `ListView.builder` in a `ConstrainedBox(maxHeight: Get.height * 0.5)` with
`shrinkWrap: true` retained, so long paired-device lists scroll instead of overflowing.

### 6.3 Printer lifecycle across screens (verify + harden, minimal edits)
Verified current design: BT reconnects inside `printReceipt` via `_ensureConnected` (2 attempts,
reads the saved address) — bluetooth_print_service.dart:59-161; USB opens/claims/closes per print
with a 60s native permission watchdog + 75s Dart timeout + `_busy` latch. Two print entry points:
`subscriber_detail_screen._handlePrint` (AWAITED, :356-416) and
`payment_history_screen._handlePrint` (`void async` fire-and-forget, :126-195).
**Fixes:**
1. **Align the two dispatchers:** make `payment_history_screen`'s post-collect call AWAIT
   `_handlePrint` like subscriber_detail does (change the fire-and-forget call at :137 to
   `await`), so refresh/errors sequence identically on both screens. Do NOT otherwise refactor
   the duplicated dispatch (R-PRESERVE).
2. **Test print button:** in Settings → printer section (settings_screen.dart near the
   type/width/copies tiles), add a `'test_print'` tile (new key both maps) that prints a
   minimal test slip via the ACTIVE transport (respects `PrinterPrefs.isUsb`; BT path uses
   `BluetoothPrintService` with a tiny one-line + cut, USB path a tiny raster + cut). Surface
   success/failure snackbars (AFTER any dialog closes — R-GETX). This directly proves
   "lifecycle works after pairing" without collecting a real payment.
3. **Keep the layered USB timeouts ordered** (Dart 75s > native 60s) — do not shorten either.

---

## 7. ITEM 6 — Per-accountant expenses in the OWNER PANEL

In-app separation already exists and is correct (accountant hard-scoped to self:
`_readScope`/`_scope`, expense_controller.dart:16-32; owner filter dropdown from v22;
sync stamps `accountant_id` server-side for accountants, syncController.js:79-91).
The gap is the **owner panel** (`backend/public/admin/index.html`):

1. **Accountant filter on `#/my/data/expenses`:** `listUserData` ALREADY supports
   `?relField=accountant_id&relValue=<uuid>` (adminController.js:226-231, whitelisted) — add a
   dropdown to `viewMyEntity` when `entity === 'expenses'` populated from the `accountants`
   mirror (same source the settlements screen uses; value = `d.id` which equals the app-side
   accountant UUID), wired into the `acctData` fetch as relField/relValue. Include an
   "الكل" (all) option and a "المالك" pseudo-option — NOTE: owner-created expenses have
   `accountant_id = null` in the mirror and `relValue` matching can't express "IS NULL"; if
   `listUserData` can't filter nulls, add a tiny additive backend branch: when
   `relField=accountant_id&relValue=__none__`, filter `{'data.accountant_id': null}`.
2. **Date filter:** add a month input (`<input type="month">`, the SPA already uses one on
   reports at index.html:2397+) filtered server-side: extend `listUserData`
   (adminController.js:201-276) with an OPTIONAL `month=YYYY-MM` query param that, for
   `entity === 'expenses'`, adds `{'data.date': {$regex: '^' + month}}` (the exact convention
   buildDashboard already uses at :102-105). Additive param — old clients unaffected.
   Validate the param with the same regex as getMyStats (:255-257).
3. **Columns + total:** extend `SYNC_COLUMNS.expenses` (index.html:1626-1631) with an
   "المحاسب" column resolved via the accountants map (same pattern as settlements in
   `syncColumnsFor`, :1697-1720; null → "المالك"). Above the table render a total row:
   Σ `amount` of the CURRENT filtered result set (client-side sum of the fetched page is
   misleading — instead have the backend return `totalAmount` alongside `total` when
   `entity==='expenses'` (aggregate over the SAME filter, additive field) and render that.
4. **Category labels:** the panel shows raw English category ids ('Fuel'/'Oil'/...) — add an
   Arabic label map in the SPA for the known category keys used by the app
   (read them from `lib/views/screens/expenses_screen.dart` quick-add grid / translations)
   with a raw-value fallback.
5. Owner panel stays READ-ONLY for expenses (no delete/edit — that's the admin panel's job).

Backend tests: `month` filter returns only matching-prefix expenses; `relValue=__none__`
returns only null-accountant rows; `totalAmount` equals the seeded sum.

---

## 8. ITEM 7 — Performance at scale (no crash / no truncation with big data)

Test dataset: `tools/TestData.backup` (1000 subscribers / 60 circuits / 20 boards, import
password `1234`). NOTE: importing floods ~1080 outbox rows and trips the >100 large-upload
confirm — settle the push before measuring.

Verified UNPAGINATED surfaces (everything else already paginates — see plan.md):
1. **Paid/Unpaid lists** — `CoreController.loadFilteredSubscribers` fetches ALL rows
   (core_controller.dart:412-437) though `getByPaymentStatus` ALREADY has `limit`/`offset`
   (core_repositories.dart:595-627). **Fix:** adopt the canonical fetch-N+1 pattern
   (copy `loadSubscribers`): page state for the filtered variant, `assignAll` page 1 / `addAll`
   later pages, preserve the v22 `query` + `category` across pages, and extend
   `subscribers_screen._onScroll` (:78-86) to call the filtered loadMore (it currently
   hard-excludes `filter != null`). Page size 100 like the All list.
2. **Board-scoped list** — `getByBoard` has NO limit params (core_repositories.dart:492-516).
   **Fix:** add `limit`/`offset` to `getByBoard` (additive named params), paginate
   `loadBoardSubscribers` the same way, include board mode in `_onScroll`.
   (`getByCircuit` stays as-is — single-row lookup usage only.)
3. **Owner settlements screen caps at 100 silently** —
   `accountant_settlements_screen.dart:55` uses `listAllForOwner()` defaults with no loadMore.
   **Fix:** add a ScrollController + canonical loadMore using the existing limit/offset params
   (settlement_repository.dart:80-100).
4. **Verify after fixes** (manual, on the 1000-sub dataset): All/Paid/Unpaid/board lists scroll
   smoothly and load incrementally; search on each list stays correct across pages; reports and
   dashboard remain instant (they are SQL aggregates — verified, no work needed);
   `_loadRowMeta`'s id-set/name-map loads are light (ids only) — no change.

---

## 9. ITEM 8 — Owner panel: professional entity details

Current: `viewMyEntity` renders generic tables; ONLY receipts have a proper detail view
(`receiptDetailContent`, index.html:2006-2039). Entities missing from `SYNC_COLUMNS` fall back
to a RAW `localId + JSON` dump (:1786-1797) — the "scattered" data the user complains about.

**Fix (SPA only, read-only views):**
1. Build a generic `entityDetailContent(entity, record, maps)` that renders a clean Arabic
   label→value card list (the `kv` row pattern receiptDetailContent already uses), with:
   FK resolution (board_id/circuit_id → names via the existing maps; accountant_id → accountant
   name or "المالك"; branch_id → branch name), money via `fmtPrice`, dates via `fmtDateShort`,
   booleans/status as Arabic labels, and unknown extra fields listed at the bottom (never a raw
   JSON blob).
2. Wire it for: **subscribers, boards, circuits, expenses, monthly_prices, settlements**
   (receipts keep their existing richer view). Row click in `viewMyEntity` opens the detail
   (same navigation style as `#/my/data/receipts/detail/:localId` — add a generic
   `#/my/data/:entity/detail/:localId` route in the `routes` table (:1030-1050) guarded
   `owner:true`).
3. Ensure ALL synced entities have a `SYNC_COLUMNS` entry so the raw-JSON fallback is
   unreachable for known entities (check which are missing and add minimal column sets).
4. Subscriber detail should ALSO show its board/circuit names and link to the existing
   per-subscriber statement (`#/my/sub/:subId`) — small nav affordance.
5. Keep the admin panel variants working (shared renderers — verify admin routes still render
   after the changes; the admin detail for receipts is shared already).

---

## 10. ITEM 10 — Local/uploaded data conflict: verify + close the real gaps

Verified guarantees already in place (list them in the change table): v17 logout unsynced-block;
v22 cross-account residue guard (fail-closed, pre-`isLoggedIn` ordering); push = last-EDIT-wins +
sticky tombstones on `data.updated_at`; pull clears only pull-generated outbox rows; branch
switch = push→wipe→pull under latches; restore flows clear the outbox deliberately (documented).

**Close these two REAL gaps (wrapper-level, R-ENGINE respected):**
1. **Profile-switch wipe has NO v17 guard** — `user_switch_screen._switchWithWipe` (:73-118)
   wipes ALL local data with no push-first and no pendingCount block: unsynced rows are lost on
   an owner↔accountant switch. **Fix:** replicate the logout guard sequence before the wipe:
   if plan `canSync`: (a) refuse while `isSyncing/isPulling`; (b) online → push
   (`syncNow(silent:true, showOverlay:false)` under the screen's existing overlay);
   (c) `refreshPending()`; (d) `pendingCount > 0` → blocking dialog `'logout_blocked_unsynced'`
   (key exists) and ABORT the switch. Only then proceed with the existing wipe+switch+pull.
   Mind the overlay/snackbar ordering (R-GETX).
2. **Admin-panel mirror delete resurrects** — `adminController.deleteUserData` does a HARD
   `findOneAndDelete` (:295-307): the device's local row survives and its next edit re-creates
   the mirror record. **Fix (backend):** convert to a tombstone: set `deleted: true`,
   `updatedAt: new Date()`, and stamp `data.updated_at = new Date().toISOString()` so devices
   that pull receive the tombstone and delete the local row, and a later stale local edit LOSES
   to the tombstone under the existing last-edit-wins rule. Panel lists already filter
   `deleted:false` — display behavior unchanged. Backend test: delete → pull contains
   tombstone → re-push of an older edit is skipped.

**Verify & document (no code):** receipt numbers are device-locally unique (cross-device
duplication documented as accepted — the user runs one device per account); last-edit-wins
trusts device clocks (documented); heartbeat is push-only (pulls at login/month-change/branch
switch/wallet/manual — documented); `since`-incremental pull exists but stays unused (full pull
is load-bearing for wipe-recovery paths — do NOT wire it in this batch).

---

## 11. Acceptance checklist (run in this order)

1. `flutter analyze` → **0 errors, 0 warnings** (infos ~45 pre-existing OK).
2. `flutter test` → all green (translation parity incl. every new key in BOTH maps).
3. `cd backend && npm test` → all green INCLUDING the new tests this spec requires
   (expected-in-payload, unpriced-month-unpaid, WRONG_PASSWORD paths ×2, expenses month/none
   filters + totalAmount, tombstone delete).
4. Manual smoke on the 1000-sub TestData: lists paginate, search works on every list variant,
   reports open instantly, owner panel expenses filter + details render.
5. `flutter build apk --release` (ships on Flash API by default — verify
   `lib/core/api_config.dart` untouched).
6. `MILESTONES.md`: add the v23 section (follow the v22 entry's format).
7. Write the user a change table (request item → what was done), flag every "reviewed, by
   design" decision listed in §2.7/§4.5/§10.
8. HOLD the commit until the user confirms; then commit with the established message style and
   push.
