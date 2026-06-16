import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:generatormanagment/controllers/dashboard_controller.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';
import 'package:generatormanagment/views/widgets/shimmer_loading.dart';
import 'package:generatormanagment/views/widgets/branch_selector.dart';
import 'package:generatormanagment/views/screens/subscribers_screen.dart';
import 'package:generatormanagment/views/screens/boards_screen.dart';

/// Compact plan label with the remaining plan time appended as
/// `plan_Ndays` (e.g. `MONTHLY_29days`), or `plan_expired` once past the
/// expiry. Returns just [base] when there is no expiry date.
String _planWithDaysLeft(String base, String? expiresAt) {
  if (expiresAt == null || expiresAt.isEmpty) return base;
  final exp = DateTime.tryParse(expiresAt);
  if (exp == null) return base;
  final left = exp.difference(DateTime.now()).inDays;
  if (left < 0) return '${base}_expired';
  return '${base}_${left}days';
}

/// Compact "last pull" timestamp for the banner: `HH:mm` when it happened
/// today, `d/M HH:mm` otherwise, or `never` when no pull has run yet.
String _formatPullTime(String? iso) {
  final t = iso == null ? null : DateTime.tryParse(iso);
  if (t == null) return 'never'.tr;
  final now = DateTime.now();
  final hm = '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
  final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
  return sameDay ? hm : '${t.day}/${t.month} $hm';
}

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final DashboardController controller = Get.find<DashboardController>();
    final AuthController authController = Get.find<AuthController>();
    final BranchController branchController = Get.find<BranchController>();
    final SyncController syncController = Get.find<SyncController>();

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('images/blue.png', height: 28),
            const SizedBox(width: 8),
            Text(
              'dashboard'.tr,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        elevation: 0,
      ),
      body: RefreshIndicator(
        // Pull-to-refresh (online): re-validate the account/subscription with
        // the server first — if blocked / expired / plan changed, the user is
        // signed out to the login screen with a warning. Otherwise reload stats.
        onRefresh: () async {
          final stillValid = await authController.recheckSession();
          if (stillValid) await controller.loadStats();
        },
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Banner / Carousel Placeholder
              Container(
                height: 330,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(
                    colors: [Colors.blue.shade800, Colors.blue.shade400],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Stack(
                  children: [
                    // Background Pattern
                    Positioned(
                      right: -30,
                      top: -30,
                      child: Icon(
                        Icons.flash_on,
                        size: 150,
                        color: Colors.white.withOpacity(0.15),
                      ),
                    ),
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: 20,
                      top: 20,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                // Headline = the ACTIVE BRANCH name (the
                                // generator's identity for the active branch),
                                // falling back to the account generator name.
                                // Tapping it opens the branch switcher when
                                // Multi-Branch is enabled (title + button).
                                Obx(() {
                                  final branchName =
                                      branchController.currentBranch.value?.name;
                                  final g = authController
                                      .account.value?.generatorName;
                                  final title = (branchName != null &&
                                          branchName.trim().isNotEmpty)
                                      ? branchName
                                      : ((g == null || g.isEmpty)
                                          ? 'generator_name'.tr
                                          : g);
                                  final canSwitch =
                                      authController.canMultiBranch;
                                  return InkWell(
                                    onTap: canSwitch
                                        ? () => openBranchSheet(context)
                                        : null,
                                    borderRadius: BorderRadius.circular(8),
                                    child: Row(
                                      children: [
                                        _bannerIconBox(Icons.account_tree),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            title,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 18,
                                              fontWeight: FontWeight.bold,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (canSwitch)
                                          const Icon(Icons.unfold_more,
                                              color: Colors.white, size: 20),
                                      ],
                                    ),
                                  );
                                }),
                                const SizedBox(height: 10),
                                // Month selector (R11) moved into the banner —
                                // a pill button that opens the date picker.
                                Obx(
                                  () => _bannerChipButton(
                                    icon: Icons.calendar_month,
                                    label: controller.currentMonth.value,
                                    onTap: () async {
                                      DateTime initial = DateTime.now();
                                      final cur = DateTime.tryParse(
                                          '${controller.currentMonth.value}-01');
                                      if (cur != null) initial = cur;
                                      final picked = await showDatePicker(
                                        context: context,
                                        initialDate: initial,
                                        firstDate: DateTime(2020),
                                        lastDate: DateTime(2030),
                                      );
                                      if (picked != null) {
                                        controller.changeMonth(DateFormat(
                                                'yyyy-MM')
                                            .format(picked));
                                      }
                                    },
                                  ),
                                ),
                                const SizedBox(height: 10),
                                // Account / phone (icon + data)
                                _bannerRow(
                                  Icons.phone_android,
                                  Obx(
                                    () => Text(
                                      authController
                                              .currentUser.value?.username ??
                                          '',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                // Current plan name (icon + data)
                                _bannerRow(
                                  Icons.workspace_premium,
                                  Obx(() {
                                    final sub = authController
                                        .account.value?.subscription;
                                    final plan = sub?.planCode;
                                    final base = (plan == null || plan.isEmpty)
                                        ? 'no_plan'.tr
                                        : plan.toUpperCase();
                                    return Text(
                                      _planWithDaysLeft(base, sub?.expiresAt),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    );
                                  }),
                                ),
                                const SizedBox(height: 10),
                                // SYNC area: only shown when the active plan
                                // enables sync. Otherwise the app is in
                                // "offline-only" mode and we show a single
                                // muted row instead of the push/pull rows.
                                Obx(() {
                                  if (!authController.canSync) {
                                    // Offline-only mode: single muted row.
                                    return _bannerRow(
                                      Icons.cloud_off,
                                      Text(
                                        'offline_only_mode'.tr,
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.75),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    );
                                  }

                                  final pending =
                                      syncController.pendingCount.value;
                                  final syncing =
                                      syncController.isSyncing.value;
                                  final pulling =
                                      syncController.isPulling.value;
                                  final busy = syncing || pulling;

                                  return Column(
                                    children: [
                                      // SYNC row: pending-changes status
                                      // (push side) + "sync now" button.
                                      Row(
                                        children: [
                                          _bannerIconBox(
                                            pending == 0
                                                ? Icons.cloud_done
                                                : Icons.cloud_upload,
                                            busy: syncing,
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              syncing
                                                  ? 'syncing'.tr
                                                  : (pending == 0
                                                      ? 'up_to_date'.tr
                                                      : '$pending ${'sync_pending'.tr}'),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          // Push pending local changes.
                                          _bannerButton(
                                            onPressed: busy
                                                ? null
                                                : () => syncController.syncNow(),
                                            busy: syncing,
                                            icon: Icons.sync,
                                            label: 'sync_now'.tr,
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),
                                      // PULL row: last-pull time + "update".
                                      Row(
                                        children: [
                                          _bannerIconBox(
                                            Icons.cloud_download,
                                            busy: pulling,
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              pulling
                                                  ? 'pulling'.tr
                                                  : '${'last_update'.tr}: ${_formatPullTime(syncController.lastPullAt.value)}',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          // Pull the latest server data.
                                          _bannerButton(
                                            onPressed: busy
                                                ? null
                                                : () => syncController.pull(),
                                            busy: pulling,
                                            icon: Icons.cloud_download,
                                            label: 'update_now'.tr,
                                          ),
                                        ],
                                      ),
                                    ],
                                  );
                                }),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Month pricing check: when the selected month/branch has no
              // price set, show a notice. The figures below still recompute
              // (revenue/remaining = 0). The month + branch controls now live
              // in the banner above.
              Obx(() {
                if (controller.hasPriceForMonth.value) {
                  return const SizedBox.shrink();
                }
                return Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFFB74D)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, color: Color(0xFFE65100)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'no_pricing_set_for_month'.tr,
                          style: const TextStyle(
                            color: Color(0xFFE65100),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),

              // Stats Grid
              Text(
                'overview'.tr,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),

              Obx(() {
                if (controller.isLoading.value) {
                  return const DashboardShimmer();
                }

                return GetBuilder<DashboardController>(
                  builder: (ctrl) => GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 1.3,
                    children: [
                      _buildStatCard(
                        icon: Icons.people,
                        color: Colors.blue,
                        label: 'total_subscribers'.tr,
                        value: ctrl.totalSubscribers.value.toString(),
                        onTap: () => Get.to(() => const SubscribersScreen()),
                      ),
                      _buildStatCard(
                        icon: Icons.check_circle,
                        color: Colors.green,
                        label: 'paid_subscribers'.tr,
                        value: ctrl.paidCount.value.toString(),
                        onTap: () => Get.to(
                          () => const SubscribersScreen(filter: 'paid'),
                        ),
                      ),
                      _buildStatCard(
                        icon: Icons.pending_actions,
                        color: Colors.redAccent,
                        label: 'unpaid_subscribers'.tr,
                        value: ctrl.unpaidCount.value.toString(),
                        onTap: () => Get.to(
                          () => const SubscribersScreen(filter: 'unpaid'),
                        ),
                      ),
                      _buildStatCard(
                        icon: Icons.grid_view,
                        color: Colors.indigo,
                        label: 'total_boards'.tr,
                        value: ctrl.boardsCount.value.toString(),
                        onTap: () => Get.to(() => const BoardsScreen()),
                      ),
                      _buildStatCard(
                        icon: Icons.settings_input_component,
                        color: Colors.cyan,
                        label: 'total_circuits'.tr,
                        value: ctrl.circuitsCount.value.toString(),
                        onTap: () =>
                            Get.to(() => const BoardsScreen(forCircuits: true)),
                      ),
                      _buildStatCard(
                        icon: Icons.electric_bolt,
                        color: Colors.orange,
                        label: 'amps'.tr,
                        value: ctrl.totalAmps.value.toStringAsFixed(1),
                      ),
                      _buildStatCard(
                        icon: Icons.account_balance_wallet,
                        color: Colors.green,
                        label: 'monthly_revenue'.tr,
                        value: ctrl.totalCollected.value.toStringAsFixed(0),
                      ),
                      _buildStatCard(
                        icon: Icons.monetization_on,
                        color: Colors.redAccent,
                        label: 'monthly_remaining'.tr,
                        value: ctrl.totalDue.value.toStringAsFixed(0),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  /// A compact white pill button for the banner (e.g. the month selector).
  Widget _bannerChipButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Material(
        color: Colors.white.withOpacity(0.2),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 16),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.expand_more, color: Colors.white, size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// One "icon + data" row for the dashboard header column.
  Widget _bannerRow(IconData icon, Widget data) {
    return Row(
      children: [
        _bannerIconBox(icon),
        const SizedBox(width: 10),
        Expanded(child: data),
      ],
    );
  }

  /// The banner rows' small icon box; shows a white spinner instead of
  /// [icon] while [busy] (the sync/pull rows).
  Widget _bannerIconBox(IconData icon, {bool busy = false}) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(Colors.white),
              ),
            )
          : Icon(icon, color: Colors.white, size: 16),
    );
  }

  /// Compact white action button for the banner's sync/pull rows; shows a
  /// spinner instead of [icon] while [busy].
  Widget _bannerButton({
    required VoidCallback? onPressed,
    required bool busy,
    required IconData icon,
    required String label,
  }) {
    return SizedBox(
      height: 30,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF1565C0),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle:
              const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        ),
        icon: busy
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(Color(0xFF1565C0)),
                ),
              )
            : Icon(icon, size: 16),
        label: Text(label),
      ),
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
    VoidCallback? onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),

      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        value,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      label,
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
