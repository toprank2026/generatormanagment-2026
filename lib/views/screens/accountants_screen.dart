import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/controllers/settings_controller.dart';
import 'package:generatormanagment/core/permissions.dart';
import 'package:generatormanagment/data/models/accountant_model.dart';
import 'package:generatormanagment/views/widgets/app_form_field.dart';

/// Dedicated owner-only screen for managing accountant sub-users (create / edit
/// / delete + per-accountant permissions). Replaces the inline accountants
/// section that used to live in the Settings screen.
class AccountantsScreen extends StatefulWidget {
  const AccountantsScreen({super.key});

  @override
  State<AccountantsScreen> createState() => _AccountantsScreenState();
}

class _AccountantsScreenState extends State<AccountantsScreen> {
  final SettingsController controller = Get.find<SettingsController>();
  final AuthController auth = Get.find<AuthController>();

  @override
  void initState() {
    super.initState();
    controller.loadAccountants();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(
        title: Text(
          'accountants'.tr,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        backgroundColor: kAppBlue,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
      ),
      // Owner-only: an accountant acting on this device must not manage staff.
      body: SafeArea(child: Obx(() {
        if (!auth.isAdmin) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'no_permission'.tr,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.blueGrey, fontSize: 16),
              ),
            ),
          );
        }
        final list = controller.accountants;
        if (list.isEmpty) {
          return Center(
            child: Text(
              'no_accountants'.tr,
              style: const TextStyle(color: Colors.blueGrey, fontSize: 16),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          itemCount: list.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, i) => _buildAccountantTile(list[i]),
        );
      })),
      floatingActionButton: Obx(() {
        if (!auth.isAdmin) return const SizedBox.shrink();
        return FloatingActionButton.extended(
          backgroundColor: kAppBlue,
          icon: const Icon(Icons.person_add, color: Colors.white),
          label: Text(
            'add_accountant'.tr,
            style: const TextStyle(color: Colors.white),
          ),
          onPressed: _showAddDialog,
        );
      }),
    );
  }

  Widget _buildAccountantTile(Accountant a) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: a.active ? Colors.blue[50] : Colors.grey[200],
          child: Icon(
            Icons.badge,
            color: a.active ? kAppBlue : Colors.grey,
          ),
        ),
        title: Text(
          a.displayName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          a.active ? '@${a.username} · ${'active'.tr}' : '@${a.username}',
          style: TextStyle(
            color: a.active ? Colors.green : Colors.redAccent,
            fontSize: 12,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit, color: kAppBlue),
              tooltip: 'edit_accountant'.tr,
              onPressed: () => _showEditDialog(a),
            ),
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.redAccent),
              tooltip: 'delete'.tr,
              onPressed: () => _confirmDelete(a),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // ADD
  // --------------------------------------------------------------------------
  void _showAddDialog() {
    final nameCtrl = TextEditingController();
    final usernameCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    final selected = <String>{};
    final branch = Get.find<BranchController>();
    // R8: the accountant is tied to a branch. Multi-branch owners pick one;
    // single-branch owners default to the active (Main) branch.
    String selectedBranchId = branch.writeBranchId;
    bool busy = false; // v14: loading state while the accountant is created

    Get.dialog(
      // v22 item 8: barrier locked — dismissing mid-create would strand the
      // in-flight save with its input gone.
      barrierDismissible: false,
      StatefulBuilder(
        builder: (context, setLocalState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Text('add_accountant'.tr),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppTextField(
                    controller: nameCtrl,
                    label: 'full_name'.tr,
                    icon: Icons.person,
                  ),
                  const SizedBox(height: 12),
                  AppTextField(
                    controller: usernameCtrl,
                    label: 'phone'.tr,
                    icon: Icons.phone,
                    keyboardType: TextInputType.phone,
                  ),
                  const SizedBox(height: 12),
                  AppTextField(
                    controller: passwordCtrl,
                    label: 'password'.tr,
                    icon: Icons.lock,
                    obscureText: true,
                  ),
                  // R8: branch selector (multi-branch plans only).
                  if (auth.canMultiBranch && branch.branches.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: branch.branches
                              .any((b) => b.id == selectedBranchId)
                          ? selectedBranchId
                          : branch.branches.first.id,
                      decoration: InputDecoration(
                        labelText: 'branch'.tr,
                        prefixIcon: const Icon(Icons.account_tree),
                        border: const OutlineInputBorder(),
                      ),
                      items: [
                        for (final b in branch.branches)
                          DropdownMenuItem(value: b.id, child: Text(b.name)),
                      ],
                      onChanged: (v) {
                        if (v != null) selectedBranchId = v;
                      },
                    ),
                  ],
                  const SizedBox(height: 16),
                  _buildPermissionsSection(selected, setLocalState),
                  const SizedBox(height: 12),
                  Text(
                    'accountant_login_hint'.tr,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                // v22 item 8: gated while saving; pops THIS dialog's own route
                // (Get.back is swallowed by an open snackbar).
                onPressed:
                    busy ? null : () => Navigator.of(context).pop(),
                child: Text('cancel'.tr),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAppBlue,
                  foregroundColor: Colors.white,
                ),
                // v14: keep the dialog open with a loading spinner until the
                // accountant is fully created, THEN dismiss it (was: close first
                // + fire-and-forget, which could act before the save completed).
                onPressed: busy
                    ? null
                    : () async {
                        final name = nameCtrl.text.trim();
                        final username = usernameCtrl.text.trim();
                        final password = passwordCtrl.text;
                        if (name.isEmpty ||
                            username.isEmpty ||
                            password.trim().isEmpty) {
                          Get.snackbar('error'.tr, 'fill_all_fields'.tr);
                          return;
                        }
                        setLocalState(() => busy = true);
                        final ok = await controller.createAccountant(
                          name,
                          username,
                          password,
                          permissions: selected,
                          branchId: selectedBranchId,
                        );
                        if (!ok) {
                          // Failure: clear the spinner so the owner can fix/
                          // retry (the controller already showed the error);
                          // the dialog stays open with their input.
                          if (context.mounted) {
                            setLocalState(() => busy = false);
                          }
                          return;
                        }
                        // Success: CLOSE the dialog FIRST, THEN snackbar. The
                        // pop targets THIS dialog's own route, so an open
                        // snackbar can't swallow the close (which used to
                        // strand the spinner) and it can never pop a
                        // different route.
                        if (context.mounted) Navigator.of(context).pop();
                        Get.snackbar('success'.tr, 'add_accountant'.tr);
                      },
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text('add'.tr),
              ),
            ],
          );
        },
      ),
    );
  }

  // --------------------------------------------------------------------------
  // EDIT
  // --------------------------------------------------------------------------
  void _showEditDialog(Accountant a) {
    final nameCtrl = TextEditingController(text: a.name ?? '');
    final passwordCtrl = TextEditingController();
    final selected = <String>{...a.permissions};
    bool active = a.active;
    // v22 item 8: busy latch — the save now AWAITS the (online-required)
    // update, keeping the dialog + the user's edits open on failure instead of
    // fire-and-forget discarding them (mirrors the ADD dialog's v14 pattern).
    bool busy = false;

    Get.dialog(
      // v22 item 8: barrier locked (see the ADD dialog).
      barrierDismissible: false,
      StatefulBuilder(
        builder: (context, setLocalState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Text('edit_accountant'.tr),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppTextField(
                    controller: nameCtrl,
                    label: 'full_name'.tr,
                    icon: Icons.person,
                  ),
                  const SizedBox(height: 12),
                  AppTextField(
                    controller: passwordCtrl,
                    label: 'password'.tr,
                    hint: 'leave_blank_keep_password'.tr,
                    icon: Icons.lock,
                    obscureText: true,
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: kAppBlue,
                    title: Text('active'.tr),
                    value: active,
                    onChanged: (v) => setLocalState(() => active = v),
                  ),
                  const SizedBox(height: 8),
                  _buildPermissionsSection(selected, setLocalState),
                ],
              ),
            ),
            actions: [
              TextButton(
                // v22 item 8: gated while saving; pops THIS dialog's own route
                // (Get.back is swallowed by an open snackbar).
                onPressed:
                    busy ? null : () => Navigator.of(context).pop(),
                child: Text('cancel'.tr),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAppBlue,
                  foregroundColor: Colors.white,
                ),
                onPressed: busy
                    ? null
                    : () async {
                        final name = nameCtrl.text.trim();
                        final pwd = passwordCtrl.text.trim();
                        // v23 §3.3: resetting the accountant's password must be
                        // authorized with the OWNER's OWN password.
                        String? ownerPwd;
                        if (pwd.isNotEmpty) {
                          if (pwd.length < 4) {
                            Get.snackbar('error'.tr, 'password_too_short'.tr,
                                snackPosition: SnackPosition.BOTTOM);
                            return;
                          }
                          ownerPwd = await _askOwnerPassword();
                          if (ownerPwd == null || ownerPwd.isEmpty) {
                            return; // cancelled — keep the dialog open
                          }
                          // Fast local reject when an offline owner-hash exists
                          // (the backend is the authoritative gate).
                          if (!await auth.verifyOwnerPassword(ownerPwd)) {
                            Get.snackbar('error'.tr, 'wrong_password'.tr,
                                snackPosition: SnackPosition.BOTTOM);
                            return;
                          }
                        }
                        setLocalState(() => busy = true);
                        final ok = await controller.updateAccountant(
                          a.id,
                          name: name,
                          active: active,
                          newPassword: pwd.isEmpty ? null : pwd,
                          ownerPassword: ownerPwd,
                          permissions: selected,
                        );
                        if (ok) {
                          // Close FIRST (via this dialog's own route — immune
                          // to the snackbar swallow), snackbar after.
                          if (context.mounted) Navigator.of(context).pop();
                          Get.snackbar('success'.tr, 'edit_accountant'.tr);
                        } else {
                          // Failure: keep the dialog + edits open to retry
                          // (updateAccountant already snackbared the error).
                          if (context.mounted) {
                            setLocalState(() => busy = false);
                          }
                        }
                      },
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Text('save'.tr),
              ),
            ],
          );
        },
      ),
    );
  }

  /// v23 §3.3: prompts the owner to re-enter their OWN password to authorize an
  /// accountant password reset. Returns the entered value, or null on cancel.
  Future<String?> _askOwnerPassword() {
    final ctrl = TextEditingController();
    return Get.dialog<String>(
      // barrierDismissible:false + close via the dialog's own route (R-GETX).
      barrierDismissible: false,
      StatefulBuilder(
        builder: (context, setLocal) {
          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text('confirm_identity'.tr),
            content: TextField(
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              onChanged: (_) => setLocal(() {}),
              onSubmitted: (v) {
                if (v.trim().isNotEmpty) {
                  Navigator.of(context).pop(v.trim());
                }
              },
              decoration: InputDecoration(
                labelText: 'current_password'.tr,
                prefixIcon: const Icon(Icons.lock_outline, color: kAppBlue),
                border: const OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('cancel'.tr),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: kAppBlue, foregroundColor: Colors.white),
                onPressed: ctrl.text.trim().isEmpty
                    ? null
                    : () => Navigator.of(context).pop(ctrl.text.trim()),
                child: Text('continue'.tr),
              ),
            ],
          );
        },
      ),
    );
  }

  /// The shared permissions checkbox group used by both dialogs. Mutates
  /// [selected] in place and rebuilds via the dialog's [setLocalState].
  Widget _buildPermissionsSection(
    Set<String> selected,
    void Function(void Function()) setLocalState,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            'permissions'.tr,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.blueGrey,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: Text(
            'permissions_hint'.tr,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        for (final p in Perm.all)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            activeColor: kAppBlue,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text('perm_$p'.tr),
            value: selected.contains(p),
            onChanged: (checked) => setLocalState(() {
              if (checked == true) {
                selected.add(p);
              } else {
                selected.remove(p);
              }
            }),
          ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // DELETE
  // --------------------------------------------------------------------------
  void _confirmDelete(Accountant a) {
    Get.defaultDialog(
      title: 'delete'.tr,
      middleText: 'delete_confirm'.tr,
      textConfirm: 'delete'.tr,
      textCancel: 'cancel'.tr,
      confirmTextColor: Colors.white,
      buttonColor: Colors.red,
      onConfirm: () {
        Get.back();
        controller.deleteAccountant(a.id);
      },
    );
  }
}
