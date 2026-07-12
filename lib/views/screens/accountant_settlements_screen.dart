import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/month_controller.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/data/models/accountant_model.dart';
import 'package:generatormanagment/data/models/settlement_model.dart';
import 'package:generatormanagment/data/repositories/accountant_repository.dart';
import 'package:generatormanagment/data/repositories/expense_repository.dart';
import 'package:generatormanagment/data/repositories/settlement_repository.dart';
import 'package:generatormanagment/utils/date_fmt.dart';
import 'package:generatormanagment/utils/money.dart';

const Color _kBlue = Color(0xFF1565C0);

/// v16 item 7 — in-app accountant settlement approval (Admin/owner-only),
/// the Owner-Panel decision flow brought into Settings. Lists every accountant
/// settlement request (pending first) and lets the admin approve/reject. The
/// decision is OFFLINE-FIRST: it updates the LOCAL `settlements` row, then a
/// `SyncController.poke()` pushes it to the mirror so the accountant pulls it
/// (no direct API call — same model as the rest of the app). The mirror stays
/// the single source of truth via the existing sync engine.
class AccountantSettlementsScreen extends StatefulWidget {
  const AccountantSettlementsScreen({super.key});

  @override
  State<AccountantSettlementsScreen> createState() =>
      _AccountantSettlementsScreenState();
}

class _AccountantSettlementsScreenState
    extends State<AccountantSettlementsScreen> {
  final SettlementRepository _repo = SettlementRepository();
  final ExpenseRepository _expenseRepo = ExpenseRepository();
  final AccountantRepository _acctRepo = AccountantRepository();
  final AuthController _auth = Get.find();
  final ConnectivityService _net = ConnectivityService();

  List<({Settlement settlement, String accountantName})> _rows = [];
  bool _loading = true;
  bool _busy = false; // a decision is being saved
  // v23 review: the true pending total (not just the loaded page) for the banner.
  int _pendingTotal = 0;

  // v27 item 6: month + accountant filters. v36 item 3: the default is the
  // GLOBAL pricing month (the app-wide context), not the calendar month — the
  // arrows still browse other months while the screen is open.
  String _month = Get.isRegistered<MonthController>()
      ? Get.find<MonthController>().selectedMonth.value
      : DateFormat('yyyy-MM').format(DateTime.now());
  String? _acctFilter; // null = all accountants
  List<Accountant> _accountants = const [];
  // v30 T1 / v39 item 5 — summary figures for the active (month, accountant)
  // scope, ALL strictly month-isolated (v39 items 2/4):
  //   Total Settlement = Σ APPROVED cash+card settlements REQUESTED this month
  //   Net Expenses     = the month's expenses
  //   Net Profit       = Total Settlement − Net Expenses
  // so the admin can reconcile every figure with a calculator.
  // v35 item 12: the salary wallet was removed — no salary figures/cards.
  double _sumRevenue = 0, _sumExpenses = 0;
  // Per-accountant breakdown: approved settlement total (month), the month's
  // unsettled balance (v39 item 3 — month-scoped, no longer the all-time
  // wallet), latest settlement of the month (status + date).
  List<
      ({
        Accountant acct,
        double approved,
        double pending,
        String? lastStatus,
        String? lastDate,
      })> _acctBreakdown = const [];
  // Approved settlement money whose accountant no longer exists locally —
  // shown as its own breakdown row so Σ(breakdown) always equals the
  // Total Revenue card.
  double _revenueOther = 0;
  // v30 F4: per-accountant expenses for the month (only computed in the "all
  // accountants" view) so it's clear how each accountant's + the combined
  // expenses feed the net. Key = accountant id; plus [_expOwner] for
  // owner/unattributed expenses (accountant_id null).
  Map<String, double> _expByAccountant = {};
  double _expOwner = 0;

  // v23 item 7: paginate — the list previously loaded only the first 100 rows
  // (listAllForOwner default) with no way to reach older settlements.
  static const int _perPage = 20;
  int _page = 1;
  bool _hasMore = false;
  bool _moreLoading = false;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(pull: true);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  /// Pull the latest requests (best-effort, online) then read the local mirror,
  /// scoped to the active (month, accountant) filters (v27 item 6).
  Future<void> _load({bool pull = false}) async {
    if (mounted) setState(() => _loading = true);
    try {
      if (pull &&
          await _net.isOnline() &&
          Get.isRegistered<SyncController>()) {
        try {
          await Get.find<SyncController>().pull(silent: true);
        } catch (_) {/* fall through to local figures */}
      }
      if (_accountants.isEmpty) {
        try {
          _accountants = await _acctRepo.getAll();
        } catch (_) {}
      }
      // Fetch one extra to detect the next page (canonical pattern).
      final rows = await _repo.listAllForOwner(
          limit: _perPage + 1, month: _month, accountantId: _acctFilter);
      // v23 review: the pending banner must reflect the TRUE total, not the
      // page. v39 item 1: scoped to the selected month, like the list.
      int pendingTotal = 0;
      try {
        pendingTotal = await _repo.pendingCount(month: _month);
      } catch (_) {}
      // v30 T1 / v39: ALL settlement figures come from APPROVED SETTLEMENTS
      // (never subscriber receipts) — a settlement is money actually handed
      // over after the admin's approval — and EVERY figure on this page is
      // isolated to the selected month (v39 items 1-4).
      double revenue = 0, expenses = 0;
      double revenueOther = 0;
      final breakdown = <({
        Accountant acct,
        double approved,
        double pending,
        String? lastStatus,
        String? lastDate,
      })>[];
      // v30 F4: per-accountant expenses breakdown (only in the "all" view).
      final Map<String, double> expByAcct = {};
      double expOwner = 0;
      try {
        revenue = await _repo.approvedSumForMonth(_month, 'cash',
                accountantId: _acctFilter) +
            await _repo.approvedSumForMonth(_month, 'card',
                accountantId: _acctFilter);
        expenses = await _expenseRepo.getTotalExpenses(_month,
            accountantId: _acctFilter, branchId: null);

        // Per-accountant breakdown over the SAME scope as the cards, computed
        // from the SAME queries, so Σ(rows) always equals the card values.
        final scoped = _acctFilter == null
            ? _accountants
            : _accountants.where((a) => a.id == _acctFilter).toList();
        double sumApproved = 0;
        for (final a in scoped) {
          // v39 item 3: the unsettled figure is MONTH-ISOLATED — the month's
          // received cash minus the month's approved settlements (clamped ≥ 0)
          // — no longer the all-time wallet balance.
          final double pend = await _repo.monthUnsettled(a.id, _month);
          final double appr = await _repo.approvedSumForMonth(_month, 'cash',
                  accountantId: a.id) +
              await _repo.approvedSumForMonth(_month, 'card',
                  accountantId: a.id);
          String? lastStatus;
          String? lastDate;
          try {
            // v39 item 1: the newest settlement OF THE SELECTED MONTH.
            final last =
                await _repo.history(a.id, limit: 1, offset: 0, month: _month);
            if (last.isNotEmpty) {
              lastStatus = last.first.status;
              lastDate = last.first.requestedAt;
            }
          } catch (_) {}
          breakdown.add((
            acct: a,
            approved: appr,
            pending: pend,
            lastStatus: lastStatus,
            lastDate: lastDate,
          ));
          sumApproved += appr;
        }
        // Approved settlements whose accountant was deleted locally — surfaced
        // as a residual row so Σ(breakdown) == the Total Revenue card exactly.
        revenueOther =
            (revenue - sumApproved) > 0.005 ? (revenue - sumApproved) : 0;

        if (_acctFilter == null) {
          double sumAcct = 0;
          for (final a in _accountants) {
            final e = await _expenseRepo.getTotalExpenses(_month,
                accountantId: a.id, branchId: null);
            if (e > 0) expByAcct[a.id] = e;
            sumAcct += e;
          }
          // Whatever isn't attributed to an accountant is owner/other expenses.
          expOwner = (expenses - sumAcct) > 0 ? (expenses - sumAcct) : 0;
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _page = 1;
        _hasMore = rows.length > _perPage;
        _rows = _hasMore ? rows.sublist(0, _perPage) : rows;
        _pendingTotal = pendingTotal;
        _sumRevenue = revenue;
        _sumExpenses = expenses;
        _acctBreakdown = breakdown;
        _revenueOther = revenueOther;
        _expByAccountant = expByAcct;
        _expOwner = expOwner;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _shiftMonth(int delta) {
    final parts = _month.split('-');
    final d = DateTime(int.parse(parts[0]), int.parse(parts[1]) + delta);
    _month = DateFormat('yyyy-MM').format(d);
    _load();
  }

  Future<void> _loadMore() async {
    if (_moreLoading || !_hasMore || _loading) return;
    setState(() => _moreLoading = true);
    try {
      final next = await _repo.listAllForOwner(
          limit: _perPage + 1,
          offset: _page * _perPage,
          month: _month,
          accountantId: _acctFilter);
      if (!mounted) return;
      setState(() {
        _hasMore = next.length > _perPage;
        _rows.addAll(_hasMore ? next.sublist(0, _perPage) : next);
        _page += 1;
      });
    } finally {
      if (mounted) setState(() => _moreLoading = false);
    }
  }

  Future<void> _decide(Settlement s, String status) async {
    if (_busy) return;
    // v27 item 3: approving a SALARY request requires the owner to ENTER the
    // amount first (the accountant requested it with no amount).
    double? salaryAmount;
    // v35 item 12: the salary wallet was removed, but LEGACY pending salary
    // rows may still exist in production mirrors — they stay decidable here
    // (approve still asks for the amount) so no request is ever stuck.
    if (status == 'approved' && s.method == 'salary') {
      salaryAmount = await _askSalaryAmount();
      if (salaryAmount == null) return; // cancelled
    } else {
      final confirmKey = status == 'approved'
          ? 'approve_settlement_confirm'
          : 'reject_settlement_confirm';
      final ok = await Get.defaultDialog<bool>(
        title: 'settlement'.tr,
        middleText: confirmKey.tr,
        textConfirm: 'continue'.tr,
        textCancel: 'cancel'.tr,
        onConfirm: () => Get.back(result: true),
        onCancel: () {},
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    bool applied = false;
    try {
      // v35 item 6: false = the request was no longer pending (raced/duplicate
      // decision) — nothing was changed; the reload below shows the truth.
      applied = await _repo.decide(s, status,
          decidedBy: _auth.currentUser.value?.id, amount: salaryAmount);
      if (applied) SyncController.poke(); // push the decision into the mirror
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!applied) return; // no misleading success toast for a no-op
    Get.snackbar(
      'settlement'.tr,
      (status == 'approved'
              ? 'settlement_approved_msg'
              : 'settlement_rejected_msg')
          .tr,
      backgroundColor: status == 'approved' ? Colors.green : Colors.redAccent,
      colorText: Colors.white,
      snackPosition: SnackPosition.BOTTOM,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pendingTotal; // v23 review: true total, not just the page
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(title: Text('accountant_settlements'.tr)),
      body: SafeArea(
        // v30 T1: everything below the filter row lives in ONE scrollable, so
        // PULL-TO-REFRESH re-fetches (mirror pull) and recomputes every
        // financial value — summary cards, breakdowns AND the requests list.
        child: Column(
          children: [
            _filterRow(),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: () => _load(pull: true),
                      child: ListView(
                        controller: _scroll,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(12),
                        children: [
                          _summaryCards(),
                          _expensesBreakdown(),
                          ..._accountantBreakdown(),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(2, 12, 2, 8),
                            child: Text('settlement_history'.tr,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15)),
                          ),
                          if (pending > 0)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                '${'status_pending'.tr}: $pending',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.orange),
                              ),
                            ),
                          if (_rows.isEmpty) ...[
                            const SizedBox(height: 24),
                            Icon(Icons.receipt_long,
                                size: 64, color: Colors.grey.shade400),
                            const SizedBox(height: 12),
                            Center(
                              child: Text('no_settlements'.tr,
                                  style:
                                      TextStyle(color: Colors.grey.shade600)),
                            ),
                            const SizedBox(height: 24),
                          ] else
                            ..._rows.map(
                                (r) => _tile(r.settlement, r.accountantName)),
                          if (_moreLoading)
                            const Padding(
                              padding: EdgeInsets.all(12),
                              child:
                                  Center(child: CircularProgressIndicator()),
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// v27 item 3: prompt the owner for the salary amount on approval. Returns
  /// the entered amount, or null if cancelled/invalid. Closes via the dialog's
  /// own route (R-GETX) and validates a positive number.
  Future<double?> _askSalaryAmount() async {
    final ctrl = TextEditingController();
    return Get.dialog<double>(
      Builder(builder: (context) {
        return AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('salary_amount'.tr),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'salary_amount'.tr,
              prefixText: '${'iqd'.tr} ',
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('cancel'.tr),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _kBlue),
              onPressed: () {
                final v = double.tryParse(ctrl.text.trim());
                if (v == null || v <= 0) {
                  Get.snackbar('error'.tr, 'amps_invalid'.tr,
                      snackPosition: SnackPosition.BOTTOM);
                  return;
                }
                Navigator.of(context).pop(v);
              },
              child: Text('approve'.tr),
            ),
          ],
        );
      }),
    );
  }

  /// v27 item 6: month + accountant filter row (responsive; SafeArea handled by
  /// the Scaffold body). Numeric month nav; "all accountants" default.
  Widget _filterRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _shiftMonth(-1),
          ),
          Text(_month,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () => _shiftMonth(1),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                isExpanded: true,
                value: _acctFilter,
                hint: Text('all_accountants'.tr),
                items: [
                  DropdownMenuItem<String?>(
                      value: null, child: Text('all_accountants'.tr)),
                  ..._accountants.map((a) => DropdownMenuItem<String?>(
                      value: a.id, child: Text(a.displayName))),
                ],
                onChanged: (v) {
                  setState(() => _acctFilter = v);
                  _load();
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// v39 item 5 — exactly THREE summary cards (owner decision), all isolated
  /// to the selected month:
  ///   Total Settlement (Σ approved cash+card settlements requested this month)
  ///   · Net Expenses (the month's expenses)
  ///   · Net Profit (Total Settlement − Net Expenses).
  /// Responsive: column count + card sizing adapt to the available width.
  Widget _summaryCards() {
    final double netProfit = _sumRevenue - _sumExpenses;
    final items = <({IconData icon, String label, double value, Color color})>[
      (
        icon: Icons.account_balance_wallet,
        label: 'total_settlements',
        value: _sumRevenue,
        color: _kBlue,
      ),
      (
        icon: Icons.receipt_long,
        label: 'net_expenses',
        value: _sumExpenses,
        color: const Color(0xFFFB8C00),
      ),
      (
        icon: netProfit >= 0 ? Icons.trending_up : Icons.trending_down,
        label: 'net_profit',
        value: netProfit,
        color: netProfit < 0 ? Colors.red : const Color(0xFF2E7D32),
      ),
    ];
    return LayoutBuilder(builder: (context, box) {
      final double w = box.maxWidth;
      final int cols = w >= 560 ? 3 : 2;
      final double scale = w >= 900 ? 1.2 : (w >= 560 ? 1.1 : 1.0);
      final double gap = w >= 560 ? 14 : 10;
      return GridView.count(
        crossAxisCount: cols,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: gap,
        crossAxisSpacing: gap,
        childAspectRatio: 1.55,
        children: [
          for (final c in items) _sumCard(c.icon, c.label.tr, c.value, c.color, scale),
        ],
      );
    });
  }

  Widget _sumCard(
      IconData icon, String label, double value, Color color, double scale) {
    return Container(
      padding: EdgeInsets.all(10 * scale),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.blue.withValues(alpha: 0.06), blurRadius: 8),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: color, size: 20 * scale),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(fmtAmount(value),
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16 * scale,
                      color: color)),
            ),
          ),
          Text(label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(fontSize: 10.5 * scale, color: Colors.blueGrey)),
        ],
      ),
    );
  }

  /// v30 T1 / v39: per-accountant breakdown — the month's approved settlement
  /// total, the month's UNSETTLED balance (warning-highlighted when > 0), and
  /// the month's latest settlement status + date. Σ(approved) + residual ==
  /// the Total Settlement card, by construction.
  List<Widget> _accountantBreakdown() {
    if (_acctBreakdown.isEmpty && _revenueOther <= 0) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(2, 12, 2, 8),
        child: Text('by_accountant'.tr,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      ),
      for (final b in _acctBreakdown) _acctCard(b),
      if (_revenueOther > 0)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(14)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('accountant'.tr,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(fmtAmount(_revenueOther),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: Color(0xFF00897B))),
            ],
          ),
        ),
    ];
  }

  Widget _acctCard(
      ({
        Accountant acct,
        double approved,
        double pending,
        String? lastStatus,
        String? lastDate,
      }) b) {
    final st = b.lastStatus;
    final Color stColor = st == 'approved'
        ? Colors.green
        : (st == 'rejected'
            ? Colors.redAccent
            : (st == 'pending' ? Colors.orange : Colors.blueGrey));
    final String stText = st == null
        ? 'no_settlements'.tr
        : (st == 'approved'
                ? 'status_approved'
                : (st == 'rejected' ? 'status_rejected' : 'status_pending'))
            .tr;
    String dateText = '';
    if (b.lastDate != null && b.lastDate!.isNotEmpty) {
      final d = DateTime.tryParse(b.lastDate!);
      dateText = d == null ? b.lastDate! : fmtDateTime12(d.toLocal());
    }
    final bool warn = b.pending > 0;
    Widget kv(String label, String value, Color color, {bool highlight = false}) =>
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: highlight
                ? const Color(0xFFEF6C00).withValues(alpha: 0.12)
                : const Color(0xFFF5F7FA),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 10.5, color: Colors.blueGrey)),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(value,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: color)),
              ),
            ],
          ),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(b.acct.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: stColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20)),
                child: Text(stText,
                    style: TextStyle(
                        color: stColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: kv('approved_settlement_total'.tr,
                    fmtAmount(b.approved), const Color(0xFF00897B)),
              ),
              const SizedBox(width: 8),
              // Money still HELD by the accountant → warning highlight so the
              // admin spots unsettled cash immediately (v30 T1).
              Expanded(
                child: kv('pending_settlement_balance'.tr,
                    fmtAmount(b.pending),
                    warn ? const Color(0xFFB45309) : Colors.blueGrey,
                    highlight: warn),
              ),
            ],
          ),
          if (dateText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${'last_settlement'.tr}: $dateText',
                  style:
                      TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            ),
        ],
      ),
    );
  }

  /// v30 F4: a collapsible per-accountant expenses breakdown, shown only in the
  /// "all accountants" view, so it is clear how each accountant's + the combined
  /// expenses feed the net. Collapsed by default (doesn't crowd the list).
  Widget _expensesBreakdown() {
    if (_acctFilter != null) return const SizedBox.shrink();
    final entries = _expByAccountant.entries.toList();
    if (entries.isEmpty && _expOwner <= 0) return const SizedBox.shrink();
    final nameOf = {for (final a in _accountants) a.id: a.displayName};
    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(16)),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          leading:
              const Icon(Icons.receipt_long, color: Color(0xFFEF6C00)),
          title: Text('expenses_by_accountant'.tr,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          subtitle: Text(
              '${'total_expenses'.tr}: ${fmtAmount(_sumExpenses)}',
              style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
          children: [
            for (final e in entries)
              _expRow(nameOf[e.key] ?? 'accountant'.tr, e.value),
            if (_expOwner > 0) _expRow('owner'.tr, _expOwner),
          ],
        ),
      ),
    );
  }

  Widget _expRow(String label, double value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w500, fontSize: 13)),
            ),
            Text(fmtAmount(value),
                style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: Color(0xFFEF6C00))),
          ],
        ),
      );

  Widget _tile(Settlement s, String accountantName) {
    final color = s.isApproved
        ? Colors.green
        : (s.isRejected ? Colors.redAccent : Colors.orange);
    final statusKey = s.isApproved
        ? 'status_approved'
        : (s.isRejected ? 'status_rejected' : 'status_pending');
    final methodLabel = s.method == 'salary'
        ? 'salary_wallet'.tr
        : (s.method == 'card' ? 'pay_card'.tr : 'pay_cash'.tr);
    final methodIcon = s.method == 'salary'
        ? Icons.account_balance_wallet
        : (s.method == 'card' ? Icons.credit_card : Icons.payments);
    // v27 item 3: a pending salary shows "—" (amount entered on approval).
    final amountText = (s.method == 'salary' && s.isPending)
        ? '— · $methodLabel'
        : '${fmtAmount(s.amount)} ${'iqd'.tr} · $methodLabel';
    final when = s.requestedAt == null
        ? ''
        : (DateTime.tryParse(s.requestedAt!) != null
            ? fmtDateTime12(DateTime.parse(s.requestedAt!).toLocal())
            : s.requestedAt!);
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
                  child: Icon(methodIcon, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        accountantName.isEmpty
                            ? 'accountant'.tr
                            : accountantName,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          amountText,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (when.isNotEmpty)
                        Text(when,
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600)),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20)),
                  child: Text(statusKey.tr,
                      style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.bold,
                          fontSize: 12)),
                ),
              ],
            ),
            if (s.isPending) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          _busy ? null : () => _decide(s, 'rejected'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent),
                      icon: const Icon(Icons.close, size: 18),
                      label: Text('reject'.tr),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed:
                          _busy ? null : () => _decide(s, 'approved'),
                      style:
                          FilledButton.styleFrom(backgroundColor: _kBlue),
                      icon: const Icon(Icons.check, size: 18),
                      label: Text('approve'.tr),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
