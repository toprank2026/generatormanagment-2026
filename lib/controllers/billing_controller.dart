import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/controllers/month_controller.dart';
import 'package:generatormanagment/controllers/dashboard_controller.dart';

class BillingController extends GetxController {
  final MonthlyPriceRepository _priceRepo = MonthlyPriceRepository();
  final ReceiptRepository _receiptRepo = ReceiptRepository();
  final BranchController _branch = Get.find();
  final MonthController _month = Get.find();

  var currentPrice = Rxn<MonthlyPrice>(); // standard price (back-compat)
  // Per-category prices for the selected month {category: pricePerAmp} (R4).
  var currentPrices = <String, double>{}.obs;
  var isLoading = false.obs;

  /// The globally-selected month (R9) — sourced from [MonthController]. Billing
  /// never owns the month; it only reads it (and the Monthly Pricing screen
  /// mutates it via MonthController). Same [RxString] so existing
  /// `selectedMonth.value` reads stay reactive.
  RxString get selectedMonth => _month.selectedMonth;

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
    // The selected month's price is per-branch (D-4): reload it on a switch.
    ever(_branch.currentBranch, (_) => loadMonthPrice(selectedMonth.value));
    // R9: the global month is owned by MonthController and changed only from the
    // Monthly Pricing screen — reload this month's prices whenever it changes.
    ever(_month.selectedMonth, (m) => loadMonthPrice(m));
  }

  @override
  void onReady() {
    super.onReady();
    loadMonthPrice(selectedMonth.value);
  }

  Future<void> loadMonthPrice(String month) async {
    isLoading.value = true;
    currentPrice.value = await _priceRepo.getByMonth(month,
        branchId: _branch.scopeBranchId, category: SubscriberCategory.standard);
    // All category prices for the month (R4) for the pricing screen.
    currentPrices.value =
        await _priceRepo.pricesForMonth(month, branchId: _branch.scopeBranchId);
    isLoading.value = false;
    update();
  }

  /// Price-per-amp set for [month] in the active branch, for the given
  /// [category] (R4). Each category is independent.
  Future<void> setPrice(double price,
      {String category = SubscriberCategory.standard}) async {
    final mp = MonthlyPrice(
      month: selectedMonth.value,
      pricePerAmp: price,
      branchId: _branch.writeBranchId,
      category: category,
    );
    await _priceRepo.insert(mp); // Insert or replace
    await loadMonthPrice(selectedMonth.value);
    // R10: pricing changed → recompute the dashboard's Collected/Remaining now.
    if (Get.isRegistered<DashboardController>()) {
      Get.find<DashboardController>().loadStats();
    }
    update();
  }

  /// Atomically set ALL category prices for the selected month/branch (R4). Used
  /// by the Monthly Pricing screen where Gold/Regular/Commercial are all
  /// required — writes each row then reloads + refreshes the dashboard ONCE.
  Future<void> setPrices(Map<String, double> pricesByCategory) async {
    for (final entry in pricesByCategory.entries) {
      await _priceRepo.insert(MonthlyPrice(
        month: selectedMonth.value,
        pricePerAmp: entry.value,
        branchId: _branch.writeBranchId,
        category: entry.key,
      ));
    }
    await loadMonthPrice(selectedMonth.value);
    if (Get.isRegistered<DashboardController>()) {
      Get.find<DashboardController>().loadStats();
    }
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
      // Subscribers are shared, but each accountant's history shows only the
      // receipts THEY collected (owner/admin sees all).
      final result = await _receiptRepo.getBySubscriber(
        subscriberId,
        limit: historyItemsPerPage + 1,
        offset: (page - 1) * historyItemsPerPage,
        accountantId: Get.find<AuthController>().scopeAccountantId,
        branchId: _branch.scopeBranchId,
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
    // A receipt belongs to the SUBSCRIBER's branch. Keying the price + paid sum
    // to sub.branchId keeps the due correct even from the consolidated view
    // (active branch null), and never counts another branch's payments.
    final String? branchId = sub.branchId ?? _branch.scopeBranchId;

    // 1. Get price for the month (per-branch AND per-category pricing, R4)
    MonthlyPrice? mp = await _priceRepo.getByMonth(month,
        branchId: branchId, category: sub.category);
    if (mp == null) return 0.0; // No price set for this category/month

    double totalDue = sub.amps * mp.pricePerAmp;

    // 2. Subtract COVERAGE (this branch's receipts only). Coverage = cash paid
    //    PLUS any discount waived (P5), so a discounted FULL payment shows due 0.
    //    Non-discount receipts have discountValue 0, so this is unchanged.
    List<Receipt> receipts = await _receiptRepo.getBySubscriberAndMonth(
      sub.id,
      month,
      branchId: branchId,
    );
    double covered =
        receipts.fold(0.0, (sum, r) => sum + r.paidAmount + r.discountValue);

    return totalDue - covered;
  }

  /// Collect a payment. [fullPayment] true = the subscriber settles the whole
  /// remaining due; only then may a discount be applied (P5). [discountType] is
  /// 'none'|'ampere'|'value'; for 'ampere' pass [discountAmps] (value =
  /// amps × pricePerAmp), for 'value' pass [discountValueInput] (IQD). On a full
  /// payment the cash collected = due − discountValue and remaining = 0, and the
  /// waived amount is recorded so the subscriber counts as fully paid.
  Future<Receipt?> collectPayment(
    Subscriber sub,
    double amount, {
    bool fullPayment = false,
    String discountType = 'none',
    double discountAmps = 0,
    double discountValueInput = 0,
  }) async {
    // The receipt belongs to the SUBSCRIBER's branch (correct even when
    // collecting from the consolidated view, where the active branch is null).
    final String branchId = sub.branchId ?? _branch.writeBranchId;

    MonthlyPrice? mp = await _priceRepo.getByMonth(selectedMonth.value,
        branchId: branchId, category: sub.category);
    if (mp == null) return null;

    final double due = await getDueAmount(sub, selectedMonth.value);

    // Discount applies ONLY on a full payment (enforced here, not just in the
    // UI — the amount field is user-editable). Partial payment => no discount.
    double discountValue = 0;
    double? discountAmpsRec;
    String discType = 'none';
    if (fullPayment && discountType != 'none') {
      if (discountType == 'ampere') {
        discountAmpsRec = discountAmps;
        discountValue = discountAmps * mp.pricePerAmp;
      } else {
        discountValue = discountValueInput;
      }
      if (discountValue < 0) discountValue = 0;
      if (discountValue > due) discountValue = due; // can't waive more than due
      discType = discountValue > 0 ? discountType : 'none';
    }

    // On a full payment the cash collected is the remainder after the discount;
    // on a partial payment it's the entered amount (no discount).
    final double cash = fullPayment ? (due - discountValue) : amount;

    if (cash <= 0 && discountValue <= 0) {
      Get.snackbar('error'.tr, 'enter_valid_amount'.tr);
      return null;
    }
    // Coverage (cash + discount) may not exceed the remaining due.
    if (cash + discountValue > due + 0.0001) {
      Get.snackbar('error'.tr, 'amount_exceeds_due'.tr);
      return null;
    }

    final AuthController auth = Get.find();
    // Receipt numbering is independent per branch (D-3): MAX+1 within the
    // subscriber's branch, so each branch keeps its own 1..N sequence.
    int receiptNo = await _receiptRepo.getNextReceiptNumber(branchId: branchId);

    final r = Receipt(
      uuid: const Uuid().v4(),
      receiptNo: receiptNo,
      subscriberId: sub.id,
      month: selectedMonth.value,
      ampsSnapshot: sub.amps,
      priceSnapshot: mp.pricePerAmp,
      paidAmount: cash,
      remainingAfter: due - cash - discountValue,
      performedByUserId: auth.currentUser.value?.id,
      // Subscribers are SHARED, so the invoice belongs to the accountant who
      // COLLECTED it (the acting user) — this drives each accountant's separate
      // history/reports and prints their name on the receipt.
      accountantId: auth.currentUser.value?.id,
      // Full isolation: the receipt belongs to the subscriber's branch.
      branchId: branchId,
      // Audit: the category (and thus price) in force at collection time (R4).
      categorySnapshot: sub.category,
      // Discount (P5).
      discountType: discType,
      discountValue: discountValue,
      discountAmps: discountAmpsRec,
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
