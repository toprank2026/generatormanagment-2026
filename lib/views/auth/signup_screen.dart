import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/views/root_handler.dart';

/// Creates a backend account. The device fingerprint is attached automatically
/// by [AuthController.register] → AuthRepository (anti-abuse device binding).
class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final AuthController _auth = Get.find();
  bool _loading = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_password.text != _confirm.text) {
      Get.snackbar('error'.tr, 'passwords_no_match'.tr);
      return;
    }
    setState(() => _loading = true);
    final result = await _auth.register(
      name: _name.text.trim(),
      phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
    );
    if (mounted) setState(() => _loading = false);
    if (result['success'] == true) {
      Get.offAll(() => const RootHandler());
    } else {
      Get.snackbar(
        'signup_failed'.tr,
        (result['message'] ?? 'error'.tr).toString(),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.withValues(alpha: 0.1),
        colorText: Colors.red,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF1565C0)),
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.bolt, size: 72, color: Color(0xFF1565C0)),
                  const SizedBox(height: 16),
                  Text(
                    'create_account'.tr,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 32),
                  _field(_name, 'full_name'.tr, Icons.badge,
                      validator: (v) => v!.trim().isEmpty ? 'required'.tr : null),
                  const SizedBox(height: 16),
                  _field(_phone, 'phone'.tr, Icons.phone,
                      keyboardType: TextInputType.phone),
                  const SizedBox(height: 16),
                  _field(_username, 'username'.tr, Icons.person,
                      validator: (v) => v!.trim().isEmpty ? 'required'.tr : null),
                  const SizedBox(height: 16),
                  _field(_password, 'password'.tr, Icons.lock,
                      obscure: true,
                      validator: (v) =>
                          (v ?? '').length < 4 ? 'password_too_short'.tr : null),
                  const SizedBox(height: 16),
                  _field(_confirm, 'confirm_password'.tr, Icons.lock_outline,
                      obscure: true,
                      validator: (v) => v!.isEmpty ? 'required'.tr : null),
                  const SizedBox(height: 28),
                  FilledButton(
                    onPressed: _loading ? null : _submit,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: const Color(0xFF1565C0),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _loading
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : Text('sign_up'.tr,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _loading ? null : () => Get.back(),
                    child: Text('have_account_sign_in'.tr),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String label,
    IconData icon, {
    bool obscure = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: c,
      obscureText: obscure,
      keyboardType: keyboardType,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: const Color(0xFF1565C0)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
      ),
    );
  }
}
