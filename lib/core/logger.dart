import 'package:flutter/foundation.dart';

/// Tiny debug-only logger. Replaces scattered `print(...)` calls.
class Log {
  Log._();

  static void d(Object? message) {
    if (kDebugMode) debugPrint('[D] $message');
  }

  static void w(Object? message) {
    if (kDebugMode) debugPrint('[W] $message');
  }

  static void e(Object? message, [Object? error, StackTrace? stack]) {
    if (kDebugMode) {
      debugPrint('[E] $message ${error ?? ''}');
      if (stack != null) debugPrint(stack.toString());
    }
  }
}
