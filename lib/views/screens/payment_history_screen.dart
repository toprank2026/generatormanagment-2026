import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/accountant_repository.dart';
import 'package:generatormanagment/controllers/billing_controller.dart';
import 'package:generatormanagment/controllers/settings_controller.dart';
import 'package:generatormanagment/utils/pdf_service.dart';
import 'package:generatormanagment/utils/bluetooth_print_service.dart';

/// Dedicated, paginated screen showing a subscriber's paid-bills (receipts)
/// history. Self-contained pagination (its own state + repository) so it does
/// not interfere with the inline history on the detail screen.
///
/// This is also the primary place to RECORD a payment and PRINT its receipt:
/// the record-payment action reuses the shared [BillingController.collectPayment]
/// flow, and the per-receipt print action reuses the same print call as the
/// detail screen.
class PaymentHistoryScreen extends StatefulWidget {
  final Subscriber subscriber;
  const PaymentHistoryScreen({super.key, required this.subscriber});

  @override
  State<PaymentHistoryScreen> createState() => _PaymentHistoryScreenState();
}

class _PaymentHistoryScreenState extends State<PaymentHistoryScreen> {
  final ReceiptRepository _repo = ReceiptRepository();
  final BillingController _billing = Get.find<BillingController>();
  final ScrollController _scroll = ScrollController();
  final _amountCtrl = TextEditingController();

  static const int _perPage = 15;
  final List<Receipt> _items = [];
  int _page = 1;
  bool _hasNext = false;
  bool _loading = true;
  bool _moreLoading = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(page: 1);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _load({required int page}) async {
    if (page == 1) {
      setState(() => _loading = true);
    } else {
      setState(() => _moreLoading = true);
    }
    // Fetch one extra to detect the next page.
    final result = await _repo.getBySubscriber(
      widget.subscriber.id,
      limit: _perPage + 1,
      offset: (page - 1) * _perPage,
    );
    final hasNext = result.length > _perPage;
    final newItems = hasNext ? result.sublist(0, _perPage) : result;
    setState(() {
      _page = page;
      _hasNext = hasNext;
      if (page == 1) {
        _items
          ..clear()
          ..addAll(newItems);
      } else {
        _items.addAll(newItems);
      }
      _loading = false;
      _moreLoading = false;
    });
  }

  void _loadMore() {
    if (_hasNext && !_moreLoading && !_loading) {
      _load(page: _page + 1);
    }
  }

  /// Opens the shared collect-payment flow (reuses [BillingController.collectPayment]),
  /// then refreshes this history list. Mirrors the detail screen's dialog so the
  /// business logic stays in one place.
  void _showCollectDialog() async {
    // Ensure the controller targets the current month and has its price loaded,
    // matching the detail-screen flow.
    _billing.selectedMonth.value = DateFormat('yyyy-MM').format(DateTime.now());
    await _billing.loadMonthPrice(_billing.selectedMonth.value);
    final due = await _billing.getDueAmount(
      widget.subscriber,
      _billing.selectedMonth.value,
    );
    _amountCtrl.text = due.toStringAsFixed(0);

    Get.defaultDialog(
      title: 'collect_payment'.tr,
      titlePadding: const EdgeInsets.only(top: 20),
      radius: 16,
      contentPadding: const EdgeInsets.all(20),
      content: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue[50],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              "${'billing_month'.tr}: ${_billing.selectedMonth.value}",
              style: const TextStyle(
                color: Colors.blue,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1565C0),
            ),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              prefixText: 'iqd'.tr,
              filled: true,
              fillColor: Colors.grey[50],
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
      confirm: SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: () async {
            double? val = double.tryParse(
              _amountCtrl.text.replaceAll(',', ''),
            ); // Handle commas if any
            if (val != null) {
              Get.back(); // Close dialog
              final receipt = await _billing.collectPayment(
                widget.subscriber,
                val,
              );
              if (receipt != null) {
                Get.snackbar(
                  'success'.tr,
                  'payment_collected'.tr,
                  backgroundColor: Colors.green,
                  colorText: Colors.white,
                );
                _handlePrint(receipt);
                _load(page: 1); // Refresh history list
              }
            }
          },
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1565C0),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text('confirm_print'.tr),
        ),
      ),
      cancel: TextButton(onPressed: () => Get.back(), child: Text('cancel'.tr)),
    );
  }

  /// Prints [receipt] for this subscriber. Reuses the same print path as the
  /// detail screen (Bluetooth thermal printer when configured, else PDF).
  void _handlePrint(Receipt receipt) async {
    final settings = Get.find<SettingsController>();

    // The accountant this invoice belongs to (owning accountant), resolved from
    // the synced identity. Empty for owner-owned receipts.
    String accountantName = "";
    if (receipt.accountantId != null && receipt.accountantId!.isNotEmpty) {
      final a = await AccountantRepository().getById(receipt.accountantId!);
      accountantName = a?.displayName ?? "";
    }

    if (settings.printerAddress.value.isNotEmpty) {
      Get.snackbar(
        'printing'.tr,
        "${'sending_to'.tr} ${settings.printerName.value}...",
        duration: const Duration(seconds: 2),
      );
      final bluetoothService = BluetoothPrintService();
      // Ensure connected
      await bluetoothService.connectByAddress(settings.printerAddress.value);
      await bluetoothService.printReceipt(
        receipt,
        widget.subscriber,
        accountantName,
      );
    } else {
      // Fallback to standard PDF printing
      await PdfService()
          .printReceipt(receipt, widget.subscriber, accountantName: accountantName);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.decimalPattern();
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        iconTheme: const IconThemeData(color: Colors.white),
        centerTitle: true,
        elevation: 0,
        title: Column(
          children: [
            Text(
              'payment_history'.tr,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            Text(
              widget.subscriber.name,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'record_payment'.tr,
            icon: const Icon(Icons.add_card),
            onPressed: _showCollectDialog,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.payment),
        label: Text('record_payment'.tr),
        onPressed: _showCollectDialog,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.receipt_long_outlined,
                          size: 80, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text(
                        'no_payments'.tr,
                        style: TextStyle(color: Colors.grey[600], fontSize: 16),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => _load(page: 1),
                  child: ListView.separated(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
                    itemCount: _items.length + (_moreLoading ? 1 : 0),
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      if (index == _items.length) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(8.0),
                            child: CircularProgressIndicator(),
                          ),
                        );
                      }
                      final r = _items[index];
                      final refunded = r.status != 'valid';
                      return Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.blue.withValues(alpha: 0.05),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 6),
                          leading: CircleAvatar(
                            backgroundColor: const Color(0xFFE3F2FD),
                            child: const Icon(Icons.receipt_long,
                                color: Color(0xFF1565C0)),
                          ),
                          title: Text(
                            "${'receipt_no'.tr}${r.receiptNo}",
                            style:
                                const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            "${r.month}  •  ${DateFormat('MMM d, yyyy', Get.locale?.toString()).format(DateTime.parse(r.issuedAt))}",
                            style: TextStyle(
                                color: Colors.grey[600], fontSize: 12),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    "${currency.format(r.paidAmount)} ${'iqd'.tr}",
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                      color: refunded
                                          ? Colors.grey
                                          : const Color(0xFF1565C0),
                                    ),
                                  ),
                                  if (refunded)
                                    Text('subscription_rejected'.tr,
                                        style: const TextStyle(
                                            fontSize: 10, color: Colors.red)),
                                ],
                              ),
                              IconButton(
                                tooltip: 'print'.tr,
                                icon: const Icon(
                                  Icons.print_outlined,
                                  color: Colors.grey,
                                ),
                                onPressed: () => _handlePrint(r),
                              ),
                            ],
                          ),
                          onTap: () => _handlePrint(r),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
