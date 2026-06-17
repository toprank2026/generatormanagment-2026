import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';
import 'package:generatormanagment/data/models/branch_model.dart';
import 'package:generatormanagment/views/screens/branches_screen.dart';

/// Active-branch selector card (dashboard). Switching the active branch swaps
/// the WHOLE app data context (full isolation) — controllers listen on
/// [BranchController.currentBranch] and reload. Renders only when the plan
/// includes Multi-Branch (`auth.canMultiBranch`); otherwise the app silently
/// stays on the single Main Branch and nothing is shown.
///
/// The dashboard now hosts the switcher as a button INSIDE the top banner (see
/// [openBranchSheet]); this standalone card is kept for any other entry points.
class BranchSelector extends StatelessWidget {
  const BranchSelector({super.key});

  @override
  Widget build(BuildContext context) {
    final BranchController branch = Get.find<BranchController>();
    final AuthController auth = Get.find<AuthController>();

    return Obx(() {
      if (!auth.canMultiBranch) return const SizedBox.shrink();
      final current = branch.currentBranch.value;
      final label = current?.name ?? 'all_branches_consolidated'.tr;
      final consolidated = current == null;
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => openBranchSheet(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF1565C0)),
            ),
            child: Row(
              children: [
                Icon(consolidated ? Icons.dashboard : Icons.account_tree,
                    color: const Color(0xFF1565C0)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'active_branch'.tr,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.blueGrey),
                      ),
                      Text(
                        label,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.unfold_more, color: Color(0xFF1565C0)),
              ],
            ),
          ),
        ),
      );
    });
  }
}

/// Opens the "switch branch" bottom sheet (branches + consolidated + manage).
/// Shared by the standalone [BranchSelector] card and the dashboard banner's
/// branch button.
void openBranchSheet(BuildContext context) {
  const kAppBlue = Color(0xFF1565C0);
  final BranchController branch = Get.find<BranchController>();
  final AuthController auth = Get.find<AuthController>();
  Get.bottomSheet(
      Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Obx(() {
          final currentId = branch.currentBranch.value?.id;
          final consolidated = branch.currentBranch.value == null;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 8),
                child: Text('switch_branch'.tr,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final Branch b in branch.branches)
                      ListTile(
                        leading: Icon(
                          b.isMainBranch ? Icons.home_work : Icons.account_tree,
                          color: b.id == currentId ? kAppBlue : Colors.grey,
                        ),
                        title: Text(b.name),
                        trailing: b.id == currentId
                            ? const Icon(Icons.check_circle, color: kAppBlue)
                            : null,
                        onTap: () {
                          Get.back();
                          // R7: clear local + pull this branch's data from the
                          // server (offline → local-only switch). Shows a
                          // blocking progress overlay.
                          Get.find<SyncController>().switchBranch(b);
                        },
                      ),
                    // Consolidated (All branches) — owner reporting only.
                    if (auth.isAdmin) ...[
                      const Divider(height: 1),
                      ListTile(
                        leading: Icon(Icons.dashboard,
                            color: consolidated ? kAppBlue : Colors.grey),
                        title: Text('all_branches_consolidated'.tr),
                        subtitle: Text('consolidated_hint'.tr,
                            style: const TextStyle(fontSize: 11)),
                        trailing: consolidated
                            ? const Icon(Icons.check_circle, color: kAppBlue)
                            : null,
                        onTap: () {
                          Get.back();
                          Get.find<SyncController>().switchBranch(null);
                        },
                      ),
                    ],
                  ],
                ),
              ),
              if (auth.isAdmin)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    icon: const Icon(Icons.settings, color: kAppBlue),
                    label: Text('branches'.tr,
                        style: const TextStyle(color: kAppBlue)),
                    onPressed: () {
                      Get.back();
                      Get.to(() => const BranchesScreen());
                    },
                  ),
                ),
            ],
          );
        }),
      ),
      isScrollControlled: true,
    );
}
