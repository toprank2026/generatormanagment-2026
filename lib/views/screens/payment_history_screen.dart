import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';

/// Dedicated, paginated screen showing a subscriber's paid-bills (receipts)
/// history. Self-contained pagination (its own state + repository) so it does
/// not interfere with the inline history on the detail screen.
class PaymentHistoryScreen extends StatefulWidget {
  final Subscriber subscriber;
  const PaymentHistoryScreen({super.key, required this.subscriber});

  @override
  State<PaymentHistoryScreen> createState() => _PaymentHistoryScreenState();
}

class _PaymentHistoryScreenState extends State<PaymentHistoryScreen> {
  final ReceiptRepository _repo = ReceiptRepository();
  final ScrollController _scroll = ScrollController();

  static const int _perPage = 15;
  final List<Receipt> _items = [];
  int _page = 1;
  bool _hasNext = false;
  bool _loading = true;
  bool _moreLoading = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(page: 1);
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

  Future<void> _load({required int page}) async {
    if (page == 1) {
      setState(() => _loading = true);
    } else {
      setState(() => _moreLoading = true);
    }
    // Fetch one extra to detect the next page.
    final result = await _repo.getBySubscriber(
      widget.subscriber.id,
      limit: _perPage + 1,
      offset: (page - 1) * _perPage,
    );
    final hasNext = result.length > _perPage;
    final newItems = hasNext ? result.sublist(0, _perPage) : result;
    setState(() {
      _page = page;
      _hasNext = hasNext;
      if (page == 1) {
        _items
          ..clear()
          ..addAll(newItems);
      } else {
        _items.addAll(newItems);
      }
      _loading = false;
      _moreLoading = false;
    });
  }

  void _loadMore() {
    if (_hasNext && !_moreLoading && !_loading) {
      _load(page: _page + 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.decimalPattern();
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        iconTheme: const IconThemeData(color: Colors.white),
        centerTitle: true,
        elevation: 0,
        title: Column(
          children: [
            Text(
              'payment_history'.tr,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            Text(
              widget.subscriber.name,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.receipt_long_outlined,
                          size: 80, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text(
                        'no_payments'.tr,
                        style: TextStyle(color: Colors.grey[600], fontSize: 16),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => _load(page: 1),
                  child: ListView.separated(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
                    itemCount: _items.length + (_moreLoading ? 1 : 0),
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      if (index == _items.length) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(8.0),
                            child: CircularProgressIndicator(),
                          ),
                        );
                      }
                      final r = _items[index];
                      final refunded = r.status != 'valid';
                      return Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.blue.withValues(alpha: 0.05),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 6),
                          leading: CircleAvatar(
                            backgroundColor: const Color(0xFFE3F2FD),
                            child: const Icon(Icons.receipt_long,
                                color: Color(0xFF1565C0)),
                          ),
                          title: Text(
                            "${'receipt_no'.tr}${r.receiptNo}",
                            style:
                                const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            "${r.month}  •  ${DateFormat('MMM d, yyyy', Get.locale?.toString()).format(DateTime.parse(r.issuedAt))}",
                            style: TextStyle(
                                color: Colors.grey[600], fontSize: 12),
                          ),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                "${currency.format(r.paidAmount)} ${'iqd'.tr}",
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  color: refunded
                                      ? Colors.grey
                                      : const Color(0xFF1565C0),
                                ),
                              ),
                              if (refunded)
                                Text('subscription_rejected'.tr,
                                    style: const TextStyle(
                                        fontSize: 10, color: Colors.red)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
