import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:generatormanagment/core/api_client.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/data/repositories/auth_repository.dart';
import 'package:generatormanagment/utils/date_fmt.dart';

/// v42 item 4: forgot-password for a locked-out generator owner/admin.
///
/// Two steps in ONE screen, because there is nothing to sign in with yet:
///  1. identity (username + the account's REGISTERED phone) + the new password;
///  2. a pending card holding the 6-digit verification code the owner quotes to
///     the super admin, plus a *check status* button.
///
/// The password is never changed here — the request is parked server-side and
/// only a super admin approval in the control panel applies it. The pending
/// reference is persisted (SharedPreferences, same store/JSON style as
/// SessionCache) so the owner can close the app while waiting and come back to
/// the code. Online-only: both calls hit the backend.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  /// The parked request `{requestId, code, createdAt}`. Removed the moment the
  /// flow ends (approved / rejected / expired) so a stale reference can never
  /// strand the owner on step 2.
  static const String _kPendingReset = 'fp_pending_reset';

  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final AuthRepository _repo = AuthRepository();

  bool _loading = false;

  // Step-2 state. [_requestId] != null IS "we are on the pending step".
  String? _requestId;
  String _code = '';
  DateTime? _requestedAt;

  /// Last known status: null (nothing filed yet) | pending | approved |
  /// rejected | expired. Drives the banner; a terminal status also decides
  /// which buttons the pending card offers.
  String? _status;

  @override
  void initState() {
    super.initState();
    _restorePending();
  }

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  // --- persistence -----------------------------------------------------------

  Future<void> _restorePending() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kPendingReset);
    if (raw == null || raw.isEmpty) return;
    try {
      final m = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final id = (m['requestId'] ?? '').toString();
      if (id.isEmpty) return;
      if (!mounted) return;
      setState(() {
        _requestId = id;
        _code = (m['code'] ?? '').toString();
        _requestedAt = DateTime.tryParse((m['createdAt'] ?? '').toString());
        _status = 'pending';
      });
    } catch (_) {
      // Corrupt entry: drop it instead of trapping the owner on the pending
      // step with a reference the server cannot resolve.
      await p.remove(_kPendingReset);
    }
  }

  /// Takes the values rather than reading the fields so the write happens
  /// BEFORE the `mounted` guard — a request that reached the server is parked
  /// even if the owner leaves the screen the instant it returns.
  Future<void> _savePending(String requestId, String code, DateTime at) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kPendingReset,
      jsonEncode({
        'requestId': requestId,
        'code': code,
        'createdAt': at.toIso8601String(),
      }),
    );
  }

  Future<void> _clearPending() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kPendingReset);
  }

  // --- actions ---------------------------------------------------------------

  Future<void> _submit() async {
    if (_loading) return; // busy latch: no double-submit
    if (!_formKey.currentState!.validate()) return;
    if (!await ConnectivityService().isOnline()) {
      _snack('error'.tr, 'fp_online_required'.tr, Colors.red);
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await _repo.requestPasswordReset(
        phone: _phone.text.trim(),
        newPassword: _password.text,
      );
      // The contract returns no createdAt — stamp it locally, it is only ever
      // displayed ("requested at") and persisted for the owner's own reference.
      final at = DateTime.now();
      await _savePending(res.requestId, res.code, at);
      if (!mounted) return;
      setState(() {
        _requestId = res.requestId;
        _code = res.code;
        _requestedAt = at;
        _status = res.status.isEmpty ? 'pending' : res.status;
        _loading = false;
      });
      // The plaintext password lives only in this request payload — clear the
      // fields now that it has been sent.
      _password.clear();
      _confirm.clear();
      _snack('fp_title'.tr, 'fp_request_sent'.tr, Colors.green);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      // Only the backend's OWN 'ACCOUNT_NOT_FOUND' means the username + phone
      // did not match. A bare 404 with no code is the server's route-not-found
      // handler — i.e. this build is talking to a backend that does not have the
      // endpoint deployed yet. Reporting that as "your details are wrong" sends
      // the owner off checking credentials that were never the problem, so the
      // two are surfaced differently.
      final String message;
      if (e.code == 'ACCOUNT_NOT_FOUND') {
        message = 'fp_account_not_found'.tr;
      } else if (e.statusCode == 404) {
        message = 'fp_unavailable'.tr;
      } else if (e.isNetworkError) {
        message = 'fp_online_required'.tr;
      } else {
        message = e.message;
      }
      _snack('error'.tr, message, Colors.red);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('error'.tr, '$e', Colors.red);
    }
  }

  Future<void> _checkStatus() async {
    if (_loading || _requestId == null) return;
    if (!await ConnectivityService().isOnline()) {
      _snack('error'.tr, 'fp_online_required'.tr, Colors.red);
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await _repo.passwordResetStatus(
        requestId: _requestId!,
        code: _code,
      );
      final status = res.status;
      // Only a KNOWN terminal status ends the flow and drops the parked
      // reference (an unrecognised one must never lose it): approved keeps the
      // card — with "sign in with your new password" — while rejected/expired
      // drops back to the form so the owner can file a fresh request at once.
      final over = status == 'approved' ||
          status == 'rejected' ||
          status == 'expired';
      if (over) await _clearPending();
      if (!mounted) return;
      setState(() {
        _status = status;
        if (over && status != 'approved') _requestId = null;
        _loading = false;
      });
      _snack(
        'fp_title'.tr,
        _statusText(status),
        status == 'approved'
            ? Colors.green
            : (status == 'pending' ? Colors.orange : Colors.red),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('error'.tr, e.isNetworkError ? 'fp_online_required'.tr : e.message,
          Colors.red);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('error'.tr, '$e', Colors.red);
    }
  }

  void _snack(String title, String message, MaterialColor color) {
    Get.snackbar(
      title,
      message,
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: color.withValues(alpha: 0.1),
      colorText: color,
    );
  }

  String _statusText(String status) {
    switch (status) {
      case 'approved':
        return 'fp_status_approved'.tr;
      case 'rejected':
        return 'fp_status_rejected'.tr;
      case 'expired':
        return 'fp_status_expired'.tr;
      default:
        return 'fp_status_pending'.tr;
    }
  }

  // --- build -----------------------------------------------------------------

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
            // Step 1 while nothing is parked; step 2 once a request exists.
            child: _requestId == null ? _buildForm() : _buildPending(),
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Image.asset('images/blue.png', height: 88),
          const SizedBox(height: 16),
          Text(
            'fp_title'.tr,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Text(
            'fp_intro'.tr,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
          // Why the previous attempt ended (rejected / expired) — kept visible
          // above the form the owner re-files with.
          if (_status == 'rejected' || _status == 'expired') ...[
            const SizedBox(height: 20),
            _banner(_statusText(_status!), Colors.red, Icons.error_outline),
          ],
          const SizedBox(height: 28),
          // v42 follow-up: PHONE ONLY — the username field was removed. A
          // locked-out owner should have exactly one thing to get right, and the
          // super admin still verifies them by the code before approving.
          _field(_phone, 'fp_phone'.tr, Icons.phone,
              keyboardType: TextInputType.phone,
              validator: (v) => v!.trim().isEmpty ? 'required'.tr : null),
          const SizedBox(height: 16),
          _field(_password, 'fp_new_password'.tr, Icons.lock,
              obscure: true,
              validator: (v) =>
                  (v ?? '').length < 4 ? 'fp_password_too_short'.tr : null),
          const SizedBox(height: 16),
          _field(_confirm, 'fp_confirm_password'.tr, Icons.lock_outline,
              obscure: true,
              validator: (v) =>
                  (v ?? '') != _password.text ? 'fp_passwords_mismatch'.tr : null),
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
                : Text('fp_submit'.tr,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _loading ? null : () => Get.back(),
            child: Text('fp_back_to_login'.tr),
          ),
        ],
      ),
    );
  }

  Widget _buildPending() {
    final approved = _status == 'approved';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          approved ? Icons.check_circle_outline : Icons.hourglass_top,
          size: 64,
          color: approved ? Colors.green : Colors.orange,
        ),
        const SizedBox(height: 16),
        Text(
          'fp_pending_title'.tr,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Text(
          'fp_pending_body'.tr,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: Colors.grey),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          decoration: BoxDecoration(
            color: Colors.grey[50],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Column(
            children: [
              Text(
                'fp_verification_code'.tr,
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              // Selectable so the owner can copy it out to the administrator;
              // forced LTR so the digits stay in order under the Arabic locale.
              SelectableText(
                _code,
                textAlign: TextAlign.center,
                textDirection: TextDirection.ltr,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 6,
                  fontFamily: 'monospace',
                  color: Color(0xFF1565C0),
                ),
              ),
              if (_requestedAt != null) ...[
                const SizedBox(height: 12),
                Text(
                  '${'fp_requested_at'.tr}: ${fmtDateTime12(_requestedAt!.toLocal())}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ],
          ),
        ),
        if (_status != null) ...[
          const SizedBox(height: 20),
          _banner(
            _statusText(_status!),
            approved ? Colors.green : Colors.orange,
            approved ? Icons.verified_outlined : Icons.schedule,
          ),
        ],
        const SizedBox(height: 28),
        // Once approved the password is already changed server-side, so there is
        // nothing left to poll — only the way back to sign in.
        if (!approved) ...[
          FilledButton(
            onPressed: _loading ? null : _checkStatus,
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
                : Text('fp_check_status'.tr,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _loading ? null : () => Get.back(),
            child: Text('fp_back_to_login'.tr),
          ),
        ] else
          FilledButton(
            onPressed: () => Get.back(),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: Colors.green.shade700,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text('fp_back_to_login'.tr,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
          ),
      ],
    );
  }

  /// The status strip — same shape as the login screen's "session ended" card.
  Widget _banner(String text, MaterialColor color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.shade300),
      ),
      child: Row(
        children: [
          Icon(icon, color: color.shade800),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: color.shade900),
            ),
          ),
        ],
      ),
    );
  }

  /// Identical to the signup screen's field builder (same rounded/filled look).
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
