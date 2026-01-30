import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/core_controller.dart';
import 'package:generatormanagment/data/models/core_models.dart';

class CircuitsScreen extends StatefulWidget {
  final Board board;
  const CircuitsScreen({super.key, required this.board});

  @override
  State<CircuitsScreen> createState() => _CircuitsScreenState();
}

class _CircuitsScreenState extends State<CircuitsScreen> {
  final CoreController controller = Get.find();
  final AuthController auth = Get.find();

  @override
  void initState() {
    super.initState();
    controller.loadCircuits(widget.board.id);
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
          return const Center(child: Text("No circuits. Add one!"));

        return ListView.builder(
          itemCount: controller.circuits.length,
          itemBuilder: (context, index) {
            final circuit = controller.circuits[index];
            return ListTile(
              leading: const Icon(Icons.flash_on),
              title: Text(circuit.name),
              subtitle: Text(circuit.phase ?? "Phase ?"),
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

    Get.defaultDialog(
      title: "Add Circuit",
      content: Column(
        children: [
          TextField(
            controller: nameCtrl,
            decoration: const InputDecoration(labelText: "Name"),
          ),
          TextField(
            controller: phaseCtrl,
            decoration: const InputDecoration(labelText: "Phase (optional)"),
          ),
        ],
      ),
      textConfirm: "Add",
      textCancel: "Cancel",
      onConfirm: () {
        if (nameCtrl.text.isNotEmpty) {
          controller.addCircuit(widget.board.id, nameCtrl.text, phaseCtrl.text);
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
