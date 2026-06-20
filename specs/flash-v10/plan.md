# Plan — Flash v10

## Execution model (repo rule: no parallel editors on coupled files)
- **Backend (disjoint)** → one dedicated agent: branch sub-account model (8) + owner-panel per-branch backend (7). Edits confined to `backend/`, keeps `npm test` green.
- **Flutter (coupled)** → edited directly by me, one workstream at a time, `flutter analyze`+`flutter test` after each, committed per workstream.
- **Adversarial review** + **on-device test** before/after commits.

## Branch sub-account design (decided: owner-created)
- A **branch** = a backend `User` with `parentOwner` ref → the creating owner; role behaves owner-like for its OWN mirror (own data, own accountants). Logs in via the normal login screen.
- **Creation:** `POST /api/account/branches` (owner-authed) → creates the branch User (username=phone, password, generatorName, parentOwner). Owner lists via `GET /api/account/branches`.
- **Scoping:** branch's sync/backup mirror keyed by the branch user id (its own). Parent owner panel reads across `parentOwner == me` accounts; can view a chosen branch's data/stats (parent-authed, must own that branch).
- **Device lifecycle (6):** logging into / switching a branch online → wipe ALL local SQLite (incl. accountants/users) → pull that branch's mirror; offline → confirm dialog.

## Order (this batch)
1. Spec-Kit (done).
2. Backend agent: items 8 + 7 (background).
3. Flutter contained, committed each: (1) reports paid-counts, (4) collection %, (10) pricing confirm, (5) pricing day picker [schema v10], (9) auto-sync-after-write, (2) logout wipe policy, (3) rebrand text.
4. Flutter branch model wiring: branch creation UI (owner), branch login auto-pull, switch-wipe lifecycle (6/8), owner-panel branch switcher (7 frontend).
5. Verify both suites + on-device test + build release.

## Risk controls
- Schema change (5) = additive `start_date` on monthly_prices, version bump v9→v10, idempotent `_addColumn`.
- Logout/branch-wipe relaxes the v9 pendingCount guard ONLY for the online case AFTER a push attempt (offline → confirm dialog, never silent loss).
- Do not change sync triggers/outbox/drain.
