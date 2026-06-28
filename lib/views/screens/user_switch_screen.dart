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
    // Verify BEFORE the destructive wipe — a wrong password must NOT wipe data.
    if (!await auth.verifyOwnerPassword(pwd)) {
      _wrongPassword();
      return;
    }
    if (!await _confirmSwitchWipe()) return;
    await _switchWithWipe(() => auth.switchToOwner(pwd), reloadOwner: true);
  }

  Future<void> _pickAccountant(Accountant a) async {
    final pwd = await _askPassword(a.displayName);
    if (pwd == null) return;
    // Verify BEFORE the wipe (online check if the local credential was wiped).
    if (!await auth.verifyAccountantPassword(a.username, pwd)) {
      _wrongPassword();
      return;
    }
    if (!await _confirmSwitchWipe()) return;
    // loginAsAccountant re-pulls the accountant's data online after the wipe.
    await _switchWithWipe(() => auth.loginAsAccountant(a.username, pwd),
        reloadOwner: false);
  }

  void _wrongPassword() => Get.snackbar('error'.tr, 'wrong_password'.tr,
      snackPosition: SnackPosition.BOTTOM);

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

  /// Wipe ALL local data (incl. wallet/settlements) then load the new identity,
  /// keeping ONE blocking overlay up across the whole wipe→switch→pull sequence
  /// so the user can't act on half-loaded data. Credentials are pre-verified by
  /// the callers, so a failure here is unexpected (and never silently loses data
  /// without a result message).
  Future<void> _switchWithWipe(Future<bool> Function() doSwitch,
      {required bool reloadOwner}) async {
    SyncProgress.show('switching_user'.tr);
    bool ok = false;
    try {
      if (Get.isRegistered<SyncController>()) {
        await Get.find<SyncController>().deleteAllLocalData();
      }
      ok = await doSwitch();
      if (ok) {
        if (reloadOwner && Get.isRegistered<SyncController>()) {
          await Get.find<SyncController>().pull(silent: true);
        }
        if (Get.isRegistered<SettlementController>()) {
          await Get.find<SettlementController>().load();
        }
      }
    } catch (_) {/* best-effort */} finally {
      SyncProgress.hide();
    }
    // Snackbars AFTER the overlay closes (a snackbar while open blocks Get.back).
    if (!ok) {
      _wrongPassword();
      return;
    }
    Get.back();
    Get.snackbar('switch_user'.tr, '${'switched_to'.tr}: ${auth.actingUserName}',
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
      body: SafeArea(
        child: _loading
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
            })),
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
