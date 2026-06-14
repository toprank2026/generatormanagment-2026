import 'package:flutter/material.dart';

/// The app's canonical brand blue (used across forms/buttons/app bars).
const Color kAppBlue = Color(0xFF1565C0);

/// App-wide form-field decoration matching the login / add-subscriber style:
/// a rounded (12) outline, grey-50 fill, a blue 2px focus border and an
/// optional leading brand-blue icon. Use this for every TextField /
/// TextFormField / DropdownButtonFormField so new screens look native.
InputDecoration appInputDecoration({
  required String label,
  String? hint,
  IconData? icon,
}) {
  return InputDecoration(
    labelText: label,
    hintText: hint,
    prefixIcon: icon == null ? null : Icon(icon, color: kAppBlue),
    filled: true,
    fillColor: Colors.grey[50],
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: Colors.grey.shade300),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: kAppBlue, width: 2),
    ),
  );
}

/// A text field pre-wired with [appInputDecoration] — the app's standard input.
class AppTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final IconData? icon;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  const AppTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.icon,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      decoration: appInputDecoration(label: label, hint: hint, icon: icon),
    );
  }
}
