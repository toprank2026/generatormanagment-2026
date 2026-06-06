# Customer Workflow — Moldati Owner

How a real generator-business **owner** uses the app, step by step. The app UI is
in **Arabic (RTL)** with the **Cairo** font; key screen labels are shown in
parentheses. After sign-in the app works **fully offline** — internet is only
needed for sign-up/sign-in, subscription checks, cloud backup, and **syncing your
data to the server** (so the office/admin can view it).

---

## A. First-time setup (online)
1. **Open the app.** It launches in Arabic.
2. **Create an account** — on the login screen tap *“ليس لديك حساب؟ أنشئ حساباً”* (Sign up), then enter **full name, phone, and password** (you sign in with your **phone**). → Your account is created and **this device is registered** to it (a plan allows a limited number of devices).
3. **Choose a subscription plan** (الاشتراك) — pick Trial / Monthly / Yearly. The request goes **pending** until it’s approved.
4. **Wait for approval**, then pull-to-refresh (or *تحقق من حالة الاشتراك*). Once **active (فعّال)** you enter the app.

## B. Build your system (offline OK)
5. **Add Boards** (البوردات) — your electrical boards (press **+ إضافة جديد**). Give each a name/code.
6. **Add Circuits** (الجوزات) under each board — the lines/جوزة on that board.
7. **Add Subscribers** (المشتركين) — for each customer enter name, phone, **amps (أمبير)**, and choose their board + circuit.

## C. Monthly billing cycle
8. **Set the monthly price per amp** (التسعير الشهري) for the current month.
9. **Collect payments** — open a subscriber → the screen shows the **amount due** (amps × price − already paid). Enter the amount → *استلام الدفعة* (Collect) → a **receipt** is created (and can be **printed on a Bluetooth thermal printer**).
10. **Track who paid** — the Dashboard shows **paid / unpaid** counts; the subscribers list can be filtered by paid/unpaid.
11. **View payment history** — open a subscriber → the **history icon** opens *سجل المدفوعات* (a full, paginated list of that subscriber’s paid bills).

## D. Expenses & insight
12. **Record expenses** (المصروفات) — fuel, oil, maintenance, salaries, rent… with quick-add buttons.
13. **Dashboard** (لوحة التحكم) — totals: subscribers, amps, collected revenue, remaining fees, expenses, boards, circuits.

## E. Account & data
14. **Subscription** (الإعدادات → الاشتراك والخطة) — see your current plan, status and dates, and **upgrade / change plan** (ترقية / تغيير الخطة).
15. **Backup** (الإعدادات → النسخ الاحتياطي) — one screen for everything: **cloud backup** (upload / restore / delete, online) and **local export/import** of the database file (offline).
16. **Sync** (الإعدادات → المزامنة) — see sync status, pending changes and last sync, and force **مزامنة الآن (Sync now)**. Data also auto-syncs in the background when online; the dashboard header shows the pending count + a quick Sync-now.
17. **Staff** — the owner can add staff users; **language** (العربية/English) and **printer** are set in Settings.

---

### Notes for the customer
- Your subscribers, billing and expenses live **on your phone** (the source of truth — fully usable offline) and are also **synced to your account on the server** so the office/admin can view them.
- Keep at least one **cloud or local backup** before changing devices.
- Deleting a board/circuit also deletes everything under it (you’ll be warned).
