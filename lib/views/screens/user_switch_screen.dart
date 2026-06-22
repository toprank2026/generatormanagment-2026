import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';
import 'package:generatormanagment/controllers/settlement_controller.dart';
import 'package:generatormanagment/data/models/accountant_model.dart';
import 'package:generatormanagment/data/repositories/accountant_repository.dart';
import 'package:generatormanagment/views/widgets/app_form_field.dart';
import 'package:generatormanagment/views/widgets/sync_progress_overlay.dart';

/// Local profile switch: pick the owner or an accountant sub-user and sign in
/// (offline, password-checked). The owner runs the cloud session; accountants
/// are local sub-users with reduced permissions and per-accountant data.
class UserSwitchScreen extends StatefulWidget {
  const UserSwitchScreen({super.key});

  @override
  State<UserSwitchScreen> createState() => _UserSwitchScreenState();
}

class _UserSwitchScreenState extends State<UserSwitchScreen> {
  final AuthController auth = Get.find();
  final AccountantRepository _repo = AccountantRepository();
  List<Accountant> _accountants = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await _repo.getAll();
    if (!mounted) return;
    setState(() {
      _accountants = list.where((a) => a.active).toList();
      _loading = false;
    });
  }

  Future<void> _pickOwner() async {
    final pwd = await _askPassword(auth.ownerUser.value?.displayName ?? 'owner'.tr);
    if (pwd == null) return;
    if (!await _confirmSwitchWipe()) return;
    await _wipeForSwitch();
    final ok = await auth.switchToOwner(pwd);
    if (ok) await _reloadAfterSwitch();
    _afterSwitch(ok);
  }

  Future<void> _pickAccountant(Accountant a) async {
    final pwd = await _askPassword(a.displayName);
    if (pwd == null) return;
    if (!await _confirmSwitchWipe()) return;
    await _wipeForSwitch();
    // loginAsAccountant re-pulls the accountant's data online after the wipe.
    final ok = await auth.loginAsAccountant(a.username, pwd);
    _afterSwitch(ok);
  }

  /// Req 10: switching accounts clears the wallet + deletes ALL local data, so
  /// confirm first (the wipe is unrecoverable locally; data re-pulls on switch).
  Future<bool> _confirmSwitchWipe() async {
    final ok = await Get.defaultDialog<bool>(
      title: 'switch_user'.tr,
      middleText: 'switch_wipe_warn'.tr,
      textConfirm: 'continue'.tr,
      textCancel: 'cancel'.tr,
      onConfirm: () => Get.back(result: true),
      onCancel: () {},
    );
    return ok == true;
  }

  /// Delete ALL local data (incl. the wallet/settlements tables) behind a
  /// blocking overlay before loading the new identity.
  Future<void> _wipeForSwitch() async {
    SyncProgress.show('switching_user'.tr);
    try {
      if (Get.isRegistered<SyncController>()) {
        await Get.find<SyncController>().deleteAllLocalData();
      }
    } catch (_) {/* best-effort */} finally {
      SyncProgress.hide();
    }
  }

  /// After switching to the OWNER, re-pull its mirror (the wipe emptied local).
  Future<void> _reloadAfterSwitch() async {
    try {
      if (Get.isRegistered<SyncController>()) {
        await Get.find<SyncController>().pull(silent: true);
      }
      if (Get.isRegistered<SettlementController>()) {
        await Get.find<SettlementController>().load();
      }
    } catch (_) {/* best-effort */}
  }

  void _afterSwitch(bool ok) {
    if (!ok) {
      Get.snackbar('error'.tr, 'wrong_password'.tr,
          snackPosition: SnackPosition.BOTTOM);
      return;
    }
    Get.back();
    Get.snackbar('switch_user'.tr,
        '${'switched_to'.tr}: ${auth.actingUserName}',
        snackPosition: SnackPosition.BOTTOM);
  }

  Future<String?> _askPassword(String who) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(who, style: const TextStyle(fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          decoration: appInputDecoration(
            label: 'password'.tr,
            icon: Icons.lock_outline,
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text('cancel'.tr)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kAppBlue),
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text('confirm'.tr),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('switch_user'.tr)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Obx(() {
              final actingId = auth.currentUser.value?.id;
              return ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _tile(
                    icon: Icons.admin_panel_settings,
                    title: auth.ownerUser.value?.displayName ?? 'owner'.tr,
                    subtitle: 'owner'.tr,
                    isCurrent: actingId == auth.ownerUser.value?.id,
                    onTap: _pickOwner,
                  ),
                  if (_accountants.isNotEmpty) const Divider(),
                  ..._accountants.map((a) => _tile(
                        icon: Icons.person,
                        title: a.displayName,
                        subtitle: 'accountant'.tr,
                        isCurrent: actingId == a.id,
                        onTap: () => _pickAccountant(a),
                      )),
                ],
              );
            }),
    );
  }

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isCurrent,
    required VoidCallback onTap,
  }) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: const Color(0xFF1565C0),
          child: Icon(icon, color: Colors.white),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle),
        trailing: isCurrent
            ? const Icon(Icons.check_circle, color: Color(0xFF2E7D32))
            : const Icon(Icons.login, color: Colors.grey),
        onTap: isCurrent ? null : onTap,
      ),
    );
  }
}
