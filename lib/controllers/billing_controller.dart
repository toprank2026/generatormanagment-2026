import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/dashboard_controller.dart';

class BillingController extends GetxController {
  final MonthlyPriceRepository _priceRepo = MonthlyPriceRepository();
  final ReceiptRepository _receiptRepo = ReceiptRepository();

  var currentPrice = Rxn<MonthlyPrice>();
  var isLoading = false.obs;
  var selectedMonth = DateFormat('yyyy-MM').format(DateTime.now()).obs;

  // --- Receipt history pagination (subscriber detail screen) ---
  static const int historyItemsPerPage = 10;
  var receipts = <Receipt>[].obs;
  var historyPage = 1.obs;
  var historyHasNext = false.obs;
  var isHistoryMoreLoading = false.obs;
  var isHistoryLoading = false.obs;

  @override
  void onInit() {
    super.onInit();
  }

  @override
  void onReady() {
    super.onReady();
    loadMonthPrice(selectedMonth.value);
  }

  void changeMonth(String month) {
    selectedMonth.value = month;
    loadMonthPrice(month);
    update();
  }

  Future<void> loadMonthPrice(String month) async {
    isLoading.value = true;
    currentPrice.value = await _priceRepo.getByMonth(month);
    isLoading.value = false;
    update();
  }

  Future<void> setPrice(double price) async {
    final mp = MonthlyPrice(month: selectedMonth.value, pricePerAmp: price);
    await _priceRepo.insert(mp); // Insert or replace
    loadMonthPrice(selectedMonth.value);
    update();
  }

  // --- Receipt history pagination ---
  Future<void> loadReceiptHistory(String subscriberId, {int page = 1}) async {
    if (page == 1) {
      isHistoryLoading.value = true;
      receipts.clear();
    } else {
      isHistoryMoreLoading.value = true;
    }

    historyPage.value = page;

    try {
      // Fetch one extra item to check if there is a next page
      final result = await _receiptRepo.getBySubscriber(
        subscriberId,
        limit: historyItemsPerPage + 1,
        offset: (page - 1) * historyItemsPerPage,
      );

      List<Receipt> newItems;
      if (result.length > historyItemsPerPage) {
        historyHasNext.value = true;
        newItems = result.sublist(0, historyItemsPerPage);
      } else {
        historyHasNext.value = false;
        newItems = result;
      }

      if (page == 1) {
        receipts.assignAll(newItems);
      } else {
        receipts.addAll(newItems);
      }
    } finally {
      isHistoryLoading.value = false;
      isHistoryMoreLoading.value = false;
    }
    update();
  }

  void loadMoreReceiptHistory(String subscriberId) {
    if (historyHasNext.value &&
        !isHistoryMoreLoading.value &&
        !isHistoryLoading.value) {
      loadReceiptHistory(subscriberId, page: historyPage.value + 1);
    }
  }

  Future<double> getDueAmount(Subscriber sub, String month) async {
    // 1. Get price for the month
    MonthlyPrice? mp = await _priceRepo.getByMonth(month);
    if (mp == null) return 0.0; // No price set

    double totalDue = sub.amps * mp.pricePerAmp;

    // 2. Subtract paid amount
    List<Receipt> receipts = await _receiptRepo.getBySubscriberAndMonth(
      sub.id,
      month,
    );
    double paid = receipts.fold(0.0, (sum, r) => sum + r.paidAmount);

    return totalDue - paid;
  }

  Future<Receipt?> collectPayment(Subscriber sub, double amount) async {
    if (amount <= 0) {
      Get.snackbar('error'.tr, 'enter_valid_amount'.tr);
      return null;
    }

    MonthlyPrice? mp = await _priceRepo.getByMonth(selectedMonth.value);
    if (mp == null) return null;

    double due = await getDueAmount(sub, selectedMonth.value);
    // Allow overpayment? PRD says "validate amount <= remaining".
    // We strictly enforce unless admin allows (flag not implemented).
    if (amount > due) {
      Get.snackbar('error'.tr, 'amount_exceeds_due'.tr);
      return null;
    }

    final AuthController auth = Get.find();
    int receiptNo = await _receiptRepo.getNextReceiptNumber();

    final r = Receipt(
      uuid: const Uuid().v4(),
      receiptNo: receiptNo,
      subscriberId: sub.id,
      month: selectedMonth.value,
      ampsSnapshot: sub.amps,
      priceSnapshot: mp.pricePerAmp,
      paidAmount: amount,
      remainingAfter: due - amount,
      performedByUserId: auth.currentUser.value?.id,
      accountantId: auth
          .currentUser
          .value
          ?.id, // Assume logged user as accountant for now
      issuedAt: DateTime.now().toIso8601String(),
    );

    await _receiptRepo.insert(r);

    // Refresh receipt history (page 1) for this subscriber
    await loadReceiptHistory(sub.id);

    // Refresh dashboard if it's registered
    if (Get.isRegistered<DashboardController>()) {
      Get.find<DashboardController>().loadStats();
    }

    update();
    return r;
  }
}
