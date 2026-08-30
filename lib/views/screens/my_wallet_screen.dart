import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/month_controller.dart';
import 'package:generatormanagment/controllers/settlement_controller.dart';
import 'package:generatormanagment/data/models/settlement_model.dart';
import 'package:generatormanagment/utils/date_fmt.dart';
import 'package:generatormanagment/utils/money.dart';

const Color _kBlue = Color(0xFF1565C0);
const Color _kTeal = Color(0xFF00897B);

/// v11/v12 — accountant wallets: Cash + Credit-Card, each with collected/settled/
/// balance + a Request Settlement button, and a shared paginated settlement
/// history. Pull-updates on open (item 2) so balances/decisions are current.
///
/// v42 item 1 — every figure on this screen belongs to ONE accounting month
/// (the global tariff month). The month is therefore stated three times — a
/// banner at the top, a chip on each wallet card and on the history header — so
/// a balance that "reset" on the 1st is read as *a new month*, never as lost
/// money. The month is READ-ONLY here: it is selected only on the Monthly
/// Pricing screen (R9), and [SettlementController] already reloads everything
/// on change — this screen only renders it.
class MyWalletScreen extends StatefulWidget {
  const MyWalletScreen({super.key});

  @override
  State<MyWalletScreen> createState() => _MyWalletScreenState();
}

class _MyWalletScreenState extends State<MyWalletScreen> {
  final SettlementController c = Get.find<SettlementController>();
  // v42 item 1: the global accounting month, READ-ONLY (permanent controller).
  final MonthController _month = Get.find<MonthController>();
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
              // v42 item 1: which accounting month every figure below belongs to.
              _monthBanner(),
              const SizedBox(height: 14),
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
              const SizedBox(height: 14),
              // v42 review fix: the LIFETIME unsettled total. The cards above
              // are per-month (the owner's requirement), so without this a
              // month nobody reopens would hide cash the accountant still
              // holds. It is also the ceiling every settlement request is
              // capped at, so the same money can never be handed over twice.
              _lifetimeCard(
                  cash: c.lifetimeCashBalance.value,
                  card: c.lifetimeCardBalance.value),
              const SizedBox(height: 22),
              // v42 item 1: the history is THIS MONTH's history — labelled with
              // the month so an empty list reads as "nothing yet this month",
              // never as a vanished record.
              Row(
                children: [
                  Expanded(
                    child: Text('settlement_history'.tr,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                  const SizedBox(width: 8),
                  _monthChip(
                      background: _kBlue.withValues(alpha: 0.10),
                      foreground: _kBlue),
                ],
              ),
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
          // v42 item 1: the accounting month this balance belongs to, on its own
          // line so it is never squeezed against the balance figure on a phone,
          // and start-aligned so it follows the RTL/LTR direction of the locale.
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: _monthChip(
                background: Colors.white.withValues(alpha: 0.22),
                foreground: Colors.white),
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

  /// v42 item 1 — the accounting-month header. States the month the WHOLE
  /// screen is scoped to plus the "these figures belong to this month only"
  /// caption, so an accountant opening the wallet after the month rolled over
  /// reads the balance as carried into a closed month, never as money lost.
  Widget _monthBanner() {
    final bool tablet = Get.mediaQuery.size.shortestSide >= 600;
    return Container(
      padding: EdgeInsets.all(tablet ? 16 : 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kBlue.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: _kBlue.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.calendar_month, color: _kBlue, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // R9: READ-ONLY — the month is selected only on Monthly Pricing.
                Obx(
                  () => Text(
                    "${'wallet_month'.tr}: ${_month.selectedMonth.value}",
                    style: TextStyle(
                        color: _kBlue,
                        fontSize: tablet ? 17 : 15,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 2),
                Text('wallet_month_note'.tr,
                    style:
                        const TextStyle(color: Colors.blueGrey, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// v42 review fix — the all-months "still in hand" summary. Deliberately a
  /// quiet, flat card (not a gradient hero) so it reads as context for the two
  /// month cards above rather than competing with them.
  Widget _lifetimeCard({required double cash, required double card}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE0E0E0)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.savings_outlined, size: 18, color: _kBlue),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('wallet_lifetime'.tr,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text('${'cash_wallet'.tr}: ${'iqd'.tr} ${fmtAmount(cash)}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, color: _kBlue)),
                ),
                Expanded(
                  child: Text('${'card_wallet'.tr}: ${'iqd'.tr} ${fmtAmount(card)}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, color: _kTeal)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('wallet_lifetime_note'.tr,
                style: const TextStyle(fontSize: 11, color: Colors.blueGrey)),
          ],
        ),
      );

  /// v42 item 1 — compact month pill, reused on both wallet cards (white on the
  /// gradient) and on the history header (blue on white). The [Obx] builder
  /// reads `selectedMonth` FIRST, with no short-circuiting condition in front of
  /// it — the release-mode grey-screen trap.
  Widget _monthChip({required Color background, required Color foreground}) =>
      Obx(
        () => Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
              color: background, borderRadius: BorderRadius.circular(20)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.calendar_month, color: foreground, size: 13),
              const SizedBox(width: 4),
              Text(_month.selectedMonth.value,
                  style: TextStyle(
                      color: foreground,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      );

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
