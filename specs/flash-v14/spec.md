# Flash v14 — small, scoped changes (system is stable)

**Mandate:** minimal edits only. Do NOT refactor/redesign/optimize working logic.
Preserve all business logic, sync, permissions, reports, accounting, UI unless a
change is explicitly requested. Backward compatible.

## Requirements
1. **Loading on create** — Board, Circuit, Accountant, settlement ("payment")
   request, and similar: show a loading indicator until the item is fully saved,
   then auto-dismiss BOTH the loading indicator and the dialog. Follow the
   existing busy/spinner pattern (e.g. branches_screen `busy=false.obs`).
2. **No "Main Branch" term** — never display "Main Branch"/"الفرع الرئيسي" as a
   label anywhere (Flutter, Owner Panel, Admin Panel). Show the **generator name**
   from registration instead. (Internal `branch_id`="main" key is unchanged —
   labels only.)
3. **Owner Panel reports per accountant** — show stats **per accountant, all
   listed at once**: each accountant's paid subscribers / unpaid / collected, etc.
   ("paid per accountant" = subscribers that accountant collected from this month
   via `receipts.accountant_id`). Keep the existing branch/overall report intact.
4. **Remove Collection Percentage** — remove the collection-% gauge from the
   reports in BOTH the Flutter app and the Owner Panel.
5. **New branch = registration approval flow** — after picking a plan, the branch
   enters **Pending** and appears in the **Admin Panel** awaiting plan + account
   approval, EXACTLY like a new-account registration. (Builds on v13 independent
   branches; align status/admin-pending with register.)

## Delivery
Spec-kit + read-only mapping + minimal direct edits + adversarial review. Then
change table, reconnect Tikrit, build release APK.
