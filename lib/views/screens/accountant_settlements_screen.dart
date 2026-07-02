import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/data/models/settlement_model.dart';
import 'package:generatormanagment/data/repositories/settlement_repository.dart';
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
  final AuthController _auth = Get.find();
  final ConnectivityService _net = ConnectivityService();

  List<({Settlement settlement, String accountantName})> _rows = [];
  bool _loading = true;
  bool _busy = false; // a decision is being saved
  // v23 review: the true pending total (not just the loaded page) for the banner.
  int _pendingTotal = 0;

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

  /// Pull the latest requests (best-effort, online) then read the local mirror.
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
      // Fetch one extra to detect the next page (canonical pattern).
      final rows = await _repo.listAllForOwner(limit: _perPage + 1);
      // v23 review: the pending banner must reflect the TRUE total, not the page.
      int pendingTotal = 0;
      try {
        pendingTotal = await _repo.pendingCount();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _page = 1;
        _hasMore = rows.length > _perPage;
        _rows = _hasMore ? rows.sublist(0, _perPage) : rows;
        _pendingTotal = pendingTotal;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_moreLoading || !_hasMore || _loading) return;
    setState(() => _moreLoading = true);
    try {
      final next = await _repo.listAllForOwner(
          limit: _perPage + 1, offset: _page * _perPage);
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
    setState(() => _busy = true);
    try {
      await _repo.decide(s, status, decidedBy: _auth.currentUser.value?.id);
      SyncController.poke(); // push the decision into the mirror
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
      appBar: AppBar(title: Text('accountant_settlements'.tr)),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: () => _load(pull: true),
                child: _rows.isEmpty
                    ? ListView(
                        controller: _scroll,
                        children: [
                          const SizedBox(height: 120),
                          Icon(Icons.receipt_long,
                              size: 64, color: Colors.grey.shade400),
                          const SizedBox(height: 12),
                          Center(
                            child: Text('no_settlements'.tr,
                                style: TextStyle(color: Colors.grey.shade600)),
                          ),
                        ],
                      )
                    : ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.all(12),
                        children: [
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
                          ..._rows.map((r) => _tile(r.settlement, r.accountantName)),
                          if (_moreLoading)
                            const Padding(
                              padding: EdgeInsets.all(12),
                              child: Center(child: CircularProgressIndicator()),
                            ),
                        ],
                      ),
              ),
      ),
    );
  }

  Widget _tile(Settlement s, String accountantName) {
    final color = s.isApproved
        ? Colors.green
        : (s.isRejected ? Colors.redAccent : Colors.orange);
    final statusKey = s.isApproved
        ? 'status_approved'
        : (s.isRejected ? 'status_rejected' : 'status_pending');
    final methodLabel = s.method == 'card' ? 'pay_card'.tr : 'pay_cash'.tr;
    final when = s.requestedAt == null
        ? ''
        : (DateTime.tryParse(s.requestedAt!) != null
            ? DateFormat('yyyy-MM-dd HH:mm')
                .format(DateTime.parse(s.requestedAt!).toLocal())
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
                  child: Icon(
                      s.method == 'card' ? Icons.credit_card : Icons.payments,
                      color: color),
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
                          '${fmtAmount(s.amount)} ${'iqd'.tr} · $methodLabel',
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
