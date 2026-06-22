# Flash v13 — roles, independent branches, reports parity, isolation

Big batch. Surfaces: Flutter app, backend, owner panel. **"Admin" = the generator
OWNER login** (the account that created the generator; each branch has its own
owner login). Accountants are its sub-accounts.

## Locked decisions
1. **Admin = generator owner login.** Owner sets pricing & CANNOT bill; accountant
   bills & CANNOT price; accountant **inherits the owner's plan/approval**.
2. **New branch = a brand-new generator registration**: own plan selection,
   **pending backend super-admin approval**, blocked until activated; linked to the
   main account only via `parentOwner`/branch id (for owner-panel switching).
3. **Billing is always accountant-only** — an owner with no accountant cannot bill.

## Requirements
1. **Owner-panel reports = app reports** — same components (gauge, donut, bars,
   stat cards, per-tariff prices), data, and order as `reports_screen.dart`.
2. **Create accountant inherits the owner (Admin)**: plan, activation, approval,
   sync/pull, branch+admin data → can log in directly + sync immediately.
3. **Show the MAIN branch** in the owner-panel switcher (named with the original
   generator name — NOT "Main Branch"), alongside branch sub-accounts. Selecting
   it shows the main account's data.
4. **Create branch = new-account flow** (same steps + **plan selection**); branch
   **waits for super-admin approval**; behaves as a fully independent generator
   linked to the main account by branch id; can change its OWN plan.
5. **Main branch name** = the original generator name (never "Main Branch").
6. **Owner (Admin) cannot bill** subscribers → billing only for accountant role.
7. **Accountant cannot edit pricing** → pricing only for owner/admin role.
8. **Fix settlement "not found"** when approving/rejecting a NON-main-branch
   settlement (decision must target the branch account's mirror, not the owner's).
9. **Reports accountant filter** — selecting an accountant must scope the report
   to that accountant (currently ignored when a branch is selected).
10. **Switch accountant/branch** → confirmation dialog → clear wallet + delete ALL
    SQLite & local data → load the new identity. (Same for branch switching.)
11. **Accountant login-after-logout bug** — after logout, logging back into the
    accountant fails ("password incorrect"). Root-cause + fix. Also branches must
    NOT inherit the parent plan (own plan, changeable) — see #4.
12. **Complete isolation** — branch + accountant data fully isolated, no overlap;
    a branch is an independent generator linked only for owner-panel switching.
13. **Branch creation flow** routes to the account-creation page (same steps),
    differing only by linking via branch/parent id.
14. **Accountant inherits owner+branch data** (plan/activation/approvals/sync/pull/
    branch/admin) so it works immediately. Keep Switch-Between-Accounts.

## Delivery
Spec-kit + read-only mapping workflow + direct coupled edits + adversarial review.
Verify each step. Then table of changes, reconnect Tikrit, build release APK.
