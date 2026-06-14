import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/core_controller.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/accountant_model.dart';
import 'package:generatormanagment/data/repositories/accountant_repository.dart';
import 'package:generatormanagment/views/widgets/app_form_field.dart';

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
        () => auth.isAdmin
            ? FloatingActionButton(
                onPressed: () => _showAddCircuitDialog(context),
                backgroundColor: const Color(0xFF1565C0),
                child: const Icon(Icons.add, color: Colors.white),
              )
            : const SizedBox.shrink(),
      ),
      body: Obx(() {
        if (controller.isLoading.value)
          return const Center(child: CircularProgressIndicator());
        if (controller.circuits.isEmpty)
          return Center(child: Text("no_circuits".tr));

        return ListView.builder(
          controller: _scrollController,
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
            return ListTile(
              leading: const Icon(Icons.flash_on),
              title: Text(circuit.name),
              subtitle: Text(circuit.phase ?? "phase_unknown".tr),
              trailing: Obx(
                () => auth.isAdmin
                    ? IconButton(
                        icon: const Icon(Icons.delete, color: Colors.redAccent),
                        onPressed: () => _showDeleteConfirm(circuit),
                      )
                    : const SizedBox.shrink(),
              ),
            );
          },
        );
      }),
    );
  }

  void _showAddCircuitDialog(BuildContext context) {
    final nameCtrl = TextEditingController();
    final phaseCtrl = TextEditingController();
    // New circuits default to the parent board's accountant (owner-only field).
    String? selectedAccountantId = widget.board.accountantId;

    Get.defaultDialog(
      title: "add_circuit".tr,
      content: StatefulBuilder(
        builder: (context, setLocalState) {
          return Column(
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
              if (auth.isAdmin) ...[
                const SizedBox(height: 14),
                FutureBuilder<List<Accountant>>(
                  future: AccountantRepository().getAll(),
                  builder: (context, snapshot) {
                    final accountants = snapshot.data ?? const <Accountant>[];
                    return DropdownButtonFormField<String?>(
                      initialValue: selectedAccountantId,
                      isExpanded: true,
                      decoration: appInputDecoration(
                        label: "assign_accountant".tr,
                        icon: Icons.person_outline,
                      ),
                      items: [
                        DropdownMenuItem<String?>(
                          value: null,
                          child: Text("unassigned_owner".tr),
                        ),
                        ...accountants.map(
                          (a) => DropdownMenuItem<String?>(
                            value: a.id,
                            child: Text(a.displayName),
                          ),
                        ),
                      ],
                      onChanged: (val) =>
                          setLocalState(() => selectedAccountantId = val),
                    );
                  },
                ),
              ],
            ],
          );
        },
      ),
      textConfirm: "add".tr,
      textCancel: "cancel".tr,
      onConfirm: () {
        if (nameCtrl.text.isNotEmpty) {
          controller.addCircuit(
            widget.board.id,
            nameCtrl.text,
            phaseCtrl.text,
            accountantId: auth.isAdmin
                ? selectedAccountantId
                : widget.board.accountantId,
          );
          Get.back();
          Get.snackbar(
            "success".tr,
            "circuit_added".tr,
            backgroundColor: Colors.green,
            colorText: Colors.white,
          );
        }
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
