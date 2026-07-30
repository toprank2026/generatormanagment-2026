import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/core/permissions.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/controllers/core_controller.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart'
    show SubscriberRepository, ValidationException;
import 'package:generatormanagment/views/screens/subscriber_detail_screen.dart';
import 'package:generatormanagment/views/widgets/app_form_field.dart';
import 'package:generatormanagment/views/widgets/sync_progress_overlay.dart';

class CircuitsScreen extends StatefulWidget {
  final Board board;
  const CircuitsScreen({super.key, required this.board});

  @override
  State<CircuitsScreen> createState() => _CircuitsScreenState();
}

class _CircuitsScreenState extends State<CircuitsScreen> {
  final CoreController controller = Get.find();
  final AuthController auth = Get.find();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    controller.loadCircuits(widget.board.id);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      controller.loadMoreCircuits();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${'circuits_in'.tr} ${widget.board.name}'),
        backgroundColor: const Color(0xFF1565C0),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      floatingActionButton: Obx(
        () => auth.can(Perm.boards)
            ? FloatingActionButton(
                onPressed: () => _showAddCircuitDialog(context),
                backgroundColor: const Color(0xFF1565C0),
                child: const Icon(Icons.add, color: Colors.white),
              )
            : const SizedBox.shrink(),
      ),
      body: SafeArea(child: Obx(() {
        if (controller.isLoading.value)
          return const Center(child: CircularProgressIndicator());
        if (controller.circuits.isEmpty)
          return Center(child: Text("no_circuits".tr));

        // v21: responsive GRID (mirrors the boards grid). Same data source,
        // ordering, pagination, scroll controller and itemCount as before —
        // only the visual list->grid changed.
        return GridView.builder(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.0,
          ),
          itemCount:
              controller.circuits.length +
              (controller.isCircuitsMoreLoading.value ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == controller.circuits.length) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(8.0),
                  child: CircularProgressIndicator(),
                ),
              );
            }
            final circuit = controller.circuits[index];
            return Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              // v22 item 3: the circuit card was a billing dead end (no onTap).
              // Tapping now opens the subscriber occupying this جوزة — same
              // detail screen + collect flow as the Home and Boards paths.
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => _openCircuitSubscriber(circuit),
                child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(10.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.settings_input_component,
                          size: 34,
                          color: Color(0xFF1565C0),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          circuit.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (circuit.phase != null &&
                            circuit.phase!.isNotEmpty)
                          Text(
                            circuit.phase!,
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 11,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (auth.can(Perm.boards))
                    Positioned(
                      top: 4,
                      right: 4,
                      child: PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert, color: Colors.grey),
                        onSelected: (val) {
                          if (val == 'delete') {
                            _showDeleteConfirm(circuit);
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'delete',
                            child: ListTile(
                              leading: const Icon(
                                Icons.delete,
                                color: Colors.red,
                              ),
                              title: Text('delete'.tr),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                ),
              ),
            );
          },
        );
      })),
    );
  }

  /// v22 item 3: resolve the ACTIVE subscriber on [circuit] and open the shared
  /// detail screen (collect payment included). A vacant circuit gets a hint.
  Future<void> _openCircuitSubscriber(Circuit circuit) async {
    try {
      final subs = await SubscriberRepository().getByCircuit(circuit.id,
          branchId: Get.find<BranchController>().scopeBranchId);
      final Subscriber? active =
          subs.firstWhereOrNull((s) => s.status == 'active') ??
              (subs.isNotEmpty ? subs.first : null);
      if (active == null) {
        Get.snackbar('circuits'.tr, 'circuit_vacant'.tr);
        return;
      }
      await Get.to(() => SubscriberDetailScreen(subscriber: active));
      // Refresh so a collected payment is reflected when the user returns.
      controller.loadCircuits(widget.board.id);
    } catch (e) {
      Get.snackbar('error'.tr, '$e',
          backgroundColor: Colors.redAccent, colorText: Colors.white);
    }
  }

  void _showAddCircuitDialog(BuildContext context) {
    final nameCtrl = TextEditingController();
    final phaseCtrl = TextEditingController();
    // v41 item 2: OPTIONAL bulk mode (a number range) — off by default so the
    // existing single-add flow stays the unchanged default.
    final fromCtrl = TextEditingController();
    final toCtrl = TextEditingController();
    bool bulk = false;

    Get.defaultDialog(
      title: "add_circuit".tr,
      content: StatefulBuilder(
        builder: (context, setDialogState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!bulk)
              AppTextField(
                controller: nameCtrl,
                label: "circuit_name".tr,
                icon: Icons.electrical_services,
              )
            else ...[
              AppTextField(
                controller: fromCtrl,
                label: "bulk_from".tr,
                icon: Icons.first_page,
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 14),
              AppTextField(
                controller: toCtrl,
                label: "bulk_to".tr,
                icon: Icons.last_page,
                keyboardType: TextInputType.number,
              ),
            ],
            const SizedBox(height: 14),
            AppTextField(
              controller: phaseCtrl,
              label: "phase_optional".tr,
              icon: Icons.bolt,
            ),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text("bulk_add_circuits".tr,
                  style: const TextStyle(fontSize: 13)),
              activeThumbColor: const Color(0xFF1565C0),
              value: bulk,
              onChanged: (v) => setDialogState(() => bulk = v),
            ),
          ],
        ),
      ),
      textConfirm: "add".tr,
      textCancel: "cancel".tr,
      // Await the write BEFORE closing so the dialog always closes exactly once
      // and only after the circuit is persisted (R2). Empty name keeps it open.
      onConfirm: () async {
        if (bulk) {
          // v41 item 2: bulk range path (single-add path below is untouched).
          final int? from = int.tryParse(fromCtrl.text.trim());
          final int? to = int.tryParse(toCtrl.text.trim());
          if (from == null || to == null || from < 0 || to < from) {
            Get.snackbar('error'.tr, 'bulk_invalid_range'.tr,
                backgroundColor: Colors.redAccent, colorText: Colors.white);
            return;
          }
          // Overflow-proof cap (review): with from ≥ 0 and to ≥ from the
          // subtraction can't wrap, unlike `to - from + 1` at int64 max.
          if (to - from >= CoreController.bulkRangeMax) {
            Get.snackbar('error'.tr, 'bulk_range_too_large'.tr,
                backgroundColor: Colors.redAccent, colorText: Colors.white);
            return;
          }
          // Error/close ordering mirrors the single-add path: hide the
          // overlay FIRST (finally), snackbars only after; close the dialog
          // via the root navigator — Get.back() while a snackbar is open
          // swallows the pop and strands the dialog (documented gotcha,
          // same workaround as _showDeleteConfirm). Navigator captured
          // BEFORE the awaits (no context across async gaps).
          final nav = Navigator.of(context, rootNavigator: true);
          SyncProgress.show('saving'.tr);
          ({int created, int skipped})? res;
          Object? err;
          try {
            res = await controller.addCircuitsRange(
                widget.board.id, from, to, phaseCtrl.text.trim());
          } catch (e) {
            err = e;
          } finally {
            SyncProgress.hide();
          }
          if (err != null || res == null) {
            Get.snackbar(
                'error'.tr,
                err is ValidationException
                    ? err.messageKey.tr
                    : '${err ?? ''}',
                backgroundColor: Colors.redAccent,
                colorText: Colors.white);
            return;
          }
          nav.pop();
          Get.snackbar(
            "success".tr,
            "${'circuits_added'.tr}: ${res.created}"
            "${res.skipped > 0 ? ' • ${'circuits_skipped'.tr}: ${res.skipped}' : ''}",
            backgroundColor: Colors.green,
            colorText: Colors.white,
          );
          return;
        }
        if (nameCtrl.text.trim().isEmpty) return;
        // v14: loading overlay until saved; hide BEFORE any snackbar.
        SyncProgress.show('saving'.tr);
        ValidationException? verr;
        bool ok = false;
        try {
          await controller.addCircuit(
            widget.board.id,
            nameCtrl.text.trim(),
            phaseCtrl.text.trim(),
          );
          ok = true;
        } on ValidationException catch (e) {
          verr = e; // R1: duplicate feed name — keep the dialog open.
        } finally {
          SyncProgress.hide();
        }
        if (verr != null) {
          Get.snackbar('error'.tr, verr.messageKey.tr,
              backgroundColor: Colors.redAccent, colorText: Colors.white);
          return;
        }
        if (!ok) return;
        Get.back();
        Get.snackbar(
          "success".tr,
          "circuit_added".tr,
          backgroundColor: Colors.green,
          colorText: Colors.white,
        );
      },
    );
  }

  void _showDeleteConfirm(Circuit circuit) {
    Get.defaultDialog(
      title: "delete_circuit_title".tr,
      middleText: "delete_circuit_confirm".tr,
      textConfirm: "delete".tr,
      textCancel: "cancel".tr,
      confirmTextColor: Colors.white,
      buttonColor: Colors.red,
      // v22 item 8: close-FIRST-then-act (a throw stranded the dialog open; a
      // double-tapped confirm over-popped a real route). Raw-navigator pop —
      // Get.back would be swallowed by an open snackbar and leave the dialog up.
      onConfirm: () async {
        Navigator.of(context, rootNavigator: true).pop();
        try {
          // v35 item 5: refused when the circuit's cascade would erase
          // receipts already inside a settlement (would corrupt wallets).
          final ok =
              await controller.deleteCircuit(circuit.id, widget.board.id);
          if (!ok) {
            Get.snackbar('error'.tr, 'delete_blocked_settled'.tr,
                backgroundColor: Colors.orange, colorText: Colors.white);
            return;
          }
        } catch (e) {
          Get.snackbar('error'.tr, '$e',
              backgroundColor: Colors.redAccent, colorText: Colors.white);
          return;
        }
        Get.snackbar(
          "success".tr,
          "circuit_deleted".tr,
          backgroundColor: Colors.red,
          colorText: Colors.white,
        );
      },
    );
  }
}
