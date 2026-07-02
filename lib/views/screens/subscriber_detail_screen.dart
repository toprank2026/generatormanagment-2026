import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/utils/money.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/core/permissions.dart';
import 'package:generatormanagment/controllers/billing_controller.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/utils/pdf_service.dart';
import 'package:generatormanagment/utils/bluetooth_print_service.dart';
import 'package:generatormanagment/utils/usb_print_service.dart';
import 'package:generatormanagment/utils/printer_prefs.dart';
import 'package:generatormanagment/data/repositories/accountant_repository.dart';
import 'package:generatormanagment/controllers/settings_controller.dart';
import 'package:generatormanagment/views/screens/add_subscriber_screen.dart';
import 'package:generatormanagment/views/screens/payment_history_screen.dart';
import 'package:generatormanagment/views/widgets/collect_payment_dialog.dart';
import 'package:generatormanagment/controllers/core_controller.dart';

class SubscriberDetailScreen extends StatefulWidget {
  final Subscriber subscriber;
  const SubscriberDetailScreen({super.key, required this.subscriber});

  @override
  State<SubscriberDetailScreen> createState() => _SubscriberDetailScreenState();
}

class _SubscriberDetailScreenState extends State<SubscriberDetailScreen> {
  final AuthController auth = Get.find<AuthController>();
  final BillingController controller = Get.find<BillingController>();
  final CoreController coreController = Get.find<CoreController>();
  final ReceiptRepository receiptRepo = ReceiptRepository();
  final _amountCtrl = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  // Re-binds this screen when the global month changes (R6/R9). Disposed below.
  Worker? _monthWorker;

  double dueAmount = 0.0;

  // R4: maps a subscriber category to its translation key (translated at use).
  static const Map<String, String> _categoryLabels = {
    SubscriberCategory.commercial: 'cat_commercial',
    SubscriberCategory.standard: 'cat_standard',
    SubscriberCategory.gold: 'cat_gold',
  };

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // Defer state updates to after the first frame to avoid "setState during build" errors
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // R6/R9: do NOT reset the month here — inherit the globally-selected month
      // (chosen on Home/Monthly Pricing) so opening a subscriber from Home uses
      // exactly that month. Re-bind whenever the global month changes too.
      _monthWorker = ever(controller.selectedMonth, (_) => _refresh());
      _refresh();
    });
  }

  @override
  void dispose() {
    _monthWorker?.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      controller.loadMoreReceiptHistory(widget.subscriber.id);
    }
  }

  void _refresh() async {
    await controller.loadMonthPrice(controller.selectedMonth.value);
    dueAmount = await controller.getDueAmount(
      widget.subscriber,
      controller.selectedMonth.value,
    );
    // Load receipt history (page 1) via paginated controller list
    await controller.loadReceiptHistory(widget.subscriber.id);
    // Pre-fill amount with due
    _amountCtrl.text = dueAmount.toStringAsFixed(0);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD), // Light blue background
      appBar: AppBar(
        title: Text(
          widget.subscriber.name,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        backgroundColor: const Color(0xFF1565C0),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'payment_history'.tr,
            icon: const Icon(Icons.history),
            onPressed: () => Get.to(
              () => PaymentHistoryScreen(subscriber: widget.subscriber),
            ),
          ),
          // Audit: gate on the fine-grained subscribers permission (matches the
          // Add FAB + the boards/expenses screens), not the coarse isAdmin —
          // an accountant GRANTED 'subscribers' could add but not edit/delete.
          Obx(
            () => auth.can(Perm.subscribers)
                ? IconButton(
                    icon: const Icon(Icons.edit),
                    onPressed: () => Get.to(
                      () => AddSubscriberScreen(subscriber: widget.subscriber),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Obx(
            () => auth.can(Perm.subscribers)
                ? IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () => _showDeleteConfirm(),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      body: SafeArea(child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // 1. Subscriber Info Card
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blue.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildInfoItem(
                    Icons.electric_meter,
                    "${widget.subscriber.amps} ${'amps'.tr}",
                    'subscription'.tr,
                  ),
                  Container(width: 1, height: 40, color: Colors.grey[200]),
                  _buildInfoItem(
                    Icons.phone,
                    widget.subscriber.phone ?? 'no_phone'.tr,
                    'phone'.tr,
                  ),
                  Container(width: 1, height: 40, color: Colors.grey[200]),
                  // R4: pricing category
                  _buildInfoItem(
                    Icons.category,
                    (_categoryLabels[widget.subscriber.category] ??
                            widget.subscriber.category)
                        .tr,
                    'category'.tr,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // 2. Month Selector
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blue.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'billing_month'.tr,
                    style: const TextStyle(color: Colors.grey),
                  ),
                  Row(
                    children: [
                      // R9: month is READ-ONLY here — it is selected only on the
                      // Monthly Pricing screen and inherited globally.
                      Obx(
                        () => Text(
                          controller.selectedMonth.value,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1565C0),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // 3. Due Amount / Payment Status
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: dueAmount > 0
                      ? [const Color(0xFFEF5350), const Color(0xFFE53935)]
                      : [const Color(0xFF66BB6A), const Color(0xFF43A047)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: (dueAmount > 0 ? Colors.red : Colors.green)
                        .withOpacity(0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Text(
                    dueAmount > 0 ? 'total_due'.tr : 'payment_complete'.tr,
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Obx(() {
                    if (controller.isLoading.value) {
                      return const SizedBox(
                        height: 48,
                        width: 48,
                        child: CircularProgressIndicator(color: Colors.white),
                      );
                    }
                    return Text(
                      '${'iqd'.tr} ${fmtAmount(dueAmount > 0 ? dueAmount : 0)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                      ),
                    );
                  }),
                  const SizedBox(height: 16),
                  // Paid/unpaid badge keyed ONLY on the due amount (so it never
                  // lies). The collect button is the accountant-only part: an
                  // owner viewing an UNPAID subscriber sees the due (above) but no
                  // collect button — and crucially NOT a false "paid in full".
                  if (dueAmount <= 0)
                    Chip(
                      label: Text(
                        'paid_full'.tr,
                        style: const TextStyle(color: Colors.green),
                      ),
                      backgroundColor: Colors.white,
                      avatar: const Icon(
                        Icons.check_circle,
                        color: Colors.green,
                      ),
                    )
                  else if (auth.isAccountant)
                    ElevatedButton.icon(
                      onPressed: () => _showCollectDialog(),
                      icon: const Icon(Icons.payment, color: Color(0xFFD32F2F)),
                      label: Text(
                        'collect_now'.tr,
                        style: const TextStyle(
                          color: Color(0xFFD32F2F),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      )),
    );
  }

  Widget _buildInfoItem(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, color: Colors.grey[400], size: 28),
        const SizedBox(height: 8),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        Text(label, style: TextStyle(color: Colors.grey[500], fontSize: 12)),
      ],
    );
  }

  void _showCollectDialog() async {
    // Item 2 pre-check: no tariff for this category this month → can't bill.
    // Message clearly instead of opening a dialog that can't complete (and which
    // previously got stuck because the controller snackbar blocked its close).
    if (controller.currentPrices[widget.subscriber.category] == null) {
      Get.snackbar('error'.tr, 'no_price_set'.tr,
          backgroundColor: Colors.redAccent, colorText: Colors.white);
      return;
    }
    // P5: shared collect dialog with full/partial + optional discount.
    final receipt = await showCollectPaymentDialog(
      subscriber: widget.subscriber,
      due: dueAmount,
    );
    if (receipt != null) {
      Get.snackbar(
        'success'.tr,
        'payment_collected'.tr,
        backgroundColor: Colors.green,
        colorText: Colors.white,
      );
      // Item 2: AWAIT the print so the receipt/print window reliably appears
      // (and a print failure surfaces) BEFORE refreshing the screen.
      await _handlePrint(receipt);
      _refresh();
    }
  }

  Future<void> _handlePrint(Receipt receipt) async {
    final settings = Get.find<SettingsController>();
    try {

    // The accountant this invoice BELONGS to (owning accountant), resolved from
    // the synced identity so the name prints on any device. Empty for
    // owner-owned receipts (no accountant line is printed then).
    String accountantName = "";
    if (receipt.accountantId != null && receipt.accountantId!.isNotEmpty) {
      final a = await AccountantRepository().getById(receipt.accountantId!);
      accountantName = a?.displayName ?? "";
    }

    if (PrinterPrefs.isUsb) {
      // v21 item 1: direct USB thermal printing (auto-cut). Bluetooth untouched.
      Get.snackbar(
        'printing'.tr,
        "${'sending_to'.tr} ${settings.usbDeviceName.value}...",
        duration: const Duration(seconds: 2),
      );
      await UsbPrintService().printReceipt(
        receipt,
        widget.subscriber,
        accountantName,
        deviceId: settings.usbDeviceId.value.isEmpty
            ? null
            : settings.usbDeviceId.value,
      );
    } else if (settings.printerAddress.value.isNotEmpty) {
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
    } catch (e) {
      // A print failure must not be silent (or swallow the collected payment) —
      // the receipt is already saved; just report the print problem.
      Get.snackbar('error'.tr, '${'print_failed'.tr}: $e',
          backgroundColor: Colors.redAccent, colorText: Colors.white);
    }
  }

  void _showDeleteConfirm() {
    Get.defaultDialog(
      title: "delete_subscriber_title".tr,
      middleText: "delete_subscriber_confirm".tr,
      textConfirm: "delete".tr,
      textCancel: "cancel".tr,
      confirmTextColor: Colors.white,
      buttonColor: Colors.red,
      // v22 item 8: close-FIRST-then-act — the old await-then-double-back left
      // the dialog stuck open on a throw, and a double-tapped confirm popped 4
      // routes. The pops go through the raw Navigator: Get.back while a
      // snackbar is open closes the SNACKBAR instead (GetX), which would leave
      // the dialog open and then mis-pop it in place of the screen.
      onConfirm: () async {
        // Close dialog (synchronously — no double-tap window).
        Navigator.of(context, rootNavigator: true).pop();
        try {
          await coreController.deleteSubscriber(widget.subscriber.id);
          if (mounted) Navigator.of(context).pop(); // leave the detail screen
          Get.snackbar(
            "success".tr,
            "subscriber_deleted".tr,
            backgroundColor: Colors.red,
            colorText: Colors.white,
          );
        } catch (e) {
          Get.snackbar('error'.tr, '$e',
              backgroundColor: Colors.redAccent, colorText: Colors.white);
        }
      },
    );
  }
}
