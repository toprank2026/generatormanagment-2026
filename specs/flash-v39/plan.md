# Flash v39 — plan

Order of work (single editor on shared files; fleets are read-only):

1. **Map** (5-agent read-only fleet): admin settlements screen, accountant
   wallet/history, repo month semantics, owner panel + backend endpoints,
   net-profit formula/keys. → root causes in spec.md.
2. **Item 6 first** (independent of settlement decisions): `date_fmt.dart`,
   translation keys, mechanical conversion of the 8 display sites + both print
   services + panel `fmtDate`.
3. **Data layer**: strict `listAllForOwner`; optional `month` on `history` /
   `pendingCount`; new `monthUnsettled`.
4. **UI/controller**: 3-card grid; month-scoped breakdown/banner;
   `SettlementController` follows the global pricing month (`_monthFollow`).
5. **Backend + panel**: additive settlements month filter in `listUserData`;
   panel sends `month`, UTC-prefix `inMonth` safety net, relabeled cards.
6. **Verify**: new Flutter test (strict isolation + monthUnsettled) and backend
   test (month filter + composition); full suites; analyze; adversarial review
   fleet (4 dims × verify); fix confirmed findings.
7. **Ship**: MILESTONES, change table, Flash-API release APK, commit+push.

Risk controls (production users): every new query param optional; no schema,
sync-engine, lock, or wallet-balance changes; backend change inert until the
new panel is deployed; app changes ride the next APK only.
