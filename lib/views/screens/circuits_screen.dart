import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/core/permissions.dart';
import 'package:generatormanagment/controllers/core_controller.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart'
    show ValidationException;
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
            );
          },
        );
      })),
    );
  }

  void _showAddCircuitDialog(BuildContext context) {
    final nameCtrl = TextEditingController();
    final phaseCtrl = TextEditingController();

    Get.defaultDialog(
      title: "add_circuit".tr,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppTextField(
            controller: nameCtrl,
            label: "circuit_name".tr,
            icon: Icons.electrical_services,
          ),
          const SizedBox(height: 14),
          AppTextField(
            controller: phaseCtrl,
            label: "phase_optional".tr,
            icon: Icons.bolt,
          ),
        ],
      ),
      textConfirm: "add".tr,
      textCancel: "cancel".tr,
      // Await the write BEFORE closing so the dialog always closes exactly once
      // and only after the circuit is persisted (R2). Empty name keeps it open.
      onConfirm: () async {
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
      onConfirm: () async {
        await controller.deleteCircuit(circuit.id, widget.board.id);
        Get.back();
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
