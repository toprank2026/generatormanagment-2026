# Flash v43 — corrections after invoicing (month-locked accounting + adjustment ledger)

## 1. The requirement, in the owner's words

> Allow the accountant to modify a subscriber's information **even after an invoice has been
> issued**, and to add an adjustment/settlement for a **specific subscriber and a specific
> month** — without breaking, altering or negatively affecting the existing architecture,
> workflows, accounting logic, or any data and operations already performed.

with the **Golden Rule**:

> Invoice Month = Accounting Month = Settlement Month = Correction Month.
> A correction for one billing month must never alter or financially affect another month.
> The accountant's wallet must never be driven negative by a historical correction.

## 2. Is this suitable for this system? — assessment

**Yes, and it fits the grain of the codebase — but only if built as an *append-only ledger
beside* the existing tables, never as edits to them.** A 14-area read-only survey of the
financial subsystem produced one unambiguous conclusion:

> **Every financial "history" this system has today is mutated in place.** There is no
> append-only record anywhere. `ReceiptRepository.markRefunded` does
> `UPDATE receipts SET status='refunded'` **on the original row**, and the `refunds` table —
> which exists, is synced, and has triggers — **is never inserted into by any code path.**
> A reversal today therefore leaves *no evidence it ever happened*.

So the owner's rules are not a tightening of something that exists; they are the first
audit trail this system will have. Three structural facts make the fit workable:

| Fact | Why it helps |
| --- | --- |
| Receipts already snapshot the billing basis (`amps_snapshot`, `price_snapshot`) | a closed month can be corrected against what was actually invoiced, without consulting today's mutable `subscribers.amps` |
| Settlements already carry a **tariff month** (v40) and are bucketed by `COALESCE(month, substr(requested_at,1,7))` everywhere | "settlement month" already exists and is consistent across app, backend and panel — corrections can reuse it verbatim |
| An **unknown sync entity is skipped on pull** (`pk == null → continue`) | new tables are invisible to older devices instead of freezing them — unlike v42's column addition |

And three facts make it dangerous, each of which dictates a design rule below: the wallet is
**derived, not stored**; `/api/sync/push` is a **mirror with no business validation**; and
`SyncService.pull` writes with `ConflictAlgorithm.replace` — **delete + insert** — which
bypasses every app-layer guard and resets any column the pushing device didn't know about.

### 2.1 The one requirement that cannot be met literally

> "The Backend must independently reject unauthorized direct modifications even if the request
> is sent manually through an API."

This is **offline-first**: the device's SQLite is the source of truth and the server is a
push-only mirror. A backend that *refuses* a pushed row cannot undo the write the device
already committed locally — it can only decline to mirror it.

Worse, the naive implementation is a **known production incident**: throwing a 4xx inside the
push loop fails the **whole batch**, so one locked row blocks every unrelated row behind it,
the outbox never drains, and — because `pull()` pushes first — synchronisation stops entirely.
That exact wedge already happened once and is why v25 downgraded authorization failures from
`403` to *skip-and-count*.

**What v43 does instead, and it satisfies the intent:**

1. The **app** enforces at the repository choke point — below the UI, so hiding a button is
   not the control; every write path goes through it
   (`MonthlyPriceRepository.insertGuarded` for the tariff, `CoreController.updateSubscriber`
   for the billing basis, and the correction flow for everything else).
2. The **backend's own mutating endpoints** — the admin synced-data DELETE and the correction
   decision routes — refuse outright with a real `4xx`. Those are ordinary request/response
   calls with no offline semantics, so a hard rejection is safe *and* is where a "manual API
   request" actually lands.
3. On **`/api/sync/push`** the only refusal is forgery **no app version can produce**: an
   accountant pushing an already-decided settlement. It is skip-and-counted, never thrown, and
   reported in the additive `rejected[]`.

### 2.2 Why the push loop carries NO business lock (revised after adversarial review)

v43 originally *did* re-evaluate the invoice/settlement lock on `/api/sync/push` and refuse to
mirror a violating row. **A 10-dimension adversarial review found that gate is
net-destructive, and it was removed.** The reasoning is recorded here so it is not
reintroduced:

- The mirror is push-only and the **device is the source of truth**. `pull()` is a **full
  restore** (`INSERT OR REPLACE`) run on a new device, after delete-local-data, and on **every
  branch switch**. So a row the server refuses is a permanent divergence — and that divergence
  becomes **silent data loss** at the next restore, when the stale mirror value overwrites the
  device's real one.
- The server **cannot reproduce the app's rules**. A `subscribers` row carries no month, so a
  server lock could only ask "was this subscriber *ever* invoiced" — strictly stricter than
  the app's month-scoped rule, so it refused ordinary amps/category edits aimed at an **open**
  month. The app's receipt-reversal rule is likewise per-accountant, per-method and
  issue-time-based, while the server could only see "does this month carry any active
  settlement" — so it refused reversals the app itself permits.
- Decisively, this is a **live, mixed-version fleet**. A v42 device has no client-side v43
  guard at all, so a new server-side refusal breaks a workflow that works today and costs that
  account real data. **Accepting the row is never worse than yesterday's behaviour; refusing
  it is.**

The honest limitation, stated plainly: a tampered *device* can write to its own local SQLite
and that row will be mirrored — no server in a device-authoritative architecture can prevent
that. Making the mirror authoritative would be exactly the architectural restructure this
batch was told not to attempt. The controls that *do* hold are the app-layer choke points and
the admin REST surface above.

## 3. Design

### 3.1 Two new synced tables — never new columns

**Rule: lock state and correction state must never be a column on `subscribers`,
`receipts`, `monthly_prices` or `settlements`.** `pull` writes `INSERT OR REPLACE`, so a
column absent from a row pushed by an older device is **reset account-wide on every device's
next pull**. New concepts get new tables; existing tables are untouched.

**`corrections`** — the request and its lifecycle (a first-class audit document, modelled on
`PasswordResetRequest`, which the codebase already proves out):

`id · subscriber_id · month · branch_id · accountant_id · receipt_uuid · settlement_id ·
reason · old_amps · new_amps · old_due · new_due · difference · status · requested_by ·
requested_at · decided_by · decided_at · decision_note · refund_paid_at · refund_paid_by ·
created_at · updated_at`

`status`: `pending → approved | rejected`, and for a decrease: `approved → refund_due →
completed`.

**`financial_adjustments`** — the immutable signed delta. **Written once, never updated,
never deleted.**

`id · correction_id · subscriber_id · month · branch_id · accountant_id · kind · amount ·
method · created_at · created_by`

`kind`: `correction_increase` · `correction_decrease` · `refund_return`.

### 3.2 Why adjustments are NOT rows in `receipts`

Putting the delta in `receipts` corrupts nine mechanisms. The two decisive ones:
`receipt_no` is `NOT NULL` and allocated as `MAX(receipt_no)+1` per branch, so an adjustment
would **consume a real invoice number**; and the `status='valid'` filter is a trap in both
directions — a new status silently **excludes** the delta from ~20 money queries (the audit
says the correction happened while every figure still shows the old number), while reusing
`'valid'` **includes** it in printed receipt history as a phantom invoice.

Adjustments therefore live in their own table and are folded, explicitly and by name, into
exactly the aggregates enumerated in `plan.md` §4.

### 3.3 The lock — derived, never stored

* **Invoice lock** (per subscriber-month): a valid receipt exists for `(subscriber_id, month)`.
* **Settlement lock** (per month): a settlement exists for the month with status
  `pending|approved`, bucketed by `COALESCE(month, substr(requested_at,1,7))` — byte-identical
  to the expression already used in the app, the backend and the panel.

Locked fields are exactly those that move the money: `subscribers.amps`, `subscribers.category`,
`subscribers.branch_id`, and the `monthly_prices` row for that month. Name, phone and board
stay freely editable, as today.

### 3.4 The correction flow

```
accountant edits a locked field
   → blocked, offered "request a correction"
   → correction (pending), linked to subscriber + month + receipt + settlement
   → admin approves
   → financial_adjustment written (original receipt UNTOUCHED)
   → same month recomputed
      ├─ increase → delta added to that month's wallet → additional settlement allowed
      └─ decrease → status refund_due (wallet NOT reduced, never negative)
                  → admin physically returns the cash
                  → refund_return adjustment written → completed
```

Approval and physical cash return are **two separate, separately-recorded operations** —
approving a correction never asserts that money moved.

### 3.5 Backward compatibility — what does NOT change

Nothing in the existing flow moves. No existing table gains a column; no existing row is
edited, deleted or re-interpreted; every existing query returns exactly what it returns today
**until an adjustment exists for that subscriber-month**. A month with no correction is
byte-identically the month it is now. The `collectPayment` / reversal / settlement paths are
untouched except for the guard that redirects a locked edit into a correction request.

The one behavioural change is the intended one: editing amps/category on a subscriber that
already has a receipt for the selected month now raises `edit_locked_invoiced` instead of
silently rewriting that month's due — which is the bug the owner is asking us to close.

## 4. Deploy order (hard constraint, not advice)

`syncController.js` throws **400 for the entire batch** on an unknown entity — unlike the 403
path, which skips. So a v43 APK reaching any device **before** the backend knows the two new
entities makes that device's every push fail forever, and since `pull()` pushes first,
synchronisation stops completely.

> **The backend MUST be deployed before a single v43 APK is installed.** Not the other way
> round, and not simultaneously.

## 5. Fixed along the way (pre-existing defects the map surfaced)

* `settlementController.decide` on the backend is **not idempotent** — it filters only
  `{user, entity, localId}` with no `data.status: 'pending'`, so an already-approved settlement
  can be re-approved, flipped to rejected, or re-amounted at any time, silently changing the
  derived wallet. The Dart twin is guarded; the panel check is client-side only.
* A reversal writes **no audit row**; the `refunds` table is a dead shell. Reversals now append
  to it (additive — nothing reads it yet, so nothing can regress).
* 🔒 **An accountant can forge an APPROVED settlement.** `ENTITY_PERMISSION.settlements = null`
  in `syncController.js` means accountants may push settlement rows without restriction, and
  `authorizeRecord` stamps `branch_id`/`accountant_id` but **never inspects `data.status`**. So a
  crafted push of `{status:'approved', amount:…, decided_by:…}` makes the owner's books show
  cash handed over that never arrived — the owner-only approval route is bypassed entirely.
  Fixed by field-level guard: an accountant may create/update a settlement only in `pending`
  state, and may never set `status`, `decided_by` or `decided_at`. Creating a settlement request
  — the accountant's real workflow — is unaffected.

  *(Found by the adversarial mapping fleet; pre-existing, not introduced by v43.)*

## 5.1 Known gaps deliberately left for a follow-up batch

The fleet also found that **no printed artefact can express a correction** — the PDF/USB/LAN/
Bluetooth renderers print only the invoice fields, with no status, supersession or adjustment
slip, and no reprint gate — and that the **public QR receipt** (`publicController.js`) is a fixed
field whitelist that would show neither. A correction is therefore auditable in the app, the
panel and the mirror, but invisible on paper to the subscriber. Closing that means one shared
renderer change (LAN reuses the USB renderer) plus the PDF and a `corrections` projection on the
public endpoint. It is deliberately **not** in this batch, which already changes the money path.

## 6. Out of scope (deliberately)

Converting the existing tables to an append-only ledger; changing `markRefunded`'s status flip;
retro-fitting audit rows for historical reversals; period "close/reopen" administration; and
any change to the sync engine's push/outbox/drain contract.
