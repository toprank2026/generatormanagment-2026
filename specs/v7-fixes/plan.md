# Plan — v7 Fix Batch

## Key decisions / assumptions
1. **Global month** = new permanent `MonthController` (`Rx<String> selectedMonth`, `setMonth`), registered in `app_binding.dart` next to `BranchController`. Dashboard & Billing delete their own month fields and consume + `ever()`-react to it. (Chosen over promoting `BillingController` because it is `lazyPut`, not permanent.) Month is **not** persisted across restarts (resets to current month on launch) — acceptable.
2. **Month picker** lives only on the Monthly Pricing screen. The dashboard banner pill and the subscriber-detail picker become read-only displays. Expenses keeps its own month (out of the stated scope) — noted, not changed, to limit blast radius.
3. **Category tab bar**: 4 tabs (All · Gold · Regular(standard) · Commercial). "All" preserves current default. New key `all_categories`.
4. **Circuit uniqueness** = per board (feeds are children of a board). Board uniqueness = per branch. Both use `IFNULL(branch_id,'main')` so legacy NULL-branch rows map to Main.
5. **Branch switch**: full `deleteLocalData()` + full account `pull()` when online & `canSync`; push pending first; abort (local-only switch + snackbar) when offline or push fails. Re-resolve the target branch from the freshly-pulled `branches` after the wipe; set `currentBranch` only **after** pull so reactive loaders don't query an emptied DB.
6. **Accountant** stays linked by its app-side UUID (`localId`). Backend stores `localId` on the accountant `User` and round-trips it on login so business rows the accountant creates carry the same `accountant_id` the owner already sees in the mirror. Effective-owner sync means the accountant operates on the owner's mirror. Accountants are **exempt** from the owner's device limit and inherit the owner's subscription/features.
7. **R2** needs no code change — add a test only.

## API contract (backend ↔ app)
New/changed endpoints (see `backend/API_CONTRACT.md` for canonical form):

- `POST /api/account/accountants` — auth: owner/admin. Body `{ name, username, password, branchId, permissions: string[], localId }`. → `201 { accountant: { id, localId, name, username, branchId, permissions, active } }`. `409 USERNAME_TAKEN`.
- `GET /api/account/accountants` → `{ accountants: [...] }` (owner's sub-accounts).
- `PUT /api/account/accountants/:id` — body any of `{ name, permissions, branchId, active, password }`.
- `DELETE /api/account/accountants/:id`.
- `POST /api/auth/login` (extended) — if the user is role `accountant`: bcrypt verify, **skip device binding/limit**, resolve subscription/features from `owner`, return account `{ id, role:'accountant', ownerId, branchId, permissions, localId, ... , subscription }`.
- `GET /api/auth/me` — returns the accountant shape for accountant tokens.
- `serializeAccount` adds: `role`, `ownerId`, `branchId`, `permissions`, `localId`.
- **Effective-owner scoping** in `syncController` (push/pull) and `accountController` (getMyData/getMyStats/getMyRecent): `ownerId = req.user.role==='accountant' ? req.user.owner : req.user._id`.

App `Account` model gains `role` ('owner'|'admin'|'accountant'), `ownerId`, `branchId`, `permissions`, `localId`. `AuthController.login` maps an accountant account → acting user (id = `localId`, role accountant, permissions), sets `BranchController` to `branchId`, then triggers a pull.

## Workstreams & file ownership (collision-aware)
- **W-BACKEND** (background agent, `backend/` only): R8 backend + panel category column + `SEARCH_FIELDS` + API_CONTRACT.md + CLAUDE.md doc fix + backend tests. Disjoint from `lib/`.
- **W-FLUTTER** (main session, sequential — these share `core_controller.dart`, `core_repositories.dart`, `billing_controller.dart`, `monthly_pricing_screen.dart`, `translations.dart`, so they are NOT parallelized): R9/R6 → R4 → R5/R3 → R1 → R7/R7b → R8 app integration.
- Per CLAUDE.md: no `git` mutations from agents; the backend agent edits only `backend/`.

## Verification
`flutter analyze` (expect 0 errors), `flutter test`, `cd backend && npm test`. Then an adversarial review workflow over the full diff (month sync correctness, positional-SQL category arg, branch-switch offline/empty-DB races, accountant effective-owner scoping). Live smoke on device for month sync + branch switch.
