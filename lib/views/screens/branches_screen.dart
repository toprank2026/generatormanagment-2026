import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/core/api_client.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/data/models/branch_model.dart';
import 'package:generatormanagment/data/repositories/auth_repository.dart';
import 'package:generatormanagment/views/widgets/app_form_field.dart';

/// Owner-only screen for managing branches (create / edit / delete + activate).
/// Each branch is a fully-isolated ERP instance; the active branch drives the
/// whole app's data context. Gated on [AuthController.canMultiBranch] — when the
/// plan doesn't include Multi-Branch only the protected Main Branch exists and
/// this screen shows a locked message.
class BranchesScreen extends StatelessWidget {
  const BranchesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final BranchController controller = Get.find<BranchController>();
    final AuthController auth = Get.find<AuthController>();

    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(
        title: Text(
          'branches'.tr,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        backgroundColor: kAppBlue,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
        actions: [
          // Flash item 8: owner creates a BRANCH login account (own generator
          // name + phone + password); it then logs in from the login screen.
          Obx(() => (auth.isAdmin && auth.canMultiBranch)
              ? IconButton(
                  icon: const Icon(Icons.person_add_alt_1, color: Colors.white),
                  tooltip: 'add_branch_account'.tr,
                  onPressed: _showAddBranchAccountDialog,
                )
              : const SizedBox.shrink()),
        ],
      ),
      body: Obx(() {
        // Owner-only AND plan-gated.
        if (!auth.isAdmin) {
          return _centered('no_permission'.tr);
        }
        if (!auth.canMultiBranch) {
          return _centered('branch_feature_locked'.tr);
        }
        final list = controller.branches;
        if (list.isEmpty) {
          return _centered('no_branches'.tr);
        }
        final activeId = controller.currentBranch.value?.id;
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          itemCount: list.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, i) =>
              _buildBranchTile(controller, list[i], activeId),
        );
      }),
      floatingActionButton: Obx(() {
        if (!auth.isAdmin || !auth.canMultiBranch) {
          return const SizedBox.shrink();
        }
        return FloatingActionButton.extended(
          backgroundColor: kAppBlue,
          icon: const Icon(Icons.add, color: Colors.white),
          label: Text('add_branch'.tr,
              style: const TextStyle(color: Colors.white)),
          onPressed: () => _showAddDialog(controller),
        );
      }),
    );
  }

  Widget _centered(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.blueGrey, fontSize: 16),
          ),
        ),
      );

  Widget _buildBranchTile(
      BranchController controller, Branch b, String? activeId) {
    final bool isActive = b.id == activeId;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: isActive ? Border.all(color: kAppBlue, width: 2) : null,
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: b.active ? Colors.blue[50] : Colors.grey[200],
          child: Icon(
            b.isMainBranch ? Icons.home_work : Icons.account_tree,
            color: b.active ? kAppBlue : Colors.grey,
          ),
        ),
        title: Text(
          b.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          [
            if (b.code != null && b.code!.isNotEmpty) b.code!,
            if (b.isMainBranch) 'main_branch'.tr,
            if (isActive) 'active_branch'.tr,
            if (!b.active) '(${'inactive'.tr})',
          ].join(' · '),
          style: TextStyle(
            color: isActive ? kAppBlue : Colors.blueGrey,
            fontSize: 12,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isActive)
              IconButton(
                icon: const Icon(Icons.check_circle_outline, color: kAppBlue),
                tooltip: 'switch_branch'.tr,
                onPressed: () => controller.setBranch(b),
              ),
            IconButton(
              icon: const Icon(Icons.edit, color: kAppBlue),
              tooltip: 'edit_branch'.tr,
              onPressed: () => _showEditDialog(controller, b),
            ),
            // The Main Branch is protected (owns all legacy data).
            if (!b.isMainBranch)
              IconButton(
                icon: const Icon(Icons.delete, color: Colors.redAccent),
                tooltip: 'delete'.tr,
                onPressed: () => _confirmDelete(controller, b),
              ),
          ],
        ),
        onTap: () => controller.setBranch(b),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // ADD
  // --------------------------------------------------------------------------
  void _showAddDialog(BranchController controller) {
    final nameCtrl = TextEditingController();
    final codeCtrl = TextEditingController();

    Get.dialog(
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('add_branch'.tr),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppTextField(
                controller: nameCtrl,
                label: 'branch_name'.tr,
                icon: Icons.account_tree,
              ),
              const SizedBox(height: 12),
              AppTextField(
                controller: codeCtrl,
                label: 'branch_code'.tr,
                icon: Icons.tag,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Get.back(), child: Text('cancel'.tr)),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: kAppBlue,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final name = nameCtrl.text.trim();
              final code = codeCtrl.text.trim();
              if (name.isEmpty) {
                Get.snackbar('error'.tr, 'fill_all_fields'.tr);
                return;
              }
              Get.back();
              controller.addBranch(name, code: code.isEmpty ? null : code);
            },
            child: Text('add'.tr),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  // ADD BRANCH ACCOUNT (Flash item 8) — a backend login account for a branch
  // (generator name + phone + password). It logs in from the normal login
  // screen; its data is isolated and aggregated under the owner's panel.
  // --------------------------------------------------------------------------
  void _showAddBranchAccountDialog() {
    final genCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final busy = false.obs;

    Get.dialog(
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('add_branch_account'.tr),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppTextField(
                  controller: genCtrl,
                  label: 'generator_name'.tr,
                  icon: Icons.bolt),
              const SizedBox(height: 12),
              AppTextField(
                  controller: phoneCtrl,
                  label: 'phone'.tr,
                  icon: Icons.phone,
                  keyboardType: TextInputType.phone),
              const SizedBox(height: 12),
              AppTextField(
                  controller: passCtrl,
                  label: 'password'.tr,
                  icon: Icons.lock,
                  obscureText: true),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Get.back(), child: Text('cancel'.tr)),
          Obx(() => ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAppBlue,
                  foregroundColor: Colors.white,
                ),
                onPressed: busy.value
                    ? null
                    : () async {
                        final gen = genCtrl.text.trim();
                        final phone = phoneCtrl.text.trim();
                        final pass = passCtrl.text;
                        if (gen.isEmpty || phone.isEmpty || pass.length < 4) {
                          Get.snackbar('error'.tr, 'fill_all_fields'.tr);
                          return;
                        }
                        if (!await ConnectivityService().isOnline()) {
                          Get.snackbar('error'.tr, 'online_only'.tr);
                          return;
                        }
                        busy.value = true;
                        try {
                          await AuthRepository().createBranch(
                              generatorName: gen,
                              phone: phone,
                              password: pass);
                          Get.back();
                          Get.snackbar('branches'.tr, 'branch_account_created'.tr,
                              backgroundColor: Colors.green,
                              colorText: Colors.white);
                        } on ApiException catch (e) {
                          Get.snackbar('error'.tr, e.message);
                        } catch (e) {
                          Get.snackbar('error'.tr, '$e');
                        } finally {
                          busy.value = false;
                        }
                      },
                child: busy.value
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text('create'.tr),
              )),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  // EDIT
  // --------------------------------------------------------------------------
  void _showEditDialog(BranchController controller, Branch b) {
    final nameCtrl = TextEditingController(text: b.name);
    final codeCtrl = TextEditingController(text: b.code ?? '');
    bool active = b.active;

    Get.dialog(
      StatefulBuilder(
        builder: (context, setLocalState) {
          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text('edit_branch'.tr),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppTextField(
                    controller: nameCtrl,
                    label: 'branch_name'.tr,
                    icon: Icons.account_tree,
                  ),
                  const SizedBox(height: 12),
                  AppTextField(
                    controller: codeCtrl,
                    label: 'branch_code'.tr,
                    icon: Icons.tag,
                  ),
                  const SizedBox(height: 8),
                  // The Main Branch must always stay active (it's the default
                  // context + owns all legacy data).
                  if (!b.isMainBranch)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      activeThumbColor: kAppBlue,
                      title: Text('active'.tr),
                      value: active,
                      onChanged: (v) => setLocalState(() => active = v),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Get.back(), child: Text('cancel'.tr)),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAppBlue,
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  final code = codeCtrl.text.trim();
                  if (name.isEmpty) {
                    Get.snackbar('error'.tr, 'fill_all_fields'.tr);
                    return;
                  }
                  Get.back();
                  controller.editBranch(
                    b.id,
                    name: name,
                    code: code,
                    active: b.isMainBranch ? true : active,
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

  // --------------------------------------------------------------------------
  // DELETE
  // --------------------------------------------------------------------------
  void _confirmDelete(BranchController controller, Branch b) {
    Get.defaultDialog(
      title: 'delete'.tr,
      middleText: 'delete_branch_confirm'.tr,
      textConfirm: 'delete'.tr,
      textCancel: 'cancel'.tr,
      confirmTextColor: Colors.white,
      buttonColor: Colors.red,
      onConfirm: () {
        Get.back();
        controller.removeBranch(b.id);
      },
    );
  }
}
