# Flash v42 — Monthly accounting isolation · arrears notice · owner password reset · stable ordering

**Production constraint (owner, verbatim):** the system is LIVE with real users and
real records. Nothing may be deleted, reset, overwritten or corrupted. Every
change must be backward-compatible and every existing record must remain
available and usable afterwards.

That constraint is met structurally, not by promise:

| Kind of change | Rule applied in v42 |
| --- | --- |
| SQLite schema | only **additive nullable columns** via idempotent `_addColumn`, mirrored in `_onCreate` (version 14 → 15) |
| Existing rows | **never rewritten** — no backfill, no UPDATE, no DELETE anywhere in this batch |
| Derived figures | new predicates always carry a *fallback branch* so a legacy row keeps its exact old behaviour |
| Backend API | new query params are **optional**; new endpoints are **new paths** — no existing response shape changes |
| Sync engine | triggers/outbox/drain untouched; pull gains **forward-compatibility hardening only** (strictly more pulls succeed) |

---

## 1. The accountant wallet is isolated per accounting month

**Today.** `SettlementRepository.wallet()` and `GET /api/account/wallet` are
**all-time**: `collected(M) = Σ paid_amount of every valid receipt of that
accountant with payment method M`, `settled(M) = Σ every approved settlement of
method M`. Only the *history*, *Total Settlement*, *pending banner* and
*monthUnsettled* were month-scoped (v39/v40). So the two big balance cards on
**My Wallet** carry August money into September and never reset.

**Change.** The wallet becomes a **per-accounting-month wallet**, driven by the
one global tariff month (`MonthController.selectedMonth`, the v40 accounting
reference):

* `SettlementRepository.walletForMonth(accountantId, month)` — both sides
  bucketed to the month: collected by `receipts.month = ?`, settled by
  `COALESCE(settlements.month, substr(requested_at,1,7)) = ?` (the v40 rule —
  legacy rows keep their `requested_at` behaviour exactly).
* `hasPending(accountantId, method, {month})` — the duplicate-request guard
  becomes **per month**, so a still-pending August request can no longer block a
  September settlement request. Omitting `month` keeps the old all-time guard.
* `GET /api/account/wallet?month=YYYY-MM` — **additive optional** param. Without
  it the response is byte-identical to today, so every not-yet-updated device
  keeps working.
* `SettlementController` already re-loads on month change (`_monthFollow`); it
  now passes the month to both the server call and the local fallback, and
  `requestSettlement` settles **that month's** balance.
* **My Wallet** shows the accounting month on the cards so the figure is never
  ambiguous.

`wallet()` (all-time) is kept and still exported for any caller that wants the
lifetime figure; nothing that reads it is removed.

## 2. A month shows only that month's records

Every figure reachable while an accounting month is selected is scoped to it,
with **no aggregation across months**:

* wallet balance / collected / settled — item 1;
* settlement list, Total Settlement, pending banner, My Wallet history,
  unsettled balance — already isolated (v39/v40), re-verified by test;
* dashboard subscriber count and Σ amps — currently **all-time**, now scoped to
  the month via item 5's activation rule;
* board paid/unpaid counts, remaining fees, per-category amps — inherit the same
  rule through the single `_paymentStatusFrom` choke point.

## 3. Previous outstanding months appear only as a notice on the subscriber page

**New** `SubscriberRepository.previousUnpaidMonths(subscriberId, {beforeMonth,
branchId})` — for months **strictly before** the selected one in which the
subscriber was already active and a price row exists, returns
`(month, due, coverage, remaining)` where `coverage < due`.

Rendered as an **amber informational card** on the subscriber detail screen,
between the month row and the due card, listing each outstanding month and its
remaining amount.

**Guarantees (the point of the requirement):**

* it is read **only** by that one widget — no controller aggregate, no dashboard
  figure, no wallet, no settlement and no receipt consumes it;
* `getDueAmount`, the collect dialog, the paid/unpaid derivation and the printed
  receipt are **byte-for-byte unchanged**;
* the current month's accounting therefore stays completely independent of any
  previous month.

## 4. Forgot Password for the generator owner — super-admin approved

An OTP-shaped identity check whose **verification and approval happen in the
control panel**, never automatically.

**Backend** — new `PasswordResetRequest` model + three surfaces:

* `POST /api/auth/forgot-password` (public, rate-limited by `authLimiter`) —
  body `{ username, phone, newPassword }`. The account is found by username and
  the **phone must match the account's registered phone** (the identity check).
  The requested password is stored **already bcrypt-hashed**; a 6-digit
  `verificationCode` is generated and returned to the app as the reference the
  owner quotes to the super admin. Status starts `pending`, expires in 24 h, one
  active pending request per account (a new one supersedes the old).
* `GET /api/auth/forgot-password/status` — the app polls `{ status }`.
* `GET /api/admin/password-resets` (search + server-side pagination),
  `POST /api/admin/password-resets/:id/approve`, `.../reject` — super-admin only,
  following the existing admin list/decide conventions. **Approval is the moment
  the password changes**: the stored hash is written to the user, `tokenVersion`
  is bumped (every old JWT dies), the request becomes `approved`. Rejection
  changes nothing.
* An SSE `password_reset_requested` event so an open panel sees it live, exactly
  like `user_registered`.

**Admin panel** — a new **"طلبات استعادة كلمة المرور"** section (`#/password-resets`)
with the standard table + search + pagination, the verification code shown for
read-back, and Approve / Reject behind the existing confirm modal; a pending
badge on the admin dashboard.

**App** — `ForgotPasswordScreen` reached from the login screen: identity + new
password → a pending screen showing the verification code and a *check status*
button → on approval, "sign in with your new password". The pending reference is
persisted so the owner can close the app and come back. Online-only, with the
standard offline message.

No password is ever changed without a super-admin approval, and the plaintext
password never leaves the request payload.

## 5. New subscribers count only from the month they were added

**Today** the subscriber set for a month is *every* subscriber row, so five
subscribers added in month 9 immediately appear as **unpaid in month 8** and in
every earlier month — corrupting the historical picture.

**Change.** New nullable column `subscribers.billing_start_month TEXT`
(SQLite 14 → 15), stamped at creation from the **global tariff month** (not the
wall clock — so a September subscriber entered in August while browsing
September bills from September, consistent with v40 future-month billing). It is
preserved across edits (`??= orig?.billingStartMonth`) and rides the sync
whole-row push with no backend change.

One predicate, added to the single `_paymentStatusFrom` choke point (and the
parallel `paymentCountsByBoard` SQL):

```sql
AND ( COALESCE(s.billing_start_month,
               substr(REPLACE(s.created_at,'T',' '), 1, 7),
               '0000-00') <= ?          -- active from this month onwards
      OR r.subscriber_id IS NOT NULL )  -- …or it already has a receipt here
```

* the `COALESCE` fallback chain means **legacy rows work with no migration** —
  they fall back to their `created_at` prefix, and a row with no timestamp at all
  (`'0000-00'`) is always included, so nothing can silently vanish;
* the `OR r.subscriber_id IS NOT NULL` **safety valve** guarantees that any
  subscriber holding a valid receipt in a month stays visible in that month
  whatever its start stamp says — **no existing record can ever be orphaned**.

Fixing the shared choke point fixes `getByPaymentStatus`, `countByPaymentStatus`,
`paidSubscriberIds`, `remainingFeesTotal` and `ampsByPaymentStatusCategory` at
once. Dashboard `countByBranch` / `ampsByCategory` gain the same **optional**
`month` scope.

The **All-subscribers directory is deliberately not filtered** — browsing the
entity list is not month accounting, and hiding rows there would look like data
loss. Instead its per-row payment dot turns **neutral grey** (not red) for a
subscriber that is not yet active in the viewed month.

## 6. Fixed oldest→newest ordering for boards, circuits and names

**Root cause (two defects, both real in production).**

1. Boards created before v20 have `created_at = NULL`. SQLite sorts NULLs
   **first** in `ASC`, so the tie-break decides — and the tie-break is `rowid`,
   which is **device-local** and is **re-assigned in pull arrival order** by every
   sync pull, "delete local data", branch switch and reinstall. That is exactly
   the "order is random and changes unexpectedly between views" complaint.
2. Two timestamp formats coexist: `'YYYY-MM-DD HH:MM:SS'` (SQLite
   `CURRENT_TIMESTAMP`) and `'YYYY-MM-DDTHH:MM:SS.mmmZ'` (Dart ISO-8601). Since
   `' ' < 'T'`, every legacy row sorts before every new row **created on the same
   day**, regardless of the actual time.

**Fix — display-only, no data rewritten.** One canonical ordering expression,
`DbHelper.creationOrder([alias])`, used by every board / circuit / subscriber
query:

```sql
COALESCE(NULLIF(REPLACE(created_at,'T',' '), ''), '0000-00-00 00:00:00') ASC,
id ASC
```

`REPLACE` normalises the two formats into one comparable key; the `id` (UUID)
tie-break is **identical on every device**, so the order is now stable across
devices, pulls, branch switches, reinstalls and views. The owner/admin panel
lists use the same oldest→newest rule.

## 7. Data safety — and the rollout hazard this batch would otherwise create

`SyncService.pull()` writes each mirrored row with `txn.insert(entity,
wholeDataMap)`. A column present on the server but **absent from an older
device's SQLite schema** makes that insert throw, which aborts the **entire pull
transaction** — every entity, every retry, silently. This is the documented v40
"old-APK pull freeze" blast radius, and adding `billing_start_month` in item 5
would reproduce it on every device that has not updated yet.

v42 therefore ships the hardening v40 listed as future work:

* each pulled record's `data` is **filtered to the columns the local table
  actually has** (cached `PRAGMA table_info`);
* a record that still fails is **isolated** instead of aborting the batch.

When schemas match, behaviour is unchanged. When they don't, a newer server row
degrades gracefully on an older device instead of freezing all synchronisation —
permanently removing this class of rollout freeze.

**Nothing in v42 deletes, resets, rewrites or migrates a single existing row.**

---

## Out of scope (explicitly untouched)

Sync triggers / outbox / drain logic · discount rules · receipt printing and PDF
layout · settlement approval & reversal locks · branch switching · device
binding · plans & subscriptions · cloud backup · the All-subscribers directory
result set · `wallet()`'s all-time semantics (kept alongside the new
month-scoped one).
