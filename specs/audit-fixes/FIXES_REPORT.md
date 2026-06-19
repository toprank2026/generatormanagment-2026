# Audit Fixes — what changed (Phase 1)

Spec-Kit: `specs/audit-fixes/` (spec / plan / tasks). Suites green: **Flutter 87, backend 100**. Method: backend agent (disjoint) + direct Flutter edits + adversarial review workflow (found & fixed 2 regressions before commit).

## Backend
- **Security:** prod boot now fails fast on default/missing `JWT_SECRET` & `ADMIN_PASSWORD`; added `helmet`; rate-limit on `/auth/*` (429); subscription `expiresAt` now enforced (served as `expired`, stops granting features).
- **Sync push authz:** `/sync/push` now whitelists entities and, for accountants, gates by permission, server-stamps `branch_id` + `accountant_id` (uses `localId`) and rejects cross-branch writes; `/sync/pull` branch-scoped for confined accountants.
- **Dashboard/backup:** consolidated owner dashboard now prices each subscriber by its **own** branch (was collapsing branches); backup endpoints scoped to the effective owner.
- **Panel:** fixed double-escaped values in admin/owner tables.

## Flutter
- **Discount lockstep:** Dashboard & Reports "remaining" now subtract the waived discount (matches backend + paid/unpaid). Added `getDiscountSum`.
- **Sync safety:** no push during a pull/branch-switch (`isPulling` guard); price cache refreshed after pull.
- **Logout safety:** local data is wiped only when online + sync-enabled + fully pushed — otherwise kept (fixes 3 data-loss cases).
- **Scale:** DB v8 with 9 indexes on hot scope/join columns.
- **Permissions/UI:** subscriber edit/delete respect the `subscribers` permission; lists refresh after collecting a payment; collect dialog can't get stuck on error.

## Not done yet (Phase 2 — needs design/decision, in tasks.md)
Conflict-resolution versioning (lost-updates / resurrected deletes), server-assigned receipt numbers, no-price≠paid + price/category immutability after receipts, count-aggregate + pagination + incremental pull, restore-clears-outbox, device-limit bypass on data routes.
