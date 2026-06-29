# Flash v18 — device rebind confirm + dialog dispose + branch count + sync settings

Mandate: do NOT modify existing sync flow, feature inheritance, subscriptions,
or business logic. ONLY these four changes. Backward compatible.

## 1. Device unbind/rebind confirmation
Before **Logout**, **Create branch**, **Create accountant**, show a confirm
dialog explaining the device is bound to the current account and must be
unbound+rebound to let another account/branch/accountant use it. Integrate into
the existing logout confirm where one exists; else a separate dialog.
- Message: "This device is currently linked to another account. To allow a
  different account, branch, or accountant to use this device, the current
  device binding must be removed and recreated. Do you want to continue?"
- **Continue**: remove the current device binding (server unbind) + clear local
  device-binding data + run the existing fresh-registration device binding flow.
- **Cancel**: abort the operation.
Goal: avoid the DEVICE_LIMIT error. Reuse the EXISTING device flow — do not
invent a new binding scheme.

## 2. Proper dispose of loading dialogs / overlays
For create-circuit, create-board, logout, create-branch, create-accountant,
sync/upload, and any loading-dialog op: always close on success AND failure
(try/catch/finally, cleanup in finally), check context/`Get.isDialogOpen`
before pop, prevent stacked dialogs, dispose related controllers/timers/overlays.
No behavior change otherwise.

## 3. Owner-panel branch count
The Owner Panel shows branch count "1" instead of the real number. Show the
total branches under the original owner (all linked branches). Backend/panel fix.

## 4. Simplify sync options in Settings
In the Flutter Settings page, keep ONLY **Export Names** + **Import Names** under
the sync section; remove all other sync actions from the Settings UI.

## Delivery
Spec + read-only mapping + coupled edits (Flutter + backend/owner-panel) +
adversarial review. Then table, confirm Flash API, build APK.
