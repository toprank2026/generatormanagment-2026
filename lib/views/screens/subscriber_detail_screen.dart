import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/utils/money.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/core/permissions.dart';
import 'package:generatormanagment/controllers/billing_controller.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/utils/pdf_service.dart';
import 'package:generatormanagment/utils/bluetooth_print_service.dart';
import 'package:generatormanagment/utils/lan_print_service.dart';
import 'package:generatormanagment/utils/usb_print_service.dart';
import 'package:generatormanagment/utils/printer_prefs.dart';
import 'package:generatormanagment/data/repositories/accountant_repository.dart';
import 'package:generatormanagment/controllers/settings_controller.dart';
import 'package:generatormanagment/views/screens/add_subscriber_screen.dart';
import 'package:generatormanagment/views/screens/payment_history_screen.dart';
import 'package:generatormanagment/views/widgets/collect_payment_dialog.dart';
import 'package:generatormanagment/controllers/core_controller.dart';
import 'package:generatormanagment/controllers/correction_controller.dart';
import 'package:generatormanagment/data/models/correction_models.dart';

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
  // v43 (E1): the correction-request dialog's fields. Owned by the SCREEN (like
  // _amountCtrl) rather than created per dialog: a controller disposed the
  // instant the dialog future completes can still be rebuilt by the route's
  // exit animation (a keyboard/MediaQuery change), which throws "used after
  // being disposed". They are disposed once, in dispose() below.
  final _corrAmpsCtrl = TextEditingController();
  final _corrReasonCtrl = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  // Re-binds this screen when the global month changes (R6/R9). Disposed below.
  Worker? _monthWorker;

  double dueAmount = 0.0;
  // v35 audit BUG 2: the LIVE subscriber row — re-fetched on every _refresh so
  // an edit (amps/category) or a reversal done on a pushed screen can never
  // leave this screen displaying/collecting against stale data.
  late Subscriber _sub;
  // v35 audit BUG 3: false = no price row for this category/month → NOT
  // billable yet (distinct from "paid"; getDueAmount returns 0.0 for both).
  bool _hasPrice = true;
  // v42 item 3: months STRICTLY BEFORE the selected one that are still short —
  // rendered as an amber NOTICE ONLY. Read by `_buildPrevUnpaidNotice()` and by
  // nothing else on this screen: dueAmount, _hasPrice, the paid/unpaid badge,
  // the collect button, the receipt history and every print path stay keyed to
  // the selected month alone, so the current month's accounting remains
  // completely independent of previous months.
  List<({String month, double due, double coverage, double remaining})>
      _prevUnpaid = const [];
  // v43 (E1): the DERIVED month lock for THIS subscriber in the SELECTED month.
  // Never a stored column — `SyncService.pull` writes INSERT OR REPLACE, so a
  // lock column an older device omitted would be reset account-wide on the next
  // pull; the state is re-derived from receipts/settlements every _refresh.
  //
  // On this screen it is a NOTICE plus a "request a correction" affordance and
  // NOTHING else: dueAmount, _hasPrice, the paid/unpaid badge, the collect
  // button, the receipt history and every print path are untouched by it. The
  // real enforcement lives in `CoreController.updateSubscriber` (below the UI),
  // so a missing notice can never let a locked edit through.
  bool _invoiceLocked = false;
  bool _settlementLocked = false;
  // Corrections already filed for this subscriber-month — fetched only when the
  // month is locked, and read ONLY by the locked notice card. Ordered pending
  // first, then newest (the repository's order), so `.first` is the one to show.
  List<Correction> _monthCorrections = const [];

  // R4: maps a subscriber category to its translation key (translated at use).
  static const Map<String, String> _categoryLabels = {
    SubscriberCategory.commercial: 'cat_commercial',
    SubscriberCategory.standard: 'cat_standard',
    SubscriberCategory.gold: 'cat_gold',
  };

  @override
  void initState() {
    super.initState();
    _sub = widget.subscriber;
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
    _corrAmpsCtrl.dispose();
    _corrReasonCtrl.dispose();
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
    // v35 audit BUG 2: re-fetch the subscriber (amps/category may have been
    // edited on the pushed edit screen) so due/display/collect use LIVE data.
    _sub = await SubscriberRepository().getById(widget.subscriber.id) ?? _sub;
    // v35 audit BUG 3: "no price yet" is NOT "paid" — the card shows a
    // dedicated not-billable state instead of a false paid-in-full.
    _hasPrice =
        await controller.hasPriceFor(_sub, controller.selectedMonth.value);
    dueAmount = await controller.getDueAmount(
      _sub,
      controller.selectedMonth.value,
    );
    // Load receipt history (page 1) via paginated controller list
    await controller.loadReceiptHistory(_sub.id);
    // v42 item 3: the previous-months NOTICE. Swallowed on error (and left
    // empty) on purpose — an informational card must NEVER be able to break the
    // page or hold up the due/collect flow above it.
    try {
      _prevUnpaid = await SubscriberRepository().previousUnpaidMonths(
        _sub.id,
        beforeMonth: controller.selectedMonth.value,
        branchId: _sub.branchId,
      );
    } catch (_) {
      _prevUnpaid = const [];
    }
    // v43 (E1): the month-lock probe, and (only when locked) the corrections
    // already filed for this subscriber-month. Swallowed on error and left
    // UNLOCKED on purpose — exactly like the arrears notice above, a probe that
    // only feeds a NOTICE must never be able to break this page or hold up the
    // due/collect flow. Failing open is safe here because the lock is enforced
    // in `CoreController.updateSubscriber`, not by this card.
    try {
      final lock = await coreController.monthLockState(
        _sub,
        controller.selectedMonth.value,
      );
      _invoiceLocked = lock.invoiceLocked;
      _settlementLocked = lock.settlementLocked;
      _monthCorrections = _invoiceLocked
          ? await Get.find<CorrectionController>().forSubscriberMonth(
              _sub.id,
              controller.selectedMonth.value,
            )
          : const [];
    } catch (_) {
      _invoiceLocked = false;
      _settlementLocked = false;
      _monthCorrections = const [];
    }
    // Pre-fill amount with due
    _amountCtrl.text = dueAmount.toStringAsFixed(0);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD), // Light blue background
      appBar: AppBar(
        title: Text(
          _sub.name,
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
            // v35 audit: refresh on return — a payment/reversal made on the
            // history screen must be reflected here immediately.
            onPressed: () => Get.to(
              () => PaymentHistoryScreen(subscriber: _sub),
            )?.then((_) => _refresh()),
          ),
          // Audit: gate on the fine-grained subscribers permission (matches the
          // Add FAB + the boards/expenses screens), not the coarse isAdmin —
          // an accountant GRANTED 'subscribers' could add but not edit/delete.
          Obx(
            () => auth.can(Perm.subscribers)
                ? IconButton(
                    icon: const Icon(Icons.edit),
                    // v35 audit BUG 2: refresh on return so an amps/category
                    // edit is reflected (and collected against) immediately.
                    onPressed: () => Get.to(
                      () => AddSubscriberScreen(subscriber: _sub),
                    )?.then((_) => _refresh()),
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
                    "${_sub.amps} ${'amps'.tr}",
                    'subscription'.tr,
                  ),
                  Container(width: 1, height: 40, color: Colors.grey[200]),
                  _buildInfoItem(
                    Icons.phone,
                    _sub.phone ?? 'no_phone'.tr,
                    'phone'.tr,
                  ),
                  Container(width: 1, height: 40, color: Colors.grey[200]),
                  // R4: pricing category
                  _buildInfoItem(
                    Icons.category,
                    (_categoryLabels[_sub.category] ?? _sub.category)
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

            // 2b. v42 item 3: PREVIOUS OUTSTANDING MONTHS — a notice, nothing
            // more. It is deliberately rendered BEFORE (and visually apart
            // from) the due card so it can never read as part of this month's
            // figure; no other widget/value below consults `_prevUnpaid`.
            if (_prevUnpaid.isNotEmpty) ...[
              _buildPrevUnpaidNotice(),
              const SizedBox(height: 20),
            ],

            // 2c. v43 (E1): the LOCKED-MONTH notice — shown when this
            // subscriber already has a valid receipt for the SELECTED month, so
            // the billing basis of that month can no longer be rewritten in
            // place. Like the arrears notice above it is informational: the due
            // card, the badge and the collect flow below are unchanged, and the
            // only action it offers is FILING a correction request.
            if (_invoiceLocked) ...[
              _buildMonthLockedNotice(),
              const SizedBox(height: 20),
            ],

            // 3. Due Amount / Payment Status. v35 audit BUG 3: a month with NO
            // price for this category is "not billable yet" (amber), NEVER a
            // false green "paid in full" — the lists/counts derive it UNPAID.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: !_hasPrice
                      ? [const Color(0xFFFFB74D), const Color(0xFFF57C00)]
                      : (dueAmount > 0
                          ? [const Color(0xFFEF5350), const Color(0xFFE53935)]
                          : [const Color(0xFF66BB6A), const Color(0xFF43A047)]),
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: (!_hasPrice
                            ? Colors.orange
                            : (dueAmount > 0 ? Colors.red : Colors.green))
                        .withOpacity(0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Text(
                    !_hasPrice
                        ? 'no_price_for_month'.tr
                        : (dueAmount > 0
                            ? 'total_due'.tr
                            : 'payment_complete'.tr),
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
                      !_hasPrice
                          ? '—'
                          : '${'iqd'.tr} ${fmtAmount(dueAmount > 0 ? dueAmount : 0)}',
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
                  if (!_hasPrice)
                    const SizedBox.shrink()
                  else if (dueAmount <= 0)
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

  /// v42 item 3: the arrears NOTICE card (amber). Purely informational — it
  /// reports months already closed short, and the figures it prints come from
  /// [SubscriberRepository.previousUnpaidMonths] alone. Nothing here feeds the
  /// selected month's due, badge, collect flow or printed receipt.
  Widget _buildPrevUnpaidNotice() {
    final double totalRemaining =
        _prevUnpaid.fold<double>(0, (sum, m) => sum + m.remaining);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        // Same amber notice palette as the other in-app hints (branches screen).
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFFE082)),
        boxShadow: [
          BoxShadow(
            color: Colors.orange.withOpacity(0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history_toggle_off, color: Color(0xFFFF8F00)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'prev_unpaid_title'.tr,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: Color(0xFFE65100),
                  ),
                ),
              ),
              Text(
                "${_prevUnpaid.length} ${'prev_unpaid_months_count'.tr}",
                style: const TextStyle(fontSize: 12, color: Color(0xFFFF8F00)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'prev_unpaid_total'.tr,
                style: const TextStyle(fontSize: 13, color: Colors.black87),
              ),
              Text(
                "${'iqd'.tr} ${fmtAmount(totalRemaining)}",
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 17,
                  color: Color(0xFFE65100),
                ),
              ),
            ],
          ),
          const Divider(height: 20, color: Color(0xFFFFE082)),
          // Per-month breakdown, newest first (the repository's order).
          ..._prevUnpaid.map(
            (m) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    m.month,
                    style: const TextStyle(fontSize: 13, color: Colors.black87),
                  ),
                  Text(
                    "${'iqd'.tr} ${fmtAmount(m.remaining)}",
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFEF6C00),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'prev_unpaid_body'.tr,
            style: TextStyle(fontSize: 11.5, color: Colors.grey[700]),
          ),
        ],
      ),
    );
  }

  /// v43 (E1): the LOCKED-MONTH notice card. Same shape/palette as the arrears
  /// notice above (this screen's established "notice" styling) so it reads as
  /// information, never as part of the month's figure.
  ///
  /// It states that the month is closed by an invoice (and, when true, by an
  /// active settlement as well), shows the correction already filed for this
  /// subscriber-month if there is one, and — for the ACCOUNTANT, the only role
  /// that may file one — offers the request dialog. Deliberately built OUTSIDE
  /// any `Obx`: the role/lock reads here are plain, non-reactive reads, and an
  /// `Obx` whose condition short-circuits before touching an observable throws
  /// at build and greys the whole screen in release.
  Widget _buildMonthLockedNotice() {
    final Correction? latest =
        _monthCorrections.isEmpty ? null : _monthCorrections.first;
    final bool hasOpen = latest != null && latest.isPending;
    return Container(
      width: double.infinity,
      // v43.1: COMPACT. This is a status notice, not the subject of the screen
      // — it sat above the payment card and pushed it off-screen. Tighter
      // padding, no drop shadow, no full-width button.
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        // Same amber notice palette as the arrears card above.
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFE082)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lock_outline, size: 16, color: Color(0xFFFF8F00)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'month_locked_title'.tr,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: Color(0xFFE65100),
                  ),
                ),
              ),
              // The month the lock belongs to — the Golden Rule made visible:
              // invoice month = accounting month = correction month.
              Text(
                controller.selectedMonth.value,
                style: const TextStyle(fontSize: 12, color: Color(0xFFFF8F00)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // One line: the full explanation is long and repeats every visit.
          Text(
            'month_locked_short'.tr,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: Colors.grey[800]),
          ),
          if (_settlementLocked)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  const Icon(Icons.account_balance_wallet,
                      size: 14, color: Color(0xFFEF6C00)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'settlement'.tr,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFEF6C00),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // The correction already filed for this subscriber-month, if any
          // (pending first, then newest — the repository's order).
          if (latest != null) ...[
            const Divider(height: 14, color: Color(0xFFFFE082)),
            Row(
              children: [
                _statusChip(latest.status),
                const Spacer(),
                // Flexible: a long amount must shrink, never overflow the card.
                Flexible(
                  child: Text(
                    '${'correction_difference'.tr}: '
                    '${_signedAmount(latest.difference)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                      color: latest.isIncrease
                          ? const Color(0xFF2E7D32)
                          : const Color(0xFFC62828),
                    ),
                  ),
                ),
              ],
            ),
          ],
          // Filing is the ACCOUNTANT's path (the owner/admin DECIDES instead).
          // A second pending request for the same subscriber-month is refused by
          // the controller; the button is hidden here so it is never offered.
          // Compact + right-aligned: a full-width orange bar read as the primary
          // action of the screen, which it is not.
          if (auth.isAccountant && !hasOpen)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFEF6C00),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _showCorrectionDialog,
                icon: const Icon(Icons.edit_note, size: 16),
                label: Text(
                  'correction_request'.tr,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Signed IQD amount, e.g. "+ IQD 12,500" / "- IQD 12,500". The sign is the
  /// whole money story of a correction, so it is never dropped.
  String _signedAmount(double value) =>
      "${value < 0 ? '-' : '+'} ${'iqd'.tr} ${fmtAmount(value.abs())}";

  /// A small status pill for a correction (same five statuses the corrections
  /// screen renders).
  Widget _statusChip(String status) {
    final Color color = status == CorrectionStatus.approved
        ? const Color(0xFF2E7D32)
        : (status == CorrectionStatus.rejected
            ? Colors.redAccent
            : (status == CorrectionStatus.refundDue
                ? const Color(0xFFEF6C00)
                : (status == CorrectionStatus.completed
                    ? const Color(0xFF00897B)
                    : Colors.orange)));
    final String label = status == CorrectionStatus.approved
        ? 'correction_approved'
        : (status == CorrectionStatus.rejected
            ? 'correction_rejected'
            : (status == CorrectionStatus.refundDue
                ? 'correction_refund_due'
                : (status == CorrectionStatus.completed
                    ? 'correction_completed'
                    : 'correction_pending')));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label.tr,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 11,
        ),
      ),
    );
  }

  /// v43 (E1): the correction REQUEST dialog — new amps + a reason. It changes
  /// nothing by itself: `CorrectionController.requestCorrection` records what
  /// the month IS billed at against what it SHOULD be, and the money only moves
  /// if and when the owner/admin approves it. The subscriber row, the receipt,
  /// the tariff and the settlement are never rewritten.
  ///
  /// The dialog is closed FIRST (through its own Navigator route) and the async
  /// work + snackbars run after — the established close-first-then-act pattern,
  /// since a snackbar raised while the dialog is open makes `Get.isDialogOpen`
  /// read false and blocks the close.
  Future<void> _showCorrectionDialog() async {
    // Prefilled with the LIVE amps (the basis the month was invoiced on) and a
    // blank reason on every open.
    _corrAmpsCtrl.text = _sub.amps.toString();
    _corrReasonCtrl.clear();
    final String month = controller.selectedMonth.value;
    final input = await Get.dialog<({double amps, String reason})>(
      Builder(builder: (ctx) {
        return AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('correction_request'.tr),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The month being corrected — read-only, and the same global
                // accounting month the rest of the screen is bound to.
                Text(
                  '${'billing_month'.tr}: $month',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1565C0),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _corrAmpsCtrl,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'correction_new_amps'.tr,
                    suffixText: 'amps'.tr,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _corrReasonCtrl,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: 'correction_reason'.tr,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'correction_original_untouched'.tr,
                  style: TextStyle(fontSize: 11.5, color: Colors.grey[700]),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('cancel'.tr),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1565C0),
              ),
              onPressed: () {
                final v = double.tryParse(_corrAmpsCtrl.text.trim());
                // Same amps rule as every other write path: a positive
                // number (0 would bill the month at nothing).
                if (v == null || v.isNaN || v <= 0) {
                  Get.snackbar('error'.tr, 'amps_invalid'.tr,
                      snackPosition: SnackPosition.BOTTOM);
                  return;
                }
                final r = _corrReasonCtrl.text.trim();
                if (r.isEmpty) {
                  Get.snackbar('error'.tr, 'correction_reason'.tr,
                      snackPosition: SnackPosition.BOTTOM);
                  return;
                }
                Navigator.of(ctx).pop((amps: v, reason: r));
              },
              child: Text('correction_submit'.tr),
            ),
          ],
        );
      }),
    );
    if (input == null) return; // cancelled — nothing written
    try {
      final CorrectionController corrections = Get.find<CorrectionController>();
      final saved = await corrections.requestCorrection(
        sub: _sub,
        month: month,
        newAmps: input.amps,
        reason: input.reason,
      );
      if (saved == null) {
        // The controller reports a translation KEY rather than raising its own
        // snackbar (it is exercised by tests with no overlay).
        Get.snackbar('error'.tr, (corrections.lastError.value ?? 'error').tr,
            backgroundColor: Colors.redAccent, colorText: Colors.white);
      } else {
        Get.snackbar('success'.tr, 'correction_sent'.tr,
            backgroundColor: Colors.green, colorText: Colors.white);
      }
    } catch (e) {
      Get.snackbar('error'.tr, '$e',
          backgroundColor: Colors.redAccent, colorText: Colors.white);
    }
    _refresh();
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
    // v35 audit BUG 3: keyed to the SUBSCRIBER-branch price lookup (_hasPrice),
    // not the active-branch cache, so it matches getDueAmount exactly.
    if (!_hasPrice) {
      Get.snackbar('error'.tr, 'no_price_set'.tr,
          backgroundColor: Colors.redAccent, colorText: Colors.white);
      return;
    }
    // P5: shared collect dialog with full/partial + optional discount.
    // v35 audit BUG 2: pass the LIVE subscriber (fresh amps/category).
    final receipt = await showCollectPaymentDialog(
      subscriber: _sub,
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
        _sub,
        accountantName,
        deviceId: settings.usbDeviceId.value.isEmpty
            ? null
            : settings.usbDeviceId.value,
      );
    } else if (PrinterPrefs.isLan) {
      // v24: LAN/Ethernet thermal printing (same rendered receipt as USB/BT).
      // PrinterPrefs.lanIp is the always-current saved endpoint (the obs can
      // lag behind an auto-discovery); onStatus keeps the user informed during
      // a network search, which can take ~10-20s.
      Get.snackbar(
        'printing'.tr,
        "${'sending_to'.tr} ${PrinterPrefs.lanIp.isEmpty ? 'lan_printer'.tr : PrinterPrefs.lanIp}...",
        duration: const Duration(seconds: 2),
      );
      await LanPrintService().printReceipt(
        receipt,
        _sub,
        accountantName,
        onStatus: (_) => Get.snackbar('printing'.tr, 'lan_searching'.tr,
            duration: const Duration(seconds: 4)),
      );
      // Reflect an auto-discovered endpoint in the settings obs.
      settings.lanIp.value = PrinterPrefs.lanIp;
      settings.lanPort.value = PrinterPrefs.lanPort;
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
        _sub,
        accountantName,
      );
    } else {
      // Fallback to standard PDF printing
      await PdfService()
          .printReceipt(receipt, _sub, accountantName: accountantName);
    }
    } catch (e) {
      // v24: a re-tap while a LAN job is still searching/streaming is NOT a
      // failure — the first job is in flight and may yet print.
      if (e.toString().contains('lan_busy')) {
        Get.snackbar('printing'.tr, 'lan_print_in_progress'.tr,
            snackPosition: SnackPosition.BOTTOM);
        return;
      }
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
          // v35 item 5: refused when the subscriber's receipts include money
          // already inside a settlement (deleting them would corrupt wallets).
          final ok =
              await coreController.deleteSubscriber(widget.subscriber.id);
          if (!ok) {
            Get.snackbar('error'.tr, 'delete_blocked_settled'.tr,
                backgroundColor: Colors.orange, colorText: Colors.white);
            return;
          }
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
