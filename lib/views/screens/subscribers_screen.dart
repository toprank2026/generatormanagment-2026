import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/core_controller.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/core/permissions.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/views/screens/add_subscriber_screen.dart';
import 'package:generatormanagment/views/screens/subscriber_detail_screen.dart';

class SubscribersScreen extends StatefulWidget {
  final String? filter; // 'paid', 'unpaid'
  final String? boardId;
  const SubscribersScreen({super.key, this.filter, this.boardId});

  @override
  State<SubscribersScreen> createState() => _SubscribersScreenState();
}

class _SubscribersScreenState extends State<SubscribersScreen>
    with SingleTickerProviderStateMixin {
  final CoreController controller = Get.find<CoreController>();
  final AuthController auth = Get.find<AuthController>();
  final TextEditingController searchCtrl = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // R5: category-filter tabs. Shown on All / Paid / Unpaid (boardId == null),
  // not in the board-scoped mode. `null` value = "All categories".
  static const List<MapEntry<String, String?>> _categoryTabs = [
    MapEntry('all_categories', null),
    MapEntry('cat_gold', SubscriberCategory.gold),
    MapEntry('cat_standard', SubscriberCategory.standard),
    MapEntry('cat_commercial', SubscriberCategory.commercial),
  ];
  TabController? _tabController;
  String? _category; // active category filter (null = all)

  bool get _showTabs => widget.boardId == null;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    if (_showTabs) {
      _tabController =
          TabController(length: _categoryTabs.length, vsync: this);
      _tabController!.addListener(() {
        if (_tabController!.indexIsChanging) return;
        _category = _categoryTabs[_tabController!.index].value;
        _reload();
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  /// Reload the list for the current variant + category tab (R5).
  /// v22 item 1: the search query reaches ALL variants (all / paid / unpaid /
  /// board-scoped), composed with the active filters at the SQL level.
  void _reload() {
    final String? q = searchCtrl.text.isEmpty ? null : searchCtrl.text;
    if (widget.filter != null) {
      controller.loadFilteredSubscribers(widget.filter!,
          category: _category, query: q);
    } else if (widget.boardId != null) {
      controller.loadBoardSubscribers(widget.boardId!, query: q);
    } else {
      controller.loadSubscribers(query: q, category: _category);
    }
  }

  @override
  void dispose() {
    _tabController?.dispose();
    _scrollController.dispose();
    searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      // Only the All list paginates (Paid/Unpaid load in full).
      if (widget.filter == null && widget.boardId == null) {
        controller.loadMore();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD), // Light blue background
      appBar: AppBar(
        title: Column(
          children: [
            Text(
              'subscribers_title'.tr,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            if (widget.filter != null || widget.boardId != null)
              Text(
                widget.filter != null
                    ? (widget.filter == 'paid'
                          ? 'paid_subscribers'.tr
                          : 'unpaid_subscribers'.tr)
                    : 'board_filter_active'.tr,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
          ],
        ),
        backgroundColor: const Color(0xFF1565C0),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(_showTabs ? 128 : 80),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Search field first.
              Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, _showTabs ? 6 : 16),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: TextField(
                    controller: searchCtrl,
                    decoration: InputDecoration(
                      hintText: 'search_hint'.tr,
                      prefixIcon: Icon(Icons.search, color: Color(0xFF1565C0)),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                    onChanged: (val) => _reload(),
                  ),
                ),
              ),
              // R5: category filter tabs UNDER the search field.
              if (_showTabs && _tabController != null)
                TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  indicatorColor: Colors.white,
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white70,
                  tabAlignment: TabAlignment.center,
                  tabs: [
                    for (final t in _categoryTabs) Tab(text: t.key.tr),
                  ],
                ),
            ],
          ),
        ),
      ),
      // R3: the Add-Subscriber button appears ONLY on the All Subscribers
      // screen (filter == null & no board). Build the Obx ONLY there, so its
      // builder ALWAYS reads an observable (auth.can -> currentUser). Putting
      // the filter check INSIDE the Obx short-circuits the `&&` before any
      // observable is read on Paid/Unpaid, which throws GetX's "improper use of
      // Obx" error — rendered as a grey ErrorWidget over the whole screen in
      // release builds.
      floatingActionButton: (widget.filter == null && widget.boardId == null)
          ? Obx(
              () => auth.can(Perm.subscribers)
                  ? FloatingActionButton.extended(
                      onPressed: () => Get.to(
                        () => const AddSubscriberScreen(),
                      )?.then((_) => _reload()),
                      icon: const Icon(Icons.person_add, color: Colors.white),
                      label: Text(
                        'add_new'.tr,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      backgroundColor: const Color(0xFF1565C0),
                    )
                  : const SizedBox.shrink(),
            )
          : null,
      body: SafeArea(child: GetBuilder<CoreController>(
        builder: (ctrl) {
          if (ctrl.isLoading.value) {
            return const Center(child: CircularProgressIndicator());
          }
          if (ctrl.subscribers.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.people_outline, size: 80, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(
                    'no_subscribers'.tr,
                    style: TextStyle(color: Colors.grey[600], fontSize: 16),
                  ),
                ],
              ),
            );
          }

          return Column(
            children: [
              Expanded(
                child: ListView.separated(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(
                    16,
                    16,
                    16,
                    80,
                  ), // Padding for FAB
                  itemCount:
                      ctrl.subscribers.length +
                      (ctrl.isMoreLoading.value ? 1 : 0),
                  separatorBuilder: (c, i) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    if (index == ctrl.subscribers.length) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(8.0),
                          child: CircularProgressIndicator(),
                        ),
                      );
                    }
                    final sub = ctrl.subscribers[index];
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
                          horizontal: 16,
                          vertical: 8,
                        ),
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFFE3F2FD),
                          radius: 24,
                          child: Text(
                            _getInitials(sub.name),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1565C0),
                            ),
                          ),
                        ),
                        title: Text(
                          sub.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.phone,
                                  size: 14,
                                  color: Colors.grey[500],
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  sub.phone ?? 'no_phone'.tr,
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                            // v22 item 9: the circuit (جوزة) this subscriber is
                            // linked to (resolved from the batch id→name map).
                            if (ctrl.circuitNames[sub.circuitId] != null)
                              Row(
                                children: [
                                  Icon(
                                    Icons.settings_input_component,
                                    size: 14,
                                    color: Colors.grey[500],
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      ctrl.circuitNames[sub.circuitId]!,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Colors.grey[600],
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // v22 item 2: paid/unpaid dot for the selected
                            // month — green = paid, red = unpaid (derived
                            // status, one query per list load).
                            Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: ctrl.paidIds.contains(sub.id)
                                    ? Colors.green
                                    : Colors.red,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE3F2FD),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                "${sub.amps} A",
                                style: const TextStyle(
                                  color: Color(0xFF1565C0),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        onTap: () {
                          // Audit: reload on return so a payment collected in
                          // the detail screen updates this (esp. Paid/Unpaid) list.
                          Get.to(() => SubscriberDetailScreen(subscriber: sub))
                              ?.then((_) => _reload());
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      )),
    );
  }

  String _getInitials(String name) {
    if (name.isEmpty) return "?";
    List<String> parts = name.trim().split(" ");
    if (parts.length > 1) {
      return "${parts[0][0]}${parts[1][0]}".toUpperCase();
    }
    return name[0].toUpperCase();
  }
}
