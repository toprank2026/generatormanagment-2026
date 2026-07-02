import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';

const Color _kBlue = Color(0xFF1565C0);

/// v20 item 4 — owner/admin self-edit of their account (username, password,
/// name, phone, generator name). Online-only; the backend returns a fresh token
/// so the session survives a password change.
class EditAccountScreen extends StatefulWidget {
  const EditAccountScreen({super.key});

  @override
  State<EditAccountScreen> createState() => _EditAccountScreenState();
}

class _EditAccountScreenState extends State<EditAccountScreen> {
  final AuthController _auth = Get.find();
  late final TextEditingController _name;
  late final TextEditingController _username;
  late final TextEditingController _phone;
  late final TextEditingController _generator;
  final TextEditingController _password = TextEditingController();
  // v23 (§3.2): required only when a NEW password is entered.
  final TextEditingController _currentPassword = TextEditingController();
  bool _saving = false;
  bool _obscure = true;
  bool _obscureCurrent = true;

  @override
  void initState() {
    super.initState();
    final acc = _auth.account.value;
    _name = TextEditingController(text: acc?.name ?? '');
    _username = TextEditingController(text: acc?.username ?? '');
    _phone = TextEditingController(text: acc?.phone ?? '');
    _generator = TextEditingController(text: acc?.generatorName ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _phone.dispose();
    _generator.dispose();
    _password.dispose();
    _currentPassword.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final username = _username.text.trim();
    final name = _name.text.trim();
    if (username.isEmpty || name.isEmpty) {
      Get.snackbar('error'.tr, 'fill_all_fields'.tr,
          snackPosition: SnackPosition.BOTTOM);
      return;
    }
    // v23 (§3.2): a password change requires the CURRENT password.
    // Trim for consistency with the backup + accountant-edit flows.
    final String newPwd = _password.text.trim();
    final bool changingPassword = newPwd.isNotEmpty;
    final String currentPwd = _currentPassword.text.trim();
    if (changingPassword) {
      if (newPwd.length < 4) {
        Get.snackbar('error'.tr, 'password_too_short'.tr,
            snackPosition: SnackPosition.BOTTOM);
        return;
      }
      if (currentPwd.isEmpty) {
        Get.snackbar('error'.tr, 'current_password_required'.tr,
            snackPosition: SnackPosition.BOTTOM);
        return;
      }
      // Fast local reject when an offline owner-hash is available (the backend
      // is the authoritative gate; verifyOwnerPassword returns true if no hash).
      if (!await _auth.verifyOwnerPassword(currentPwd)) {
        Get.snackbar('error'.tr, 'wrong_password'.tr,
            snackPosition: SnackPosition.BOTTOM);
        return;
      }
    }
    setState(() => _saving = true);
    final res = await _auth.updateProfile(
      username: username,
      name: name,
      phone: _phone.text.trim(),
      generatorName: _generator.text.trim(),
      // empty → keep the current password (repo only sends non-empty).
      password: changingPassword ? newPwd : null,
      currentPassword: changingPassword ? currentPwd : null,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (res['success'] == true) {
      Get.back();
      Get.snackbar('success'.tr, 'account_updated'.tr,
          backgroundColor: Colors.green,
          colorText: Colors.white,
          snackPosition: SnackPosition.BOTTOM);
    } else {
      // 409 = username OR phone already taken — surface the backend's specific
      // message (it says which); 401 WRONG_PASSWORD → the current password was
      // wrong (v23 §3.2).
      final code = res['statusCode'];
      final String msg;
      if (res['code'] == 'WRONG_PASSWORD' || code == 401) {
        msg = 'wrong_password'.tr;
      } else if (code == 409) {
        msg = (res['message'] ?? 'username_taken'.tr).toString();
      } else {
        msg = (res['message'] ?? 'error'.tr).toString();
      }
      Get.snackbar('error'.tr, msg,
          backgroundColor: Colors.redAccent,
          colorText: Colors.white,
          snackPosition: SnackPosition.BOTTOM);
    }
  }

  InputDecoration _dec(String label, IconData icon) => InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: _kBlue),
        border:
            OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('edit_account'.tr)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
                controller: _name,
                decoration: _dec('name'.tr, Icons.person_outline)),
            const SizedBox(height: 14),
            TextField(
                controller: _username,
                decoration: _dec('username'.tr, Icons.alternate_email)),
            const SizedBox(height: 14),
            TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: _dec('phone'.tr, Icons.phone_outlined)),
            const SizedBox(height: 14),
            TextField(
                controller: _generator,
                decoration:
                    _dec('generator_name'.tr, Icons.bolt_outlined)),
            const SizedBox(height: 14),
            TextField(
              controller: _password,
              obscureText: _obscure,
              onChanged: (_) => setState(() {}), // toggle current-password field
              decoration: _dec('new_password_optional'.tr, Icons.lock_outline)
                  .copyWith(
                helperText: 'leave_blank_keep_password'.tr,
                suffixIcon: IconButton(
                  icon: Icon(
                      _obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            // v23 (§3.2): current-password field, shown only while changing the
            // password (required to authorize the change).
            if (_password.text.isNotEmpty) ...[
              const SizedBox(height: 14),
              TextField(
                controller: _currentPassword,
                obscureText: _obscureCurrent,
                decoration:
                    _dec('current_password'.tr, Icons.lock_clock_outlined)
                        .copyWith(
                  helperText: 'current_password_required'.tr,
                  suffixIcon: IconButton(
                    icon: Icon(_obscureCurrent
                        ? Icons.visibility
                        : Icons.visibility_off),
                    onPressed: () =>
                        setState(() => _obscureCurrent = !_obscureCurrent),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: _kBlue,
                  minimumSize: const Size.fromHeight(50)),
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save),
              label: Text('save'.tr),
            ),
          ],
        ),
      ),
    );
  }
}
