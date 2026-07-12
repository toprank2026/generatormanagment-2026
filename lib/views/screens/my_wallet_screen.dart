import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/settlement_controller.dart';
import 'package:generatormanagment/data/models/settlement_model.dart';
import 'package:generatormanagment/utils/date_fmt.dart';
import 'package:generatormanagment/utils/money.dart';

const Color _kBlue = Color(0xFF1565C0);
const Color _kTeal = Color(0xFF00897B);

/// v11/v12 — accountant wallets: Cash + Credit-Card, each with collected/settled/
/// balance + a Request Settlement button, and a shared paginated settlement
/// history. Pull-updates on open (item 2) so balances/decisions are current.
class MyWalletScreen extends StatefulWidget {
  const MyWalletScreen({super.key});

  @override
  State<MyWalletScreen> createState() => _MyWalletScreenState();
}

class _MyWalletScreenState extends State<MyWalletScreen> {
  final SettlementController c = Get.find<SettlementController>();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    c.load(pull: true); // item 2: pull latest before showing
    _scroll.addListener(() {
      if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
        c.loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(
        title: Text('my_wallet'.tr,
            style: const TextStyle(
                fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: _kBlue,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(child: Obx(() {
        if (c.isLoading.value && c.history.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        return RefreshIndicator(
          onRefresh: () => c.load(pull: true),
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              _walletCard(
                title: 'cash_wallet'.tr,
                icon: Icons.payments,
                gradient: const [_kBlue, Color(0xFF42A5F5)],
                balance: c.cashBalance.value,
                collected: c.cashCollected.value,
                settled: c.cashSettled.value,
                pending: c.hasPendingCash.value,
                method: 'cash',
              ),
              const SizedBox(height: 14),
              _walletCard(
                title: 'card_wallet'.tr,
                icon: Icons.credit_card,
                gradient: const [_kTeal, Color(0xFF4DB6AC)],
                balance: c.cardBalance.value,
                collected: c.cardCollected.value,
                settled: c.cardSettled.value,
                pending: c.hasPendingCard.value,
                method: 'card',
              ),
              // v35 item 12: the SALARY wallet card was REMOVED (no new salary
              // requests); legacy salary settlements still show in the history.
              const SizedBox(height: 22),
              Text('settlement_history'.tr,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 10),
              if (c.history.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Center(
                      child: Text('no_settlements'.tr,
                          style: const TextStyle(color: Colors.blueGrey))),
                )
              else
                ...c.history.map(_tile),
              if (c.isMoreLoading.value)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        );
      })),
    );
  }

  Widget _walletCard({
    required String title,
    required IconData icon,
    required List<Color> gradient,
    required double balance,
    required double collected,
    required double settled,
    required bool pending,
    required String method,
  }) {
    // v27 item 3: shorter, RESPONSIVE cards — tablets get a bit more room.
    // v35 item 12: salary branches removed — only cash/card cards exist now.
    final bool tablet = Get.mediaQuery.size.shortestSide >= 600;
    final double pad = tablet ? 16 : 12;
    final double balanceFont = tablet ? 26 : 22;
    return Container(
      padding: EdgeInsets.all(pad),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: gradient),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
              ),
              Text('${fmtAmount(balance)} ${'iqd'.tr}',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: balanceFont,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _miniStat('wallet_collected'.tr, collected),
              _miniStat('wallet_settled'.tr, settled),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 40,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: gradient.first,
                padding: EdgeInsets.zero,
              ),
              // v14: loading state while the request saves (disabled + spinner).
              icon: c.isRequesting.value
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.request_quote, size: 18),
              label: Text(
                c.isRequesting.value
                    ? 'saving'.tr
                    : (pending
                        ? 'wallet_pending_exists'.tr
                        : 'request_settlement'.tr),
                overflow: TextOverflow.ellipsis,
              ),
              onPressed: (pending || c.isRequesting.value || balance <= 0)
                  ? null
                  : () => c.requestSettlement(method),
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, double v) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(fmtAmount(v),
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      );

  Widget _tile(Settlement s) {
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
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        leading: CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.12),
            child: Icon(methodIcon, color: color)),
        title: Text('${fmtAmount(s.amount)} ${'iqd'.tr} · $methodLabel',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(s.requestedAt == null
            ? ''
            : (DateTime.tryParse(s.requestedAt!) != null
                ? fmtDateTime12(DateTime.parse(s.requestedAt!).toLocal())
                : s.requestedAt!)),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20)),
          child: Text(statusKey.tr,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.bold, fontSize: 12)),
        ),
      ),
    );
  }
}
