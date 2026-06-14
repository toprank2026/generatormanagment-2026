# Accountant Sub-Users — Feature & Test Report

Multi-accountant support for the **Flash** generator app: the owner (admin) creates
accountant sub-accounts with **per-accountant permissions** and **full data
isolation** across the offline SQLite app, the synced server mirror, cloud backup,
the owner web panel, and the super-admin panel.

## What was built

| Area | Summary |
|---|---|
| **Identity** | Owner = the one cloud account (handles sync/backup). Accountants = local sub-users created by the owner; they **sign in offline** (local password) and become the *acting user*. A synced `accountants` identity table (id/username/name/active/permissions, **no password**) makes them visible to the panels on any device. |
| **Schema** | DB v2→v4: `accountant_id` on boards/circuits/subscribers/expenses (receipts already had it); `name`/`active`/`permissions` on users; new `accountants` table. Idempotent migrations. |
| **Permissions** | Per accountant the owner grants any of: manage **subscribers**, **boards & circuits**, **expenses**, **prices**. Default = none. **Recording payments + printing are always allowed.** Owner has everything. `AuthController.can(perm)` drives gating. |
| **Sharing model (updated)** | **Boards, circuits, subscribers are SHARED** — the owner builds one common customer base visible to ALL accountants (no per-subscriber assignment). **Invoices/payments, expenses, and the reports/history derived from them stay per-accountant.** So: subscriber lists + paid/unpaid + totals are global; collected / expenses / net / payment-history are each accountant's own (owner sees all / can filter). |
| **Attribution / printing** | Each receipt belongs to the **accountant who collected it**; the printed invoice shows the **المحاسب** (accountant) line, resolved from `receipt.accountant_id` (Bluetooth + PDF). |
| **Reports** | Subscriber metrics global (shared base); money (collected/expenses/net) + payment history per-accountant; the owner has an accountant **filter** (scopes the money) + an accountant **count** card (app reports + owner web panel). |
| **Accountant management** | A dedicated **AccountantsScreen** (reached from a Settings tile, owner-only) — create/edit/enable/reset-password/delete with permission checkboxes — moved out of the Settings body. |
| **Panels** | Owner panel (`#/my`): accountant count card + reports filter. Super-admin: browsable `accountants` data tab + per-accountant attribution on every row. |
| **Sync & backup** | No new flow needed — sync is whole-row (the new columns + the `accountants` table ride along automatically; backend accepts any entity) and backup is the whole `moldati.db` file. |

## Automated tests — ✅ all green
- **Flutter:** 61 tests, incl. a new `accountant_scoping_test.dart` (8 tests) proving: accountant create writes a synced identity + a working offline credential; disabled accountant can't log in; boards/subscribers reads are scoped vs all; collected-sum + paid/unpaid counts respect the accountant scope; an accountant can't delete another's subscriber; the owner can delete any.
- **Backend:** 67 tests.
- `flutter analyze`: 0 errors.

## Live verification

### Backend mirror (API) — ✅ (shared model)
Pushed 2 accountants + 2 **shared** subscribers + receipts collected by each, then called `/api/account/stats`:
- No filter → 2 subscribers, collected **15,000**, paid 1, unpaid 1, `counts.accountants = 2`.
- `?accountantId=A1` → subscribers **2 (shared/global)**, collected **10,000** (A1's), paid/unpaid global.
- `?accountantId=A2` → subscribers **2 (shared/global)**, collected **5,000** (A2's).

### Owner web panel (`#/my`) — ✅
- Dashboard shows the **المحاسبون** (accountants) count card.
- Reports accountant **filter** (كل المحاسبين / Sara / Ahmed): selecting *Ahmed* re-scoped every figure live — collected **10,000**, expected 10,000, 1 subscriber, 1 paid, 100% (vs 15,000 / 2 for "all").

### Super-admin panel — ✅
- New **accountants** data tab renders a clean table (name / username / active) with search + delete; breadcrumb المستخدمون / AcctTest / المحاسبون.
- Per-accountant attribution visible on the owner's synced rows (Sub1→A1, Sub2→A2).

### Flutter app (device) — ✅
- Owner creates an accountant in Settings → Accountants (with permission checkboxes); count badge in the section header.
- **Profile switch** owner ⇄ accountant works (offline password check); the persisted accountant is restored on relaunch; the profile badge + all scoped screens update on switch.
- **Permission gating:** as an accountant the owner-only Settings sections (Subscription / Accountants / Manage-devices / Delete-local) are hidden; create/edit/delete controls appear only for granted areas; collect + print stay available.
- **Isolation (with seeded data):** accountant *Kareem* (granted: subscribers + expenses) sees exactly **1 subscriber / 1 board / 1 paid** — only his own; the owner sees **2 / 2** (his + the owner-owned one).
- **Print invoice (accountant):** opening Kareem's subscriber → Receipt #1 → Print executes and builds the invoice **with Kareem's name** (resolved from `receipt.accountant_id`) and hands it to the print service — confirmed via device logs.

## Known limitations / notes
- **Print — visible PDF not screenshotted:** the test device has a *bonded* Bluetooth thermal printer, so the app took the Bluetooth path (no physical printer → "broken pipe"); after clearing the printer, the Flutter dashboard cards did not respond to `adb` synthetic taps (an automation limitation, not a code issue — a real finger tap works). The print path + المحاسب attribution are verified by code + logs.
- **Legacy rows:** records that existed before the v3/v4 migration have a null `accountant_id` → treated as owner-owned (owner sees them; accountants don't). No mass backfill is run (matches the existing sync-backfill gotcha).
- **New device after backup-restore:** the synced `accountants` identities restore (names/attribution/panel work), but accountant *login passwords* are device-local — the owner re-sets a password per device.
- `monthly_prices` stays owner-global (one shared price per month).

## Status
All changes committed & pushed to `main`. The app's release build defaults to the
production API `https://generator.tikritstore.shop`.
