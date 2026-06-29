# Flash v11 → now — change log (for self-check)

All changes since the v10 release. Suites: **Flutter 90, backend 124**.
Release APK built for Tikrit (`https://generator.tikritstore.shop`, 65.7 MB).

**Commits on `main` (newest → oldest):**

| Hash | What |
|------|------|
| `b839021` | Owner panel: restore old branch switcher as fallback (single bar) |
| `e0a0262` | Flash v12: MILESTONES entry |
| `d6ae494` | Flash v12 review fixes (hard-logout data-loss HIGH + overlay + payments load) |
| `fddd19d` | Flash v12: card wallet + wallet pull-on-open + broad sync + hard logout + payments screen |
| `68cd9e5` | Flash v11 review fixes: server-authoritative wallet + receipt-delete sync + 4 nits |
| `c7c394e` | docs: schema v11 + test counts |
| `efd818f` | Flash v11 (3,5,6): current-month receipt pull + accountant data link + accountant-by-phone |
| `2bedcc9` | Flash v11 (2,4): payment method (cash/card) end-to-end + print receipt twice |
| `726bc0b` | Flash v11 backend: settlements approve + payment_method QR + receiptsMonth pull + accountant-by-phone + owner-panel settlements UI |
| `0a0a883` | Flash v11 (1): accountant My Wallet + settlements (schema v11) + receipt payment_method column |

---

## A) Flash v11 features

| # | Change | Where (files) | How to verify |
|---|--------|---------------|---------------|
| 1 | **Accountant "My Wallet" + settlements** — receipts an accountant collects build a wallet; Settings → **My Wallet** shows the balance; **Request Settlement** → *Pending* → owner **approves in Owner Panel** → wallet drops by the requested amount; paginated history; synced. Schema **v11** (new `settlements` table + `receipts.payment_method`). | `db_helper` (v11), `settlement_model`, `settlement_repository`, `settlement_controller`, `my_wallet_screen`, `app_binding`, `settings_screen` (tile); backend `settlementController`, `accountController.getWallet`, `routes/account`, owner-panel settlements UI | Log in as accountant → collect a cash receipt → My Wallet balance rises → Request Settlement → Owner Panel approve → balance drops. |
| 2 | **Payment method (Cash/Card)** on receipts → reports, printed receipts (BT + PDF), and QR/public receipt. | `billing_models` (`Receipt.paymentMethod`, `receiptPaymentMethodText`), `collect_payment_dialog` (selector), `billing_controller`, `bluetooth_print_service`, `pdf_service`, `reports_screen`; backend `publicController` (PUBLIC_RECEIPT_FIELDS) | Collect with Cash vs Card → method shows on the printed receipt, in Reports, and in the scanned QR. |
| 3 | **Login data load: upload all, pull only current-month histories** (anti-crash). Push uploads everything; pull scopes **receipts** to the current month (other entities full); receipt deletions still propagate. | `sync_repository`, `sync_service.pull(receiptsMonth)`, `sync_controller` (`_receiptsMonth`, `_monthWorker`); backend `syncController` (receiptsMonth `$or` + tombstone clause) | Account with many months of receipts → login is fast/no crash; only current month present; switch month → that month pulls. |
| 4 | **Print the receipt twice** in one print op. | `bluetooth_print_service` (copy loop), `pdf_service` (two pages) | One print → two identical copies. |
| 5 | **Accountant data association** — boards/circuits/subscribers/expenses/receipts created by an accountant stamp `accountant_id`; synced/pulled/wiped; preserved on subscriber edit. | `core_controller` (stamp), `core_repositories` (`getById`), `billing_controller` | Accountant creates data → it carries their id (wallet/attribution correct); editing a subscriber keeps the id. |
| 6 | **Accountant created by name + phone + password** (phone = login, like branch/owner). | `auth_repository.createAccountant` (phone+username), `accountants_screen` (phone field); backend `accountantAccountController` | Owner creates accountant with a phone → accountant logs in with that phone. |

## B) Flash v11 review fixes (commit `68cd9e5`)

| Sev | Bug | Fix |
|-----|-----|-----|
| **HIGH** | Wallet balance went negative after wipe/login — collected was month-scoped but settled was all-time. | **Server-authoritative** `GET /api/account/wallet` (cash-only, all-time) used online, local fallback offline. |
| **HIGH** | Current-month-scoped pull dropped receipt **deletions** (tombstones). | Added `{entity:'receipts',deleted:true}` to the `receiptsMonth` `$or`. |
| LOW | Card payments counted as cash in the wallet. | Cash-only filter (client + server). |
| LOW | Wallet not refreshed after a pull. | `_reloadAppData` reloads `SettlementController`. |
| LOW | Switching month didn't pull. | `_monthWorker` silent pull on month change. |
| LOW | Editing a subscriber wiped `accountant_id`. | Preserve via `getById`. |

---

## C) Flash v12 features

| # | Change | Where (files) | How to verify |
|---|--------|---------------|---------------|
| 1 | **Credit-card wallet** — a 2nd accountant wallet beside Cash, for card-paid receipts. `settlements.method` ('cash'\|'card'), schema **v11→v12**. Per-method balance = collected − approved settlements; cash & card independent. Per-method Request Settlement, synced, owner-approved, paginated history (shows method). | `db_helper` (v12 + `settlements.method`), `settlement_model`, `settlement_repository` (`wallet` per-method, `hasPending(id,method)`), `settlement_controller`, `my_wallet_screen` (two cards); backend `accountController.getWallet` (`{cash,card}`), owner panel (method column) | My Wallet shows **two** wallets. A **card** receipt raises only the Card wallet; a cash one only Cash. *(Verified live RMX3085: Cash 60,000 / Card 32,000.)* |
| 2 | **Wallet pull-on-open** — opening My Wallet pulls latest receipts + owner decisions first; pull-to-refresh. | `settlement_controller.load(pull:true)`, `my_wallet_screen` initState | Approve in Owner Panel → reopen My Wallet → already current. |
| 3 | **Sync after (nearly) every op** — `poke()` also fires on accountant creation. | `settings_controller.createAccountant` | Create accountant online → pending clears immediately. |
| 4 | **Hard logout** — confirm → loading overlay → wipe **ALL** local tables → only then clear session. Install-id preserved. | `auth_controller.logout`, `sync_service.wipeAllLocalData`, `sync_controller.deleteAllLocalData`, `db_helper.wipeAllTables` | Log out → spinner during wipe → Login. Re-login → no leftover data; binding OK. |
| 5 | **Payments-of-month → own screen** — moved out of Reports into **PaymentsScreen** (button in Reports); reuses ReportsController + pagination + pull-to-refresh. | `payments_screen.dart` (new), `reports_screen` | Reports → **payments_of_month** button → separate paginated list. |

## D) Flash v12 review fixes (commit `d6ae494`)

| Sev | Bug | Fix |
|-----|-----|-----|
| **HIGH** | Hard-logout `wipeAllTables` cleared `sync_outbox` before later tables (accountants/branches/settlements) → tombstones replayed as deletes on next login (**data loss** on upgraded installs). | Clear `sync_outbox` **last**. |
| MED | Nested `syncNow` during logout closed the overlay early on >100 pending rows. | `syncNow({showOverlay})`; logout passes `showOverlay:false`. |
| LOW | PaymentsScreen couldn't load when empty. | Load report if empty + pull-to-refresh. |

## E) Owner-panel branch switcher — "as old" (commit `b839021`)

| Change | Detail | Where | How to verify |
|--------|--------|-------|---------------|
| **Restore old switcher as fallback** | Single switcher: branch-**account** switcher takes precedence; with **no branch sub-accounts**, show the old **`كل الفروع`** dropdown (filters own mirror by `branch_id`). | `index.html` `ownerShell` (`acctBranchBar() \|\| ownerBranchBar()`, `ensureOwnerBranches()`) | No branch accounts → `كل الفروع` appears; with branch accounts → account switcher. Never two bars. |
| **Switch re-scopes ALL data** | Fallback now also passes `branchId` to entity-**list** queries (stats already did). Backend filters `data.branch_id` on stats + lists. | `index.html` `acctData` | Pick a branch → home stats, all entity lists, and Reports change to that branch. |

---

### Deploy / build notes
- **Flutter (A,C,D):** in the built Tikrit release APK — reinstall on device.
- **Backend (v11 settlements/wallet/pull, v12 `getWallet`):** needs a **server deploy** to take effect on production.
- **Owner panel (v11 settlements UI + method column, v12 method column, E switcher):** static SPA `backend/public/admin/index.html` — appears on production **after you deploy `index.html`** to the Tikrit server.
