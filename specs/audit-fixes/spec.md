# Spec — Audit Fixes (from AUDIT_REPORT.md)

Source: `AUDIT_REPORT.md` — 74 confirmed + 1 potential + 4 needs-validation findings. This spec groups them into workstreams and splits **Phase 1 (bounded, ship now)** from **Phase 2 (architectural — needs design/decision)**.

## Decisions (baked in)
- **Discount lockstep:** align the **app** to the backend — the backend already does `remaining = expected − collected − Σdiscount`; the app Dashboard/Reports will subtract the waived discount too (coverage already includes it for paid/unpaid). Net invariant everywhere: `collected(cash) + discount(waived) + remaining = expected`. (Fixes the discount/reports-consistency High findings.)
- **Receipt numbering:** a SQLite `UNIQUE(branch_id, receipt_no)` is **incompatible** with the whole-row pull mirror (two distinct uuids with the same number both pull in via `ConflictAlgorithm.replace`-by-uuid; a unique index would make the second pull *throw* and break sync). So Phase 1 only makes local allocation atomic (MAX+1 + insert in one txn) and stops number reuse on delete; true cross-device uniqueness (server-assigned numbers / device-namespaced) is **Phase 2**.
- **Conflict resolution (LWW/lost-updates/tombstones):** a real fix needs a per-row `updated_at` (maintained by triggers) sent as the sync timestamp + a server `updatedAt < incoming` guard. Touching the outbox/triggers is flagged risky in CLAUDE.md, and the change spans client+server+migration. **Phase 2**, designed carefully; not rushed.
- **Server-side push authz/validation:** Phase 1 — pure backend, high security value, no client change.

## Phase 1 — ship now (bounded, suite stays green)

### Backend (disjoint files → parallel agents)
- **WS-SEC** security: fail-fast when `JWT_SECRET` unset/default in production; refuse default `admin/admin123` in production; add `express-rate-limit` (+helmet) on `/api/auth/*`; require a `device` on owner login (don't issue a usable token without binding) and enforce `maxDevices` regardless of payload; **enforce subscription `expiresAt`** (treat `active && expiresAt<now` as expired in `featuresForUser`/serialize). _(findings: JWT default, default admin, no rate-limit, device-limit bypass, expiry never enforced; token-version on password change optional.)_
- **WS-PUSHAUTHZ** `syncController.push`: whitelist `entity` against the known synced tables; for `role==='accountant'` server-stamp/validate `data.branch_id===req.user.branchId` and `data.accountant_id===req.user._id`, and reject entities the accountant's `permissions` don't allow; (pull) branch-scope an accountant to its `branchId`. _(findings: push trusts whole row, UI-only permissions, accountant gets all branches on pull.)_
- **WS-DASH** `accountController.buildDashboard`: fix the consolidated (branchId=null) price map to be keyed by `(branch, category)` so per-branch pricing isn't collapsed; keep `remaining = expected − collected − discountTotal` (now matched by the app). Fix `backupController` to scope by `effectiveOwnerId` (or restrict to owner/admin). UTC month-default → accept client month. _(findings: consolidated price collapse, backup scoping, month UTC.)_
- **WS-PANEL** `index.html`: `fmtPrice/fmtDate*` drop `esc()` on the textContent-only path (double-escape). _(finding: panel double-escape.)_

### Flutter (coupled → edited directly, in order)
- **WS-DISCOUNT** `ReceiptRepository.getDiscountSum(month,{accountantId,branchId})`; `DashboardController.loadStats` and `ReportsController.loadReport` set `remaining = expected − collected − discountSum`.
- **WS-SYNCSAFE** `maybeAutoSync`/`syncNow` early-return also on `isPulling`; logout-wipe only when online + `canSync` + `pendingCount()==0` after the pre-wipe push (else keep data); clear `sync_outbox` after a cloud/file restore; `_reloadAppData` also refreshes `BillingController` price cache; post-login pull retry / bootstrap pull-if-empty.
- **WS-PRICING** `getByPaymentStatus`/`getDueAmount`: a subscriber/category with **no price row** is **not** "paid" (require `mp.price_per_amp IS NOT NULL` for the paid branch; collect shows a "no price" snackbar instead of silent null); block `setPrices` for a month that already has valid receipts (implement the dead `locked` intent / immutability) and warn on category change for subscribers with receipts; compute historical due from `price_snapshot`/`category_snapshot` where receipts exist.
- **WS-SCALE** DB **v7→v8**: add indexes (`monthly_prices(month,branch_id,category)`, `receipts(branch_id,month,status)`, `receipts(subscriber_id,month,status)`, `subscribers(branch_id,category)`, `subscribers(branch_id,status,circuit_id)`, `circuits(board_id)`, `expenses(branch_id,date)`, `sync_outbox(entity,local_id,seq)`) in `_onCreate` + an `_onUpgrade(<8)` branch; `countByPaymentStatus` → `SELECT COUNT(*)` wrapper (no row hydration); dashboard totals via `COUNT/SUM`; circuit count via one `COUNT`; paid/unpaid screen paginated; wire incremental `since` on routine pulls.
- **WS-PERMS-UI** subscriber-detail edit/delete gate `auth.can(Perm.subscribers)` (not `isAdmin`); subscribers list `Get.to(detail)?.then((_)=>_reload())`; collect dialog wrap confirm in try/catch; consolidated-view create blocked or inherits parent branch; NULL-branch reads use `IFNULL(branch_id,'main')` uniformly.
- **WS-RECEIPTNO** allocate receipt number + insert in one transaction; next-number from a never-decreasing source so a deleted top receipt doesn't reuse its number. (Cross-device uniqueness = Phase 2.)

## Phase 2 — architectural (design + decision required; specced, not yet built)
- **Conflict resolution:** add `updated_at` per business row (trigger-maintained), push it as the sync timestamp, server applies only when newer (`updatedAt < incoming`), tombstones sticky; protect locally-pending rows from being overwritten by pull. Fixes lost-update, edit-vs-delete, pull-overwrite, push-time-LWW (multiple Critical/High).
- **Receipt numbering:** server-assigned per-(account,branch) sequence at push, or device-namespaced numbers; post-pull dedup/renumber + surface collisions. (Critical/High receipt findings.)
- **Branch-delete distributed cascade / orphan cleanup** after pull.
- **Periodic incremental pull** for multi-accountant convergence (double-collect window) + overpay reconciliation/flagging.
- **maxDevices self-service recovery**; accountant device-exemption cap.

## Verification
`flutter analyze` (0 errors/new warnings), `flutter test` (+ new tests: discount-lockstep remaining, no-price≠paid, pricing-immutability, count-aggregates), `cd backend && npm test` (+ security/authz tests). Adversarial review of the diff. Commit per workstream so the suite is green between changes.
