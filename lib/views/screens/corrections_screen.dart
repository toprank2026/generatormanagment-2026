import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/correction_controller.dart';
import 'package:generatormanagment/controllers/month_controller.dart';
import 'package:generatormanagment/data/models/correction_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/utils/date_fmt.dart';
import 'package:generatormanagment/utils/money.dart';

const Color _kBlue = Color(0xFF1565C0);
const Color _kAmber = Color(0xFFEF6C00);
const Color _kGreen = Color(0xFF2E7D32);
const Color _kTeal = Color(0xFF00897B);

/// v43 (E2) — the CORRECTION QUEUE.
///
/// Corrections filed against an already-invoiced (or already-settled) month,
/// with the owner/admin decision on each. Mirrors
/// `accountant_settlements_screen.dart`: filter row on top, one scrollable body
/// with pull-to-refresh, the canonical `perPage + 1` pagination (owned by
/// [CorrectionController]) driven by a `ScrollController` disposed in the State.
///
/// What a decision here does — and does not do:
///
///  * APPROVE appends ONE immutable row to `financial_adjustments`. The
///    original receipt, the settlement, the tariff and the subscriber row are
///    never rewritten; an increase raises that month's wallet, a decrease moves
///    the correction to `refund_due` and the wallet is NOT reduced (it must
///    never be driven negative by a historical correction).
///  * RECORD CASH RETURNED is a SEPARATE operation with its own record —
///    approving a decrease never asserted that money moved.
///  * REJECT writes nothing at all; the month keeps exactly the figures it has.
///
/// Every decision button is gated on [CorrectionController.canDecide], which
/// checks the EXPLICIT role — never `AuthController.isAdmin`, which is also true
/// for the `DEV_ADMIN` compile flag.
///
/// Every `Obx` builder below reads an observable on its FIRST line: an `Obx`
/// whose condition short-circuits before touching one throws at build and
/// renders the whole screen as a grey `ErrorWidget` in release.
class CorrectionsScreen extends StatefulWidget {
  const CorrectionsScreen({super.key});

  @override
  State<CorrectionsScreen> createState() => _CorrectionsScreenState();
}

class _CorrectionsScreenState extends State<CorrectionsScreen> {
  final CorrectionController _c = Get.find<CorrectionController>();
  final MonthController _month = Get.find<MonthController>();
  final SubscriberRepository _subRepo = SubscriberRepository();
  final ScrollController _scroll = ScrollController();

  /// subscriber id -> display name, resolved lazily for the loaded rows so the
  /// queue reads as names rather than uuids. Purely cosmetic: a name that fails
  /// to resolve falls back to a dash and nothing else changes.
  final Map<String, String> _names = {};

  /// Worker on the controller's list — STORED so [dispose] can dispose it (an
  /// undisposed worker outlives the screen and fires into a dead State).
  Worker? _rowsWorker;

  /// The status filter chips, in lifecycle order.
  static const List<String> _statuses = [
    CorrectionStatus.pending,
    CorrectionStatus.approved,
    CorrectionStatus.refundDue,
    CorrectionStatus.completed,
    CorrectionStatus.rejected,
  ];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _rowsWorker = ever(_c.corrections, (_) => _resolveNames());
    // Deferred: `load` writes to `.obs` fields, and mutating an observable
    // during the first build would markNeedsBuild mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _c.load(pull: true);
      _resolveNames();
    });
  }

  @override
  void dispose() {
    _rowsWorker?.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      _c.loadMore();
    }
  }

  /// Fill [_names] for any loaded row whose subscriber is not cached yet.
  /// Swallowed on error and re-rendered as a dash — a display lookup must never
  /// be able to break the queue.
  Future<void> _resolveNames() async {
    final missing = <String>{};
    for (final c in _c.corrections) {
      final id = c.subscriberId;
      if (id != null && id.isNotEmpty && !_names.containsKey(id)) {
        missing.add(id);
      }
    }
    if (missing.isEmpty) return;
    bool changed = false;
    for (final id in missing) {
      try {
        final s = await _subRepo.getById(id);
        if (s != null) {
          _names[id] = s.name;
          changed = true;
        }
      } catch (_) {/* leave it unresolved — the tile shows a dash */}
    }
    if (changed && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(title: Text('correction_requests'.tr)),
      body: SafeArea(
        child: Column(
          children: [
            _filterRow(),
            Expanded(
              child: Obx(() {
                // Observables FIRST — and an unambiguous scalar `.value` read
                // as the very first statement (the release-mode grey-screen
                // trap: an Obx that returns before touching an observable
                // throws at build and greys the whole screen).
                final bool loading = _c.isLoading.value;
                final rows = _c.corrections.toList();
                final bool moreLoading = _c.isMoreLoading.value;
                final bool saving = _c.isSaving.value;
                final bool canDecide = _c.canDecide;
                if (loading && rows.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }
                return RefreshIndicator(
                  onRefresh: () => _c.load(pull: true),
                  child: ListView(
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    children: [
                      if (rows.isEmpty) ...[
                        const SizedBox(height: 40),
                        Icon(Icons.fact_check_outlined,
                            size: 64, color: Colors.grey.shade400),
                        const SizedBox(height: 12),
                        Center(
                          child: Text('correction_none'.tr,
                              style: TextStyle(color: Colors.grey.shade600)),
                        ),
                        const SizedBox(height: 40),
                      ] else
                        ...rows.map((c) => _tile(c, canDecide, saving)),
                      if (moreLoading)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                    ],
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  /// Month scope + status filter. The queue follows the GLOBAL accounting month
  /// by default (a correction belongs to exactly one month), and the month chip
  /// toggles that off so a pending request can never become invisible merely
  /// because the owner browsed to another month.
  Widget _filterRow() {
    return Obx(() {
      // Observables FIRST.
      final String? status = _c.statusFilter.value;
      final bool allMonths = _c.allMonths.value;
      final int pending = _c.pendingCount.value;
      final String month = _month.selectedMonth.value;
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  FilterChip(
                    selected: !allMonths,
                    showCheckmark: false,
                    avatar: Icon(
                      allMonths ? Icons.all_inclusive : Icons.event,
                      size: 18,
                      color: allMonths ? Colors.blueGrey : _kBlue,
                    ),
                    label: Text(
                      allMonths ? "${'billing_month'.tr}: —" : month,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    onSelected: (sel) => _c.setAllMonths(!sel),
                  ),
                  const SizedBox(width: 10),
                  for (final s in _statuses) ...[
                    FilterChip(
                      selected: status == s,
                      showCheckmark: false,
                      selectedColor: _statusColor(s).withValues(alpha: 0.16),
                      label: Text(
                        _statusKey(s).tr,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: status == s
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: status == s ? _statusColor(s) : null,
                        ),
                      ),
                      // Tapping the selected chip clears the filter, so "every
                      // status" needs no label of its own.
                      onSelected: (sel) => _c.setStatusFilter(sel ? s : null),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            if (pending > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 2),
                child: Text(
                  '${'correction_pending'.tr}: $pending',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.orange),
                ),
              ),
          ],
        ),
      );
    });
  }

  /// One correction: who/which month, the signed difference, the amps change,
  /// the reason, and the decision buttons the acting role is allowed to press.
  Widget _tile(Correction c, bool canDecide, bool saving) {
    final Color color = _statusColor(c.status);
    final String name = (c.subscriberId != null && c.subscriberId!.isNotEmpty)
        ? (_names[c.subscriberId] ?? '—')
        : '—';
    final String when = _when(c.requestedAt ?? c.createdAt);
    final bool increase = c.isIncrease;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: color.withValues(alpha: 0.12),
                  child: Icon(
                    increase ? Icons.trending_up : Icons.trending_down,
                    color: increase ? _kGreen : Colors.redAccent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      // The month the correction belongs to — the Golden Rule
                      // on screen: it can affect no other month.
                      Text(
                        '${'billing_month'.tr}: ${c.month ?? '—'}',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade700),
                      ),
                      if (when.isNotEmpty)
                        Text(when,
                            style: TextStyle(
                                fontSize: 11.5, color: Colors.grey.shade600)),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20)),
                  child: Text(_statusKey(c.status).tr,
                      style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.bold,
                          fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                // amps as invoiced -> amps as corrected.
                Expanded(
                  child: Text(
                    '${_amps(c.oldAmps)} → ${_amps(c.newAmps)} ${'amps'.tr}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                // Flexible: a long amount shrinks, it never overflows the card.
                Flexible(
                  child: Text(
                    '${'correction_difference'.tr}: ${_signed(c.difference)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: increase ? _kGreen : Colors.redAccent,
                    ),
                  ),
                ),
              ],
            ),
            if ((c.reason ?? '').trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${'correction_reason'.tr}: ${c.reason!.trim()}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                ),
              ),
            if ((c.decisionNote ?? '').trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  c.decisionNote!.trim(),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ),
            // --- decisions (owner/admin only) ---
            if (canDecide && c.isPending) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: saving ? null : () => _reject(c),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent),
                      icon: const Icon(Icons.close, size: 18),
                      label: Text('correction_reject'.tr),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: saving ? null : () => _approve(c),
                      style: FilledButton.styleFrom(backgroundColor: _kBlue),
                      icon: const Icon(Icons.check, size: 18),
                      label: Text('correction_approve'.tr),
                    ),
                  ),
                ],
              ),
            ],
            if (canDecide && c.isRefundDue) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: saving ? null : () => _recordRefund(c),
                  style: FilledButton.styleFrom(backgroundColor: _kAmber),
                  icon: const Icon(Icons.payments, size: 18),
                  label: Text('correction_record_refund'.tr),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // decisions
  // ---------------------------------------------------------------------------

  Future<void> _approve(Correction c) async {
    final ok = await _confirm(
      'correction_approve'.tr,
      "${'correction_difference'.tr}: ${_signed(c.difference)}\n\n"
      "${'correction_original_untouched'.tr}",
    );
    if (ok != true) return;
    final bool done = await _c.approve(c);
    // A DECREASE lands in `refund_due` (the cash still has to be physically
    // returned), an increase in `approved` — say which, so approval is never
    // mistaken for money having moved.
    _report(
      done,
      c.difference < 0 ? 'correction_refund_due' : 'correction_approved',
    );
  }

  Future<void> _reject(Correction c) async {
    final ok = await _confirm(
      'correction_reject'.tr,
      "${'correction_difference'.tr}: ${_signed(c.difference)}\n\n"
      "${'correction_original_untouched'.tr}",
    );
    if (ok != true) return;
    final bool done = await _c.reject(c);
    _report(done, 'correction_rejected');
  }

  Future<void> _recordRefund(Correction c) async {
    final ok = await _confirm(
      'correction_record_refund'.tr,
      "${'iqd'.tr} ${fmtAmount(c.difference.abs())}\n\n"
      "${'correction_original_untouched'.tr}",
    );
    if (ok != true) return;
    final bool done = await _c.recordRefundPaid(c);
    _report(done, 'correction_refund_recorded');
  }

  /// Confirm dialog, same shape as the settlement decision confirm.
  Future<bool?> _confirm(String title, String body) => Get.defaultDialog<bool>(
        title: title,
        middleText: body,
        textConfirm: 'continue'.tr,
        textCancel: 'cancel'.tr,
        confirmTextColor: Colors.white,
        buttonColor: _kBlue,
        onConfirm: () => Get.back(result: true),
        onCancel: () {},
      );

  /// One place for the result toast: the success message on a real change, and
  /// otherwise the controller's refusal KEY (it reports one instead of raising
  /// its own snackbar — it is exercised by tests with no overlay, and a
  /// snackbar raised before a dialog closes blocks the close).
  void _report(bool done, String successKey) {
    if (!done) {
      Get.snackbar('error'.tr, (_c.lastError.value ?? 'error').tr,
          backgroundColor: Colors.redAccent,
          colorText: Colors.white,
          snackPosition: SnackPosition.BOTTOM);
      return;
    }
    Get.snackbar('success'.tr, successKey.tr,
        backgroundColor: _kGreen,
        colorText: Colors.white,
        snackPosition: SnackPosition.BOTTOM);
  }

  // ---------------------------------------------------------------------------
  // formatting
  // ---------------------------------------------------------------------------

  /// Signed IQD amount ("+ IQD 12,500" / "- IQD 12,500"). The sign is the whole
  /// money story of a correction, so it is never dropped.
  String _signed(double value) =>
      "${value < 0 ? '-' : '+'} ${'iqd'.tr} ${fmtAmount(value.abs())}";

  String _amps(double? value) => value == null ? '—' : '$value';

  String _when(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final d = DateTime.tryParse(raw);
    return d == null ? raw : fmtDateTime12(d.toLocal());
  }

  static Color _statusColor(String status) {
    switch (status) {
      case CorrectionStatus.approved:
        return _kGreen;
      case CorrectionStatus.rejected:
        return Colors.redAccent;
      case CorrectionStatus.refundDue:
        return _kAmber;
      case CorrectionStatus.completed:
        return _kTeal;
      default:
        return Colors.orange;
    }
  }

  static String _statusKey(String status) {
    switch (status) {
      case CorrectionStatus.approved:
        return 'correction_approved';
      case CorrectionStatus.rejected:
        return 'correction_rejected';
      case CorrectionStatus.refundDue:
        return 'correction_refund_due';
      case CorrectionStatus.completed:
        return 'correction_completed';
      default:
        return 'correction_pending';
    }
  }
}
