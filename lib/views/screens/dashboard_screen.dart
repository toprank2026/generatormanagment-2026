import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/dashboard_controller.dart';
import 'package:generatormanagment/utils/money.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';
import 'package:generatormanagment/views/widgets/shimmer_loading.dart';
import 'package:generatormanagment/views/screens/subscribers_screen.dart';
import 'package:generatormanagment/views/screens/boards_screen.dart';

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
      body: SafeArea(
          child: RefreshIndicator(
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
                    // Background Pattern — v26 item 3: the transparent bolt
                    // moved from the RIGHT side to the LEFT (physical sides;
                    // nothing else about the card changed).
                    Positioned(
                      left: -30,
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
                                  final cur = branchController.currentBranch.value;
                                  final branchName = cur?.name;
                                  final g = authController
                                      .account.value?.generatorName;
                                  // v14: never show the literal "main branch"
                                  // name — for the MAIN branch use the generator
                                  // name from registration; other branches keep
                                  // their own name.
                                  final isMain = cur?.isMainBranch ?? true;
                                  final String title;
                                  if (isMain) {
                                    // Main branch: generator name, NEVER the
                                    // stored "main branch" literal. No generator
                                    // name yet → neutral fallback (not the name).
                                    title = (g != null && g.trim().isNotEmpty)
                                        ? g
                                        : 'generator_name'.tr;
                                  } else if (branchName != null &&
                                      branchName.trim().isNotEmpty) {
                                    title = branchName;
                                  } else {
                                    title = (g == null || g.isEmpty)
                                        ? 'generator_name'.tr
                                        : g;
                                  }
                                  // Flash: NO in-app branch switching — a branch
                                  // is a separate account (log in from the login
                                  // screen to use it); switching between branches
                                  // to view is in the Owner Panel. So this banner
                                  // is display-only.
                                  return InkWell(
                                    onTap: null,
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
                                      ],
                                    ),
                                  );
                                }),
                                const SizedBox(height: 10),
                                // Month is READ-ONLY here (R9): it is selected
                                // only on the Monthly Pricing screen and shown
                                // on Home as information. Tapping does nothing.
                                Obx(
                                  () => _bannerMonthChip(
                                    controller.currentMonth.value,
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
                                    // v15: show SERVER-computed REMAINING days
                                    // (not the total duration); never the local
                                    // clock. Expired/0 -> expired label.
                                    final rem = sub?.remainingDays;
                                    final expired = sub?.status == 'expired' ||
                                        (rem != null && rem <= 0);
                                    final String label = expired
                                        ? '$base • ${'subscription_expired'.tr}'
                                        : (rem != null
                                            ? '$base • $rem ${'days_left'.tr}'
                                            : base);
                                    return Text(
                                      label,
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
                  builder: (ctrl) {
                    // v16: responsive sizing by screen width (tablet vs phone);
                    // card height adapts (no fixed 1.3 ratio) + numbers are
                    // FittedBox-safe, so big numbers never get clipped.
                    // v19: PHONES (<600) keep the EXACT current sizing; only
                    // TABLETS / large landscape screens adapt — more columns +
                    // bigger icons/text/padding + a height derived from a target
                    // so cards never balloon with tiny content.
                    final double w = MediaQuery.of(context).size.width;
                    final bool isTablet = w >= 600;
                    final bool isLarge = w >= 1000;
                    final int columns = isLarge ? 4 : (isTablet ? 3 : 2);
                    final double iconSize = isLarge ? 36 : (isTablet ? 32 : 24);
                    final double gridValueFont =
                        isLarge ? 30 : (isTablet ? 27 : 23);
                    final double labelFont = isLarge ? 16 : (isTablet ? 15 : 13);
                    final double cardPad = isLarge ? 18 : (isTablet ? 16 : 12);
                    final double spacing = isTablet ? 18 : 16;
                    // Phone keeps the exact 1.08 ratio; tablets derive the ratio
                    // from a TARGET card height so cards stay compact as the
                    // column count grows (32 = the scroll view's 16px side pad).
                    double aspect = 1.08;
                    if (isTablet) {
                      final double avail = w - 32 - (columns - 1) * spacing;
                      final double cardW = avail / columns;
                      final double targetH = isLarge ? 150 : 140;
                      aspect = cardW / targetH;
                    }
                    final double fullCardH =
                        isLarge ? 160 : (isTablet ? 140 : 110);
                    final double moneyValueFont =
                        isLarge ? 46 : (isTablet ? 40 : 30);
                    return Column(
                      children: [
                        GridView.count(
                          crossAxisCount: columns,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          mainAxisSpacing: spacing,
                          crossAxisSpacing: spacing,
                          childAspectRatio: aspect,
                          children: [
                            _buildStatCard(
                              icon: Icons.people,
                              color: Colors.blue,
                              label: 'total_subscribers'.tr,
                              value: ctrl.totalSubscribers.value.toString(),
                              iconSize: iconSize,
                              valueFontSize: gridValueFont,
                              labelFontSize: labelFont,
                              padding: cardPad,
                              onTap: () =>
                                  Get.to(() => const SubscribersScreen()),
                            ),
                            _buildStatCard(
                              icon: Icons.check_circle,
                              color: Colors.green,
                              label: 'paid_subscribers'.tr,
                              value: ctrl.paidCount.value.toString(),
                              iconSize: iconSize,
                              valueFontSize: gridValueFont,
                              labelFontSize: labelFont,
                              padding: cardPad,
                              onTap: () => Get.to(
                                () => const SubscribersScreen(filter: 'paid'),
                              ),
                            ),
                            _buildStatCard(
                              icon: Icons.pending_actions,
                              color: Colors.redAccent,
                              label: 'unpaid_subscribers'.tr,
                              value: ctrl.unpaidCount.value.toString(),
                              iconSize: iconSize,
                              valueFontSize: gridValueFont,
                              labelFontSize: labelFont,
                              padding: cardPad,
                              onTap: () => Get.to(
                                () => const SubscribersScreen(filter: 'unpaid'),
                              ),
                            ),
                            _buildStatCard(
                              icon: Icons.grid_view,
                              color: Colors.indigo,
                              label: 'total_boards'.tr,
                              value: ctrl.boardsCount.value.toString(),
                              iconSize: iconSize,
                              valueFontSize: gridValueFont,
                              labelFontSize: labelFont,
                              padding: cardPad,
                              onTap: () => Get.to(() => const BoardsScreen()),
                            ),
                            _buildStatCard(
                              icon: Icons.settings_input_component,
                              color: Colors.cyan,
                              label: 'total_circuits'.tr,
                              value: ctrl.circuitsCount.value.toString(),
                              iconSize: iconSize,
                              valueFontSize: gridValueFont,
                              labelFontSize: labelFont,
                              padding: cardPad,
                              onTap: () => Get.to(
                                  () => const BoardsScreen(forCircuits: true)),
                            ),
                            _buildStatCard(
                              icon: Icons.electric_bolt,
                              color: Colors.orange,
                              label: 'amps'.tr,
                              value: ctrl.totalAmps.value.toStringAsFixed(1),
                              iconSize: iconSize,
                              valueFontSize: gridValueFont,
                              labelFontSize: labelFont,
                              padding: cardPad,
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // v32 item 1: Σ amps of PAID vs UNPAID subscribers per
                        // tariff (gold/standard/commercial) + group totals —
                        // the two groups partition the total-amps card above.
                        _ampsByStatusCard(ctrl),
                        const SizedBox(height: 16),
                        // v16 item 4/5: Collected + Remaining span the FULL row
                        // (only these two) so large amounts show clearly.
                        // v19: amounts use thousands separators (fmtAmount).
                        SizedBox(
                          width: double.infinity,
                          height: fullCardH,
                          child: _buildStatCard(
                            icon: Icons.account_balance_wallet,
                            color: Colors.green,
                            label: 'monthly_revenue'.tr,
                            value: fmtAmount(ctrl.totalCollected.value),
                            iconSize: iconSize,
                            valueFontSize: moneyValueFont,
                            labelFontSize: labelFont,
                            padding: cardPad,
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          height: fullCardH,
                          child: _buildStatCard(
                            icon: Icons.monetization_on,
                            color: Colors.redAccent,
                            label: 'monthly_remaining'.tr,
                            value: fmtAmount(ctrl.totalDue.value),
                            iconSize: iconSize,
                            valueFontSize: moneyValueFont,
                            labelFontSize: labelFont,
                            padding: cardPad,
                          ),
                        ),
                        const SizedBox(height: 16),
                        // v32 item 2: total APPROVED DISCOUNTS this month —
                        // read-only aggregate of receipts.discount_value.
                        SizedBox(
                          width: double.infinity,
                          height: fullCardH,
                          child: _buildStatCard(
                            icon: Icons.discount,
                            color: const Color(0xFF6A1B9A),
                            label: 'total_discounts'.tr,
                            value: fmtAmount(ctrl.totalDiscounts.value),
                            iconSize: iconSize,
                            valueFontSize: moneyValueFont,
                            labelFontSize: labelFont,
                            padding: cardPad,
                          ),
                        ),
                      ],
                    );
                  },
                );
              }),
            ],
          ),
        ),
      )),
    );
  }

  /// A compact, READ-ONLY white pill showing the selected month in the banner
  /// (R9). The month is chosen only on the Monthly Pricing screen; here it is
  /// information only, so there is no tap/picker.
  Widget _bannerMonthChip(String label) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.2),
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.calendar_month, color: Colors.white, size: 16),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
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

  /// v32 item 1: Σ subscriber AMPS per tariff, split PAID vs UNPAID — two
  /// side-by-side groups (green/red), each with gold/standard/commercial rows
  /// and its own total. paidTotal + unpaidTotal == the total-amps card (both
  /// derive from the same category-aware coverage rule).
  Widget _ampsByStatusCard(DashboardController ctrl) {
    // One decimal everywhere — matches the total-amps grid card ("120.0") and
    // the report's per-tariff amps cards, so the partition reconciles visually.
    String fmtAmps(double v) => v.toStringAsFixed(1);

    // v34 item 7: styled like the other dashboard cards — same white surface,
    // radius-16 + soft shadow, tinted rounded ICON CHIP header, grey labels.
    Widget group(String title, IconData icon, Color color,
        Map<String, double> byCat) {
      final double gold = byCat['gold'] ?? 0;
      final double standard = byCat['standard'] ?? 0;
      final double commercial = byCat['commercial'] ?? 0;
      // Group total folds EVERY category in the map (any legacy/unknown value
      // included), so the two group totals always sum to totalAmps exactly.
      final double total = byCat.values.fold(0.0, (s, a) => s + a);
      Widget row(String label, double v, {bool bold = false}) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              bold ? FontWeight.bold : FontWeight.w500,
                          color: bold ? color : Colors.grey[600])),
                ),
                Text(fmtAmps(v),
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                        color: bold ? color : Colors.black87)),
              ],
            ),
          );
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: color, size: 16),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: color)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            row('cat_gold'.tr, gold),
            row('cat_standard'.tr, standard),
            row('cat_commercial'.tr, commercial),
            Divider(height: 12, color: color.withOpacity(0.25)),
            row('total'.tr, total, bold: true),
          ],
        ),
      );
    }

    // v35 (user request): COLLAPSIBLE — the header (icon chip + title) stays
    // visible like the other dashboard cards; tapping expands the two groups.
    // Collapsed by default so the Home stays compact.
    return Container(
      width: double.infinity,
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
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.electric_bolt, color: Colors.orange, size: 24),
        ),
        title: Text('amps_by_status'.tr,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Short titles: the long "المشتركين …" labels ellipsize into
              // IDENTICAL prefixes beside the icon chip on narrow phones.
              Expanded(
                child: group('paid_short'.tr, Icons.check_circle,
                    const Color(0xFF2E7D32), ctrl.paidAmpsByCategory),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: group('unpaid_short'.tr, Icons.pending_actions,
                    const Color(0xFFC62828), ctrl.unpaidAmpsByCategory),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
    VoidCallback? onTap,
    double iconSize = 24, // v16: responsive (tablet vs phone)
    double valueFontSize = 23, // v16: bigger on the full-width money cards
    double labelFontSize = 13, // v19: responsive (phone default 13)
    double padding = 12, // v19: responsive (phone default 12)
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
          padding: EdgeInsets.all(padding),
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
                child: Icon(icon, color: color, size: iconSize),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // v16: bigger + overflow-SAFE number — FittedBox shrinks big
                    // numbers to fit so they are never clipped on small phones.
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          value,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: valueFontSize,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    Text(
                      label,
                      style: TextStyle(
                          color: Colors.grey, fontSize: labelFontSize),
                      maxLines: 1,
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
