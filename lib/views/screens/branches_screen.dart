import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/core/api_client.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/data/repositories/auth_repository.dart';
import 'package:generatormanagment/data/repositories/subscription_repository.dart';
import 'package:generatormanagment/data/models/plan.dart';
import 'package:generatormanagment/views/widgets/app_form_field.dart';

/// Flash items 6/7/8: a branch is its OWN login account (generator name + phone
/// + password) created by the owner here. There is NO in-app branch switching —
/// to use a branch you log in with its credentials from the login screen; the
/// Owner Panel is where you switch between branches to view their data. So this
/// screen only CREATES + LISTS the owner's branch accounts (read-only).
class BranchesScreen extends StatefulWidget {
  const BranchesScreen({super.key});

  @override
  State<BranchesScreen> createState() => _BranchesScreenState();
}

class _BranchesScreenState extends State<BranchesScreen> {
  final AuthController auth = Get.find<AuthController>();
  final AuthRepository _repo = AuthRepository();

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _branches = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!auth.isAdmin || !auth.canMultiBranch) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _repo.listBranches();
      if (!mounted) return;
      setState(() {
        _branches = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(
        title: Text('branches'.tr,
            style: const TextStyle(
                fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: kAppBlue,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
      ),
      floatingActionButton: (auth.isAdmin && auth.canMultiBranch)
          ? FloatingActionButton.extended(
              backgroundColor: kAppBlue,
              icon: const Icon(Icons.person_add_alt_1, color: Colors.white),
              label: Text('add_branch_account'.tr,
                  style: const TextStyle(color: Colors.white)),
              onPressed: _showAddBranchAccountDialog,
            )
          : null,
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (!auth.isAdmin) return _centered('no_permission'.tr);
    if (!auth.canMultiBranch) return _centered('branch_feature_locked'.tr);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _centered(_error!);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          // Explains the no-switch model (login screen to use, owner panel to switch).
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF8E1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFFFE082)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: Color(0xFFFF8F00)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('branch_login_hint'.tr,
                      style: const TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_branches.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: _centered('no_branch_accounts'.tr),
            )
          else
            ..._branches.map(_branchTile),
        ],
      ),
    );
  }

  Widget _branchTile(Map<String, dynamic> b) {
    final name = (b['generatorName'] ?? b['name'] ?? b['phone'] ?? '').toString();
    final phone = (b['phone'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: Color(0xFFE3F2FD),
          child: Icon(Icons.account_tree, color: kAppBlue),
        ),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: phone.isEmpty
            ? null
            : Row(children: [
                const Icon(Icons.phone, size: 14, color: Colors.blueGrey),
                const SizedBox(width: 4),
                Text(phone,
                    style:
                        const TextStyle(color: Colors.blueGrey, fontSize: 12)),
              ]),
      ),
    );
  }

  Widget _centered(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.blueGrey, fontSize: 16)),
        ),
      );

  // Flash item 8: create a branch login account (generator name + phone + pass).
  void _showAddBranchAccountDialog() {
    final genCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final busy = false.obs;
    // v13: a branch is an independent generator — pick its OWN plan (it then
    // waits for super-admin approval, like a brand-new account).
    final plans = <Plan>[].obs;
    final selectedPlan = RxnString();
    SubscriptionRepository().getPlans().then((p) {
      plans.assignAll(p.where((x) => x.active));
    }).catchError((_) {});

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
              const SizedBox(height: 12),
              Obx(() => DropdownButtonFormField<String>(
                    initialValue: selectedPlan.value,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'select_plan'.tr,
                      prefixIcon: const Icon(Icons.workspace_premium),
                      border: const OutlineInputBorder(),
                    ),
                    items: plans
                        .map((p) => DropdownMenuItem(
                            value: p.code, child: Text(p.name)))
                        .toList(),
                    onChanged: (v) => selectedPlan.value = v,
                  )),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Get.back(), child: Text('cancel'.tr)),
          Obx(() => ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: kAppBlue, foregroundColor: Colors.white),
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
                          await _repo.createBranch(
                              generatorName: gen,
                              phone: phone,
                              password: pass,
                              planCode: selectedPlan.value);
                          Get.back();
                          Get.snackbar('branches'.tr, 'branch_account_created'.tr,
                              backgroundColor: Colors.green,
                              colorText: Colors.white);
                          _load(); // refresh the list
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
}
