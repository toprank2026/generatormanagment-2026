import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/billing_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/controllers/month_controller.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/correction_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/correction_repository.dart';
import 'package:generatormanagment/utils/money.dart';

/// v44 — the **Corrections** tab on the Subscribers screen: every customer
/// whose data was corrected in the selected accounting month, with the
/// original value, the new value, the difference and the **settlement
/// status** of that difference.
///
/// This is the VISIBILITY layer only. It changes nothing: paid/unpaid is
/// derived (coverage vs due) exactly as everywhere else, and the money flows
/// through ordinary receipts / the correction ledger. It reads the same global
/// month every other screen reads (`MonthController.selectedMonth`) and
/// re-loads when it changes, like the subscriber lists do.
///
/// Settlement status is DERIVED per row, never stored:
///   pending          -> awaiting approval
///   increase, approved:
///       due(sub, month) > 0  -> unpaid difference (a receipt is still owed)
///       due(sub, month) == 0 -> paid
///   decrease:
///       refund_due       -> credit (held on the correction)
///       completed        -> refunded (cash returned)
///       carried_forward  -> carried forward (applied to next month)
///   rejected         -> rejected
class CorrectionsMonthTab extends StatefulWidget {
  const CorrectionsMonthTab({super.key});

  @override
  State<CorrectionsMonthTab> createState() => _CorrectionsMonthTabState();
}

class _CorrectionsMonthTabState extends State<CorrectionsMonthTab> {
  static const int _perPage = 20;
  final CorrectionRepository _repo = CorrectionRepository();
  final SubscriberRepository _subs = SubscriberRepository();
  final ScrollController _scroll = ScrollController();
  late final MonthController _month = Get.find<MonthController>();
  late final BranchController _branch = Get.find<BranchController>();
  late final BillingController _billing = Get.find<BillingController>();

  final List<_Row> _rows = [];
  bool _loading = true;
  bool _more = false;
  bool _loadingMore = false;
  int _page = 1;
  Worker? _monthWorker;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // Same re-bind idiom as the other month-scoped screens.
    _monthWorker = ever(_month.selectedMonth, (_) => _load());
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _monthWorker?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_more || _loadingMore) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      _load(page: _page + 1);
    }
  }

  /// Canonical pagination idiom (fetch perPage + 1, trim, page-1 assign /
  /// later pages append) — reference: CoreController.loadSubscribers.
  Future<void> _load({int page = 1}) async {
    if (!mounted) return;
    setState(() {
      if (page == 1) {
        _loading = true;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final String month = _month.selectedMonth.value;
      final raw = await _repo.correctedInMonth(
        month: month,
        branchId: _branch.scopeBranchId,
        limit: _perPage + 1,
        offset: (page - 1) * _perPage,
      );
      final bool more = raw.length > _perPage;
      final slice = more ? raw.sublist(0, _perPage) : raw;
      final rows = <_Row>[];
      for (final m in slice) {
        final c = Correction.fromMap(m);
        rows.add(_Row(
          correction: c,
          name: (m['subscriber_name'] as String?) ?? '',
          settle: await _settlementOf(c, month),
        ));
      }
      if (!mounted) return;
      setState(() {
        if (page == 1) {
          _rows
            ..clear()
            ..addAll(rows);
        } else {
          _rows.addAll(rows);
        }
        _page = page;
        _more = more;
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  /// The derived settlement status of one correction — see the class doc.
  Future<String> _settlementOf(Correction c, String month) async {
    switch (c.status) {
      case CorrectionStatus.pending:
        return 'settle_awaiting_approval';
      case CorrectionStatus.rejected:
        return 'settle_rejected';
      case CorrectionStatus.refundDue:
        return 'settle_credit';
      case CorrectionStatus.completed:
        return 'settle_refunded';
      case CorrectionStatus.carriedForward:
        return 'settle_carried_forward';
    }
    // approved (an increase): is the extra amount covered by a receipt yet?
    final String? sid = c.subscriberId;
    if (sid == null || sid.isEmpty) return 'settle_paid';
    final Subscriber? sub = await _subs.getById(sid);
    if (sub == null) return 'settle_paid';
    final double due = await _billing.getDueAmount(sub, month);
    return due > 0 ? 'settle_unpaid_difference' : 'settle_paid';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_rows.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.rule_folder_outlined, size: 72, color: Colors.grey[400]),
            const SizedBox(height: 12),
            Text('corrections_tab_empty'.tr,
                style: TextStyle(color: Colors.grey[600], fontSize: 15)),
            const SizedBox(height: 4),
            Obx(() => Text(_month.selectedMonth.value,
                style: TextStyle(color: Colors.grey[500], fontSize: 12))),
          ],
        ),
      );
    }
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
      itemCount: _rows.length + (_loadingMore ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        if (i == _rows.length) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(8),
              child: CircularProgressIndicator(),
            ),
          );
        }
        return _CorrectionCard(row: _rows[i]);
      },
    );
  }
}

class _Row {
  final Correction correction;
  final String name;
  final String settle; // translation key
  const _Row({required this.correction, required this.name, required this.settle});
}

class _CorrectionCard extends StatelessWidget {
  final _Row row;
  const _CorrectionCard({required this.row});

  Color get _settleColor {
    switch (row.settle) {
      case 'settle_paid':
      case 'settle_refunded':
      case 'settle_carried_forward':
        return const Color(0xFF2E7D32);
      case 'settle_unpaid_difference':
        return const Color(0xFFC62828);
      case 'settle_credit':
        return const Color(0xFF1565C0);
      case 'settle_rejected':
        return Colors.grey.shade600;
      default:
        return const Color(0xFFEF6C00); // awaiting approval
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = row.correction;
    final bool inc = c.isIncrease;
    final String sign = c.difference < 0 ? '-' : '+';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.name.isEmpty ? (c.subscriberId ?? '') : row.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _settleColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  row.settle.tr,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: _settleColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // original -> new
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(fontSize: 12.5, color: Colors.grey[800]),
                    children: [
                      TextSpan(text: '${'correction_old_new_amps'.tr}: '),
                      TextSpan(
                        text: fmtAmount(c.oldAmps ?? 0),
                        style: const TextStyle(
                            decoration: TextDecoration.lineThrough),
                      ),
                      const TextSpan(text: '  →  '),
                      TextSpan(
                        text: fmtAmount(c.newAmps ?? 0),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
              // difference
              Text(
                "${'correction_difference'.tr}: $sign ${'iqd'.tr} "
                "${fmtAmount(c.difference.abs())}",
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: inc
                      ? const Color(0xFFC62828)
                      : const Color(0xFF2E7D32),
                ),
              ),
            ],
          ),
          if ((c.reason ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              c.reason!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: Colors.grey[600]),
            ),
          ],
        ],
      ),
    );
  }
}
