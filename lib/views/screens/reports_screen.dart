import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/reports_controller.dart';
import 'package:generatormanagment/data/models/accountant_model.dart';
import 'package:generatormanagment/data/repositories/accountant_repository.dart';
import 'package:generatormanagment/utils/money.dart';
import 'package:generatormanagment/views/widgets/report_charts.dart';
import 'package:generatormanagment/views/screens/payments_screen.dart';

/// Monthly reports & statistics: pick a month and see gauges/charts plus
/// totals (expected / collected / remaining / expenses / net profit) derived
/// from the local receipts, expenses and monthly prices, and that month's
/// payments list.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Canonical pagination trigger: load the next payments page ~200px from
    // the bottom of the report scroll view.
    _scroll.addListener(() {
      if (_scroll.position.pixels >=
          _scroll.position.maxScrollExtent - 200) {
        Get.find<ReportsController>().loadMoreReceipts();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ReportsController controller = Get.find<ReportsController>();
    final AuthController auth = Get.find<AuthController>();

    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(
        title: Text(
          'reports'.tr,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        backgroundColor: const Color(0xFF1565C0),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(child: Column(
        children: [
          _buildMonthPicker(controller),
          // Owner-only: filter every figure on this screen by accountant, and a
          // quick count of accountants. An accountant only ever sees their own
          // numbers, so neither control is shown to them.
          Obx(
            () => auth.isAdmin
                ? _buildAccountantControls(controller)
                : const SizedBox.shrink(),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: controller.loadReport,
              child: Obx(() {
                if (controller.isLoading.value) {
                  return const Center(child: CircularProgressIndicator());
                }

                final double expected = controller.expectedTotal.value;
                final double collected = controller.collectedTotal.value;
                final double net = controller.netProfit.value;
                final Color netColor =
                    net >= 0 ? const Color(0xFF2E7D32) : const Color(0xFFC62828);
                // v30 F1: paid / unpaid / paid-by-current-accountant gauge.
                final int paidN = controller.paidCount.value;
                final int unpaidN = controller.unpaidCount.value;
                final int byMeN = controller.paidByMe.value;
                final int byOthersN = (paidN - byMeN) < 0 ? 0 : (paidN - byMeN);

                return SingleChildScrollView(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // v23 (§2.2): a month with no STANDARD price set — since
                      // the audit fix, subscribers of an unpriced category count
                      // as UNPAID (not paid) until a price is set. Surface that so
                      // the all-unpaid state isn't mistaken for non-collection.
                      if (controller.pricePerAmp.value <= 0)
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF3E0),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFFFCC80)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.info_outline,
                                  color: Color(0xFFEF6C00)),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'no_price_for_month'.tr,
                                  style: const TextStyle(
                                    color: Color(0xFFB45309),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                      // v14: collection-rate gauge removed.

                      // b) Paid / unpaid / paid-by-me donut (v30 F1). When the
                      //    current accountant has collected from subscribers this
                      //    month, the paid ring splits into green "paid by others"
                      //    + orange "paid by me"; otherwise it's a plain paid/
                      //    unpaid donut (identical to the owner view).
                      _chartCard(
                        DonutChart(
                          segments: [
                            // No "paid by me" collections → a plain green paid
                            // segment. Otherwise green = paid-by-others, but only
                            // when it's non-zero (else the legend would show a
                            // confusing "paid by others 0" row).
                            if (byMeN == 0)
                              DonutSegment(
                                label: 'paid_subscribers'.tr,
                                value: paidN.toDouble(),
                                color: const Color(0xFF2E7D32),
                              )
                            else if (byOthersN > 0)
                              DonutSegment(
                                label: 'paid_by_others'.tr,
                                value: byOthersN.toDouble(),
                                color: const Color(0xFF2E7D32),
                              ),
                            if (byMeN > 0)
                              DonutSegment(
                                label: 'paid_by_me'.tr,
                                value: byMeN.toDouble(),
                                color: const Color(0xFFEF6C00),
                              ),
                            DonutSegment(
                              label: 'unpaid_subscribers'.tr,
                              value: unpaidN.toDouble(),
                              color: const Color(0xFFC62828),
                            ),
                          ],
                          // v23 (§2.6): the center equals the two visible
                          // segments (paid+unpaid). Under an accountant filter
                          // this differs from branch-wide totalSubscribers, so
                          // showing the sum keeps the donut internally consistent.
                          centerText: (paidN + unpaidN).toString(),
                        ),
                      ),

                      // c) Collected vs expenses vs net-profit bars.
                      _chartCard(
                        BarCompareChart(
                          items: [
                            BarItem(
                              label: 'collected_revenue'.tr,
                              value: collected,
                              color: const Color(0xFF1565C0),
                            ),
                            BarItem(
                              label: 'total_expenses'.tr,
                              value: controller.expensesTotal.value,
                              color: const Color(0xFFEF6C00),
                            ),
                            BarItem(
                              label: 'net_profit'.tr,
                              value: net,
                              color: const Color(0xFF00695C),
                            ),
                          ],
                        ),
                      ),

                      // d) Totals grid (dashboard-overview style).
                      GridView.count(
                        crossAxisCount: 2,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 16,
                        crossAxisSpacing: 16,
                        childAspectRatio: 1.3,
                        children: [
                          _buildStatCard(
                            icon: Icons.request_quote,
                            color: Colors.indigo,
                            label: 'expected_total'.tr,
                            value: fmtAmount(expected),
                          ),
                          _buildStatCard(
                            icon: Icons.account_balance_wallet,
                            color: Colors.green,
                            label: 'collected_revenue'.tr,
                            value: fmtAmount(collected),
                          ),
                          _buildStatCard(
                            icon: Icons.monetization_on,
                            color: Colors.redAccent,
                            label: 'remaining_fees'.tr,
                            value: fmtAmount(controller.remainingTotal.value),
                          ),
                          _buildStatCard(
                            icon: Icons.receipt_long,
                            color: Colors.orange,
                            label: 'total_expenses'.tr,
                            value: fmtAmount(controller.expensesTotal.value),
                          ),
                          _buildStatCard(
                            icon: net >= 0
                                ? Icons.trending_up
                                : Icons.trending_down,
                            color: netColor,
                            label: 'net_profit'.tr,
                            value: fmtAmount(net),
                            valueColor: netColor,
                          ),
                          // item 1: COUNT of PAID subscribers per tariff (gold /
                          // standard / commercial) — not their prices.
                          _buildStatCard(
                            icon: Icons.people,
                            color: const Color(0xFFFFB300), // gold
                            label:
                                '${'cat_gold'.tr} — ${'paid_subscribers'.tr}',
                            value: controller.paidGold.value.toString(),
                          ),
                          _buildStatCard(
                            icon: Icons.people,
                            color: Colors.cyan,
                            label:
                                '${'cat_standard'.tr} — ${'paid_subscribers'.tr}',
                            value: controller.paidStandard.value.toString(),
                          ),
                          _buildStatCard(
                            icon: Icons.people,
                            color: const Color(0xFF00897B), // commercial (teal)
                            label:
                                '${'cat_commercial'.tr} — ${'paid_subscribers'.tr}',
                            value: controller.paidCommercial.value.toString(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // e) The month's payments moved to their own screen.
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF1565C0),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          icon: const Icon(Icons.receipt_long),
                          label: Text('payments_of_month'.tr),
                          onPressed: () => Get.to(() => const PaymentsScreen()),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),
        ],
      )),
    );
  }

  /// The month-picker card: prev/next chevrons around the selected month.
  /// chevron_left/right carry matchTextDirection, so under RTL the framework
  /// mirrors them AND the Row flips sides — using the plain LTR semantics here
  /// yields outward-pointing arrows in both directions.
  Widget _buildMonthPicker(ReportsController controller) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.blue.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(
              Icons.chevron_left,
              color: Color(0xFF1565C0),
              size: 30,
            ),
            onPressed: controller.prevMonth,
          ),
          Expanded(
            child: Obx(
              () => Text(
                controller.month.value,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1565C0),
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.chevron_right,
              color: Color(0xFF1565C0),
              size: 30,
            ),
            onPressed: controller.nextMonth,
          ),
        ],
      ),
    );
  }

  /// Owner-only row: an accountant filter dropdown (null = all accountants)
  /// plus a small card showing how many accountants exist. Both fetch from
  /// [AccountantRepository] once via FutureBuilders.
  Widget _buildAccountantControls(ReportsController controller) {
    final AccountantRepository repo = AccountantRepository();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          // Accountant filter dropdown.
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blue.withOpacity(0.05),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: FutureBuilder<List<Accountant>>(
                future: repo.getAll(),
                builder: (context, snapshot) {
                  final List<Accountant> accountants = snapshot.data ?? [];
                  return Obx(
                    () => DropdownButtonHideUnderline(
                      child: DropdownButton<String?>(
                        isExpanded: true,
                        value: controller.accountantFilter.value,
                        hint: Text('all_accountants'.tr),
                        icon: const Icon(Icons.person_search,
                            color: Color(0xFF1565C0)),
                        items: [
                          DropdownMenuItem<String?>(
                            value: null,
                            child: Text('all_accountants'.tr),
                          ),
                          ...accountants.map(
                            (a) => DropdownMenuItem<String?>(
                              value: a.id,
                              child: Text(
                                a.displayName,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: controller.setAccountantFilter,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Accountants count card.
          FutureBuilder<int>(
            future: repo.count(),
            builder: (context, snapshot) {
              final int n = snapshot.data ?? 0;
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.blue.withOpacity(0.05),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.people_alt, color: Color(0xFF1565C0)),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$n',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1565C0),
                          ),
                        ),
                        Text(
                          'accountants'.tr,
                          style:
                              const TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// White rounded card wrapping one chart, centered.
  Widget _chartCard(Widget child) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.blue.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(child: child),
    );
  }

  /// 2-col overview stat card (same style as the dashboard grid).
  Widget _buildStatCard({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
    Color? valueColor,
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
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: valueColor,
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
    );
  }

}
