import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:generatormanagment/controllers/settlement_controller.dart';
import 'package:generatormanagment/data/models/settlement_model.dart';

const Color _kBlue = Color(0xFF1565C0);

/// v11 — accountant "My Wallet": total collected, settled, current balance, a
/// Request Settlement button, and the paginated settlement history.
class MyWalletScreen extends StatefulWidget {
  const MyWalletScreen({super.key});

  @override
  State<MyWalletScreen> createState() => _MyWalletScreenState();
}

class _MyWalletScreenState extends State<MyWalletScreen> {
  final SettlementController c = Get.find<SettlementController>();
  final ScrollController _scroll = ScrollController();
  final NumberFormat _money = NumberFormat.decimalPattern();

  @override
  void initState() {
    super.initState();
    c.load();
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
      body: Obx(() {
        if (c.isLoading.value && c.history.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        return RefreshIndicator(
          onRefresh: c.load,
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              // Balance card.
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [_kBlue, Color(0xFF42A5F5)]),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  children: [
                    Text('wallet_balance'.tr,
                        style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 6),
                    Text('${_money.format(c.balance.value)} ${'iqd'.tr}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _miniStat('wallet_collected'.tr, c.collected.value),
                        _miniStat('wallet_settled'.tr, c.settled.value),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Request Settlement button.
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _kBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.request_quote),
                  label: Text(c.hasPending.value
                      ? 'wallet_pending_exists'.tr
                      : 'request_settlement'.tr),
                  onPressed: (c.hasPending.value || c.balance.value <= 0)
                      ? null
                      : () => c.requestSettlement(),
                ),
              ),
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
      }),
    );
  }

  Widget _miniStat(String label, double v) => Column(
        children: [
          Text(_money.format(v),
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
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        leading: CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.12),
            child: Icon(Icons.account_balance_wallet, color: color)),
        title: Text('${_money.format(s.amount)} ${'iqd'.tr}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(s.requestedAt == null
            ? ''
            : (DateTime.tryParse(s.requestedAt!) != null
                ? DateFormat('yyyy-MM-dd HH:mm')
                    .format(DateTime.parse(s.requestedAt!).toLocal())
                : s.requestedAt!)),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20)),
          child: Text(statusKey.tr,
              style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
        ),
      ),
    );
  }
}
