import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:generatormanagment/views/widgets/app_form_field.dart';

/// A date input that accepts BOTH manual typing and the calendar picker (R12).
///
/// [monthOnly] true  -> `yyyy-MM`   (normalized to the 1st of the month)
/// [monthOnly] false -> `yyyy-MM-dd`
///
/// Manual text is parsed live; a valid parse fires [onChanged]. The trailing
/// calendar icon opens the native picker. Numeric-style format only (no locale
/// month names) so it works the same in Arabic and English.
class DateField extends StatefulWidget {
  final String label;
  final DateTime initial;
  final bool monthOnly;
  final ValueChanged<DateTime> onChanged;
  final DateTime? firstDate;
  final DateTime? lastDate;

  const DateField({
    super.key,
    required this.label,
    required this.initial,
    required this.onChanged,
    this.monthOnly = false,
    this.firstDate,
    this.lastDate,
  });

  @override
  State<DateField> createState() => _DateFieldState();
}

class _DateFieldState extends State<DateField> {
  late final TextEditingController _ctrl;
  String? _error;

  String get _fmt => widget.monthOnly ? 'yyyy-MM' : 'yyyy-MM-dd';

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: DateFormat(_fmt).format(widget.initial));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Parse `yyyy-MM` (→ 1st of month) or `yyyy-MM-dd`; null if invalid.
  DateTime? _parse(String s) {
    s = s.trim();
    if (s.isEmpty) return null;
    try {
      if (widget.monthOnly) {
        final p = s.split('-');
        if (p.length < 2) return null;
        final y = int.parse(p[0]);
        final m = int.parse(p[1]);
        if (m < 1 || m > 12 || y < 1900) return null;
        return DateTime(y, m, 1);
      }
      return DateFormat('yyyy-MM-dd').parseStrict(s);
    } catch (_) {
      return null;
    }
  }

  void _onChanged(String s) {
    final d = _parse(s);
    if (d != null) {
      if (_error != null) setState(() => _error = null);
      widget.onChanged(d);
    } else {
      setState(() => _error = 'invalid_date'.tr);
    }
  }

  Future<void> _pick() async {
    final now = DateTime.now();
    final init = _parse(_ctrl.text) ?? widget.initial;
    final picked = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: widget.firstDate ?? DateTime(now.year - 10),
      lastDate: widget.lastDate ?? DateTime(now.year + 10),
    );
    if (picked == null) return;
    final d = widget.monthOnly
        ? DateTime(picked.year, picked.month, 1)
        : picked;
    _ctrl.text = DateFormat(_fmt).format(d);
    setState(() => _error = null);
    widget.onChanged(d);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      keyboardType: TextInputType.datetime,
      onChanged: _onChanged,
      decoration: appInputDecoration(
        label: widget.label,
        hint: _fmt,
        icon: Icons.event,
      ).copyWith(
        errorText: _error,
        suffixIcon: IconButton(
          icon: const Icon(Icons.calendar_month, color: kAppBlue),
          tooltip: 'pick_date'.tr,
          onPressed: _pick,
        ),
      ),
    );
  }
}
