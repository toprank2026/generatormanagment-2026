import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/billing_controller.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/utils/pdf_service.dart';
import 'package:generatormanagment/utils/bluetooth_print_service.dart';
import 'package:generatormanagment/data/repositories/user_repository.dart';
import 'package:generatormanagment/controllers/settings_controller.dart';
import 'package:generatormanagment/views/screens/add_subscriber_screen.dart';
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

  double dueAmount = 0.0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // Defer state updates to after the first frame to avoid "setState during build" errors
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Reset to current month when entering screen to avoid stale state from previous visits
      controller.selectedMonth.value = DateFormat(
        'yyyy-MM',
      ).format(DateTime.now());
      _refresh();
    });
  }

  @override
  void dispose() {
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
          Obx(
            () => auth.isAdmin
                ? IconButton(
                    icon: const Icon(Icons.edit),
                    onPressed: () => Get.to(
                      () => AddSubscriberScreen(subscriber: widget.subscriber),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Obx(
            () => auth.isAdmin
                ? IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () => _showDeleteConfirm(),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      body: SingleChildScrollView(
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
                    widget.subscriber.phone ?? "N/A",
                    'phone'.tr,
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
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(
                          Icons.calendar_month,
                          color: Color(0xFF1565C0),
                        ),
                        onPressed: () async {
                          DateTime? picked = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now(),
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2030),
                          );
                          if (picked != null) {
                            String m = DateFormat('yyyy-MM').format(picked);
                            controller.changeMonth(m);
                            _refresh();
                          }
                        },
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
                      NumberFormat.currency(
                        symbol: 'iqd'.tr,
                        decimalDigits: 0,
                      ).format(dueAmount > 0 ? dueAmount : 0),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                      ),
                    );
                  }),
                  const SizedBox(height: 16),
                  if (dueAmount > 0)
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
                    )
                  else
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
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // 4. Receipt History
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 8.0),
                child: Text(
                  'history'.tr,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.blueGrey,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            Obx(
              () => ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount:
                    controller.receipts.length +
                    (controller.isHistoryMoreLoading.value ? 1 : 0),
                separatorBuilder: (c, i) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  if (index >= controller.receipts.length) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final r = controller.receipts[index];
                  return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.grey.withOpacity(0.05),
                        blurRadius: 5,
                      ),
                    ],
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    leading: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.receipt_long,
                        color: Color(0xFF1565C0),
                      ),
                    ),
                    title: Text(
                      "${'receipt_no'.tr}${r.receiptNo}",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      DateFormat(
                        'MMM d, yyyy - h:mm a',
                        Get.locale?.toString(),
                      ).format(DateTime.parse(r.issuedAt)),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          NumberFormat.currency(
                            symbol: "",
                            decimalDigits: 0,
                          ).format(r.paidAmount),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Color(0xFF1565C0),
                          ),
                        ),
                        IconButton(
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
          ],
        ),
      ),
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

  void _showCollectDialog() {
    _amountCtrl.text = dueAmount.toStringAsFixed(0);

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
              "Month: ${controller.selectedMonth.value}",
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
              final receipt = await controller.collectPayment(
                widget.subscriber,
                val,
              );
              if (receipt != null) {
                Get.snackbar(
                  "Success",
                  "Payment collected",
                  backgroundColor: Colors.green,
                  colorText: Colors.white,
                );
                _handlePrint(receipt);
                _refresh();
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

  void _handlePrint(Receipt receipt) async {
    final settings = Get.find<SettingsController>();
    final auth = Get.find<AuthController>();

    // Fetch accountant name
    String accountantName = "";
    if (receipt.performedByUserId == auth.currentUser.value?.id) {
      accountantName = auth.currentUser.value?.username ?? "";
    } else if (receipt.performedByUserId != null) {
      final user = await UserRepository().getUserById(
        receipt.performedByUserId!,
      );
      accountantName = user?.username ?? "";
    }

    if (settings.printerAddress.value.isNotEmpty) {
      Get.snackbar(
        "Printing",
        "Sending to ${settings.printerName.value}...",
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
      await PdfService().printReceipt(receipt, widget.subscriber);
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
      onConfirm: () async {
        await coreController.deleteSubscriber(widget.subscriber.id);
        Get.back(); // Close dialog
        Get.back(); // Go back to previous screen
        Get.snackbar(
          "success".tr,
          "subscriber_deleted".tr,
          backgroundColor: Colors.red,
          colorText: Colors.white,
        );
      },
    );
  }
}
