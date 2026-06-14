import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
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
      body: Obx(() {
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
      }),
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

    Get.dialog(
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
                    label: 'username'.tr,
                    icon: Icons.alternate_email,
                  ),
                  const SizedBox(height: 12),
                  AppTextField(
                    controller: passwordCtrl,
                    label: 'password'.tr,
                    icon: Icons.lock,
                    obscureText: true,
                  ),
                  const SizedBox(height: 16),
                  _buildPermissionsSection(selected, setLocalState),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Get.back(),
                child: Text('cancel'.tr),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAppBlue,
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  final username = usernameCtrl.text.trim();
                  final password = passwordCtrl.text;
                  if (name.isEmpty ||
                      username.isEmpty ||
                      password.trim().isEmpty) {
                    Get.snackbar('error'.tr, 'fill_all_fields'.tr);
                    return;
                  }
                  Get.back();
                  controller.createAccountant(
                    name,
                    username,
                    password,
                    permissions: selected,
                  );
                },
                child: Text('add'.tr),
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

    Get.dialog(
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
                onPressed: () => Get.back(),
                child: Text('cancel'.tr),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAppBlue,
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  final pwd = passwordCtrl.text.trim();
                  Get.back();
                  controller.updateAccountant(
                    a.id,
                    name: name,
                    active: active,
                    newPassword: pwd.isEmpty ? null : pwd,
                    permissions: selected,
                  );
                },
                child: Text('save'.tr),
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
