import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:generatormanagment/controllers/core_controller.dart';
import 'package:generatormanagment/data/models/core_models.dart';

class AddSubscriberScreen extends StatefulWidget {
  final Subscriber? subscriber;
  const AddSubscriberScreen({super.key, this.subscriber});

  @override
  State<AddSubscriberScreen> createState() => _AddSubscriberScreenState();
}

class _AddSubscriberScreenState extends State<AddSubscriberScreen> {
  final CoreController controller = Get.find();
  final _formKey = GlobalKey<FormState>();

  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _ampsCtrl = TextEditingController();

  Board? selectedBoard;
  Circuit? selectedCircuit;

  bool get isEdit => widget.subscriber != null;

  @override
  void initState() {
    super.initState();
    if (isEdit) {
      _nameCtrl.text = widget.subscriber!.name;
      _phoneCtrl.text = widget.subscriber!.phone ?? "";
      _ampsCtrl.text = widget.subscriber!.amps.toString();
    }
    // Ensure boards are loaded
    _initData();
  }

  Future<void> _initData() async {
    await controller.loadBoards();
    if (isEdit) {
      // Find and select the board
      selectedBoard = controller.boards.firstWhereOrNull(
        (b) => b.id == widget.subscriber!.boardId,
      );
      if (selectedBoard != null) {
        await controller.loadCircuits(selectedBoard!.id);
        selectedCircuit = controller.circuits.firstWhereOrNull(
          (c) => c.id == widget.subscriber!.circuitId,
        );
      }
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD), // Light blue background
      appBar: AppBar(
        title: Text(
          isEdit ? "edit_subscriber".tr : "add_subscriber".tr,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        backgroundColor: const Color(0xFF1565C0),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "subscriber_details".tr,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1565C0),
              ),
            ),
            const SizedBox(height: 16),

            // White Card Form
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blue.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    _buildTextField(
                      controller: _nameCtrl,
                      label: "full_name".tr,
                      icon: Icons.person,
                      validator: (v) => v!.isEmpty ? "required".tr : null,
                    ),
                    const SizedBox(height: 20),

                    _buildTextField(
                      controller: _phoneCtrl,
                      label: "${"phone_number".tr} ${"optional".tr}",
                      icon: Icons.phone,
                      keyboardType: TextInputType.phone,
                    ),
                    const SizedBox(height: 20),

                    _buildTextField(
                      controller: _ampsCtrl,
                      label: "amps".tr,
                      icon: Icons.electric_bolt,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      validator: (v) => v!.isEmpty ? "required".tr : null,
                    ),
                    const SizedBox(height: 20),

                    const Divider(height: 32),

                    // Board Dropdown
                    Obx(
                      () => DropdownButtonFormField<Board>(
                        decoration: _inputDecoration(
                          "board_name".tr,
                          Icons.developer_board,
                        ),
                        value: selectedBoard,
                        items: controller.boards
                            .map(
                              (b) => DropdownMenuItem(
                                value: b,
                                child: Text(b.name),
                              ),
                            )
                            .toList(),
                        onChanged: (val) async {
                          setState(() {
                            selectedBoard = val;
                            selectedCircuit = null;
                          });
                          if (val != null) {
                            await controller.loadCircuits(val.id);
                          }
                        },
                        validator: (v) => v == null ? "required".tr : null,
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Circuit Dropdown
                    Obx(
                      () => DropdownButtonFormField<Circuit>(
                        decoration: _inputDecoration(
                          "circuit_jawza".tr,
                          Icons.settings_input_component,
                        ),
                        value: selectedCircuit,
                        items: controller.circuits
                            .map(
                              (c) => DropdownMenuItem(
                                value: c,
                                child: Text(c.name),
                              ),
                            )
                            .toList(),
                        onChanged: (val) {
                          setState(() {
                            selectedCircuit = val;
                          });
                        },
                        validator: (v) => v == null
                            ? (selectedBoard == null
                                  ? "select_board_first".tr
                                  : "required".tr)
                            : null,
                      ),
                    ),

                    const SizedBox(height: 32),

                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1565C0),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          isEdit ? "save_changes".tr : "save_subscriber".tr,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      decoration: _inputDecoration(label, icon),
      validator: validator,
    );
  }

  InputDecoration _inputDecoration(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: const Color(0xFF1565C0)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF1565C0), width: 2),
      ),
      filled: true,
      fillColor: Colors.grey[50],
    );
  }

  void _save() {
    if (_formKey.currentState!.validate()) {
      final amps = double.tryParse(_ampsCtrl.text.trim());
      if (amps == null) {
        Get.snackbar(
          "error".tr,
          "amps_invalid".tr,
          backgroundColor: Colors.red,
          colorText: Colors.white,
        );
        return;
      }
      // Subscribers are shared across all accountants (the owner's common
      // customer base), so accountantId is left null = shared.
      final sub = Subscriber(
        id: isEdit ? widget.subscriber!.id : const Uuid().v4(),
        name: _nameCtrl.text,
        phone: _phoneCtrl.text,
        amps: amps,
        boardId: selectedBoard!.id,
        circuitId: selectedCircuit!.id,
        accountantId: null,
        // Preserve original status/createdAt when editing.
        status: isEdit ? widget.subscriber!.status : 'active',
        createdAt: isEdit ? widget.subscriber!.createdAt : null,
      );

      if (isEdit) {
        controller.updateSubscriber(sub);
      } else {
        controller.addSubscriber(sub);
      }

      Get.back();
      Get.snackbar(
        "success".tr,
        isEdit ? "subscriber_updated".tr : "subscriber_added".tr,
        backgroundColor: Colors.green,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
    }
  }
}
