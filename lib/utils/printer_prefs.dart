import 'package:pdf/pdf.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Shared, cached accessor for the selected thermal-printer paper width.
///
/// Both print services ([PdfService] and [BluetoothPrintService]) read the
/// width synchronously from the cached value so receipt generation doesn't have
/// to await SharedPreferences each time. The cache is primed on app start
/// ([load]) and refreshed whenever the user changes the setting ([setWidth]).
class PrinterPrefs {
  PrinterPrefs._();

  /// SharedPreferences key holding the paper width in millimetres (58 or 80).
  static const String keyPaperWidth = 'printer_paper_width_mm';

  /// Default width — matches the historical behaviour (~58mm / 380px).
  static const int defaultWidthMm = 58;

  /// Cached paper width in millimetres (58 or 80). Synchronous-friendly.
  static int _widthMm = defaultWidthMm;

  /// v20 item 3: how many COPIES of each receipt to print (1 or 2). Default 2
  /// preserves the prior behaviour (customer copy + keep copy); the user can
  /// switch to a single copy from the printer settings.
  static const String keyCopies = 'printer_copies';
  static int _copies = 2;

  /// Number of copies to print per receipt (clamped to 1 or 2).
  static int get copies => _copies == 1 ? 1 : 2;

  /// The currently selected paper width in millimetres (58 or 80).
  static int get widthMm => _widthMm;

  /// Whether the selected paper is the wider 80mm roll.
  static bool get is80mm => _widthMm == 80;

  /// Pixel width used when rendering receipt images for the thermal printer:
  /// ~384px for a 58mm roll, ~576px for an 80mm roll.
  static double get pixelWidth => is80mm ? 576 : 384;

  /// Page format for the PDF receipt: roll80 for 80mm, roll57 for 58mm.
  static PdfPageFormat get pdfPageFormat =>
      is80mm ? PdfPageFormat.roll80 : PdfPageFormat.roll57;

  /// Loads the persisted width + copies into the cache (call once on app start).
  static Future<int> load() async {
    final prefs = await SharedPreferences.getInstance();
    _widthMm = _normalize(prefs.getInt(keyPaperWidth) ?? defaultWidthMm);
    _copies = (prefs.getInt(keyCopies) ?? 2) == 1 ? 1 : 2;
    return _widthMm;
  }

  /// Persists [mm] (58 or 80) and updates the cache.
  static Future<void> setWidth(int mm) async {
    _widthMm = _normalize(mm);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(keyPaperWidth, _widthMm);
  }

  /// v20 item 3: persists the copies-per-receipt setting (1 or 2).
  static Future<void> setCopies(int n) async {
    _copies = n == 1 ? 1 : 2;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(keyCopies, _copies);
  }

  static int _normalize(int mm) => mm == 80 ? 80 : 58;
}
