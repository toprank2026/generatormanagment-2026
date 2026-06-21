import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:generatormanagment/controllers/reports_controller.dart';
import 'package:generatormanagment/data/models/billing_models.dart';

const Color _kBlue = Color(0xFF1565C0);

/// The month's payments (receipts) list — moved out of the Reports screen into
/// its own page. Reuses [ReportsController] (its receipts list + pagination).
class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({super.key});

  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen> {
  final ReportsController controller = Get.find<ReportsController>();
  final ScrollController _scroll = ScrollController();
  final NumberFormat _money = NumberFormat.decimalPattern();

  @override
  void initState() {
    super.initState();
    // Normally ReportsController is already populated (Reports tab loads it on
    // launch), but if it isn't (cold open / empty), load it here.
    if (controller.receipts.isEmpty) controller.loadReport();
    _scroll.addListener(() {
      if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
        controller.loadMoreReceipts();
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
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(
        backgroundColor: _kBlue,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
        title: Column(
          children: [
            Text('payments_of_month'.tr,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.white)),
            Obx(() => Text(controller.month.value,
                style: const TextStyle(fontSize: 12, color: Colors.white70))),
          ],
        ),
      ),
      body: Obx(() {
        return RefreshIndicator(
          onRefresh: () => controller.loadReport(),
          child: controller.receipts.isEmpty
              ? ListView(
                  // ListView (not Center) so pull-to-refresh works when empty.
                  children: [
                    SizedBox(height: MediaQuery.of(context).size.height * 0.35),
                    Center(
                      child: Text('no_data_month'.tr,
                          style:
                              TextStyle(color: Colors.grey[500], fontSize: 16)),
                    ),
                  ],
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  itemCount: controller.receipts.length +
                      (controller.isReceiptsLoadingMore.value ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == controller.receipts.length) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    return _buildReceiptCard(controller.receipts[i]);
                  },
                ),
        );
      }),
    );
  }

  Widget _buildReceiptCard(Receipt r) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _kBlue.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.receipt_long, color: _kBlue),
        ),
        title: Text('${'receipt_no'.tr} ${r.receiptNo}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(
          '${_formatDate(r.issuedAt)} · ${r.paymentMethod == 'card' ? 'pay_card'.tr : 'pay_cash'.tr}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          _money.format(r.paidAmount),
          style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: Color(0xFF2E7D32)),
        ),
      ),
    );
  }

  String _formatDate(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return iso;
    return DateFormat('yyyy-MM-dd HH:mm').format(t);
  }
}
