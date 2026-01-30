import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/core_controller.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/views/screens/add_subscriber_screen.dart';
import 'package:generatormanagment/views/screens/subscriber_detail_screen.dart';

class SubscribersScreen extends StatefulWidget {
  final String? filter; // 'paid', 'unpaid'
  final String? boardId;
  const SubscribersScreen({super.key, this.filter, this.boardId});

  @override
  State<SubscribersScreen> createState() => _SubscribersScreenState();
}

class _SubscribersScreenState extends State<SubscribersScreen> {
  final CoreController controller = Get.put(CoreController());
  final AuthController auth = Get.find<AuthController>();
  final TextEditingController searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.filter != null) {
        controller.loadFilteredSubscribers(widget.filter!);
      } else if (widget.boardId != null) {
        controller.loadBoardSubscribers(widget.boardId!);
      } else {
        controller.loadSubscribers();
      }
    });
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
          preferredSize: const Size.fromHeight(80),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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
                onChanged: (val) {
                  controller.loadSubscribers(query: val);
                },
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: Obx(
        () => auth.isAdmin
            ? FloatingActionButton.extended(
                onPressed: () => Get.to(
                  () => const AddSubscriberScreen(),
                )?.then((_) => controller.loadSubscribers()),
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
      ),
      body: GetBuilder<CoreController>(
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

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(
              16,
              16,
              16,
              80,
            ), // Padding for FAB
            itemCount: ctrl.subscribers.length,
            separatorBuilder: (c, i) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final sub = ctrl.subscribers[index];
              return Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.blue.withOpacity(0.05),
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
                  subtitle: Row(
                    children: [
                      Icon(Icons.phone, size: 14, color: Colors.grey[500]),
                      const SizedBox(width: 4),
                      Text(
                        sub.phone ?? 'no_phone'.tr,
                        style: TextStyle(color: Colors.grey[600], fontSize: 13),
                      ),
                    ],
                  ),
                  trailing: Container(
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
                  onTap: () {
                    Get.to(() => SubscriberDetailScreen(subscriber: sub));
                  },
                ),
              );
            },
          );
        },
      ),
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
