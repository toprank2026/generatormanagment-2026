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

  /// v21 item 1: which transport to print on — 'bluetooth' (default, unchanged),
  /// 'usb' (direct USB thermal), or v24 'lan' (Ethernet/Wi-Fi TCP). The
  /// Bluetooth and USB paths/settings are untouched by the LAN addition.
  static const String keyPrinterType = 'printer_type';
  static String _printerType = 'bluetooth';
  static String get printerType => _printerType == 'usb'
      ? 'usb'
      : (_printerType == 'lan' ? 'lan' : 'bluetooth');
  static bool get isUsb => _printerType == 'usb';
  static bool get isLan => _printerType == 'lan';

  /// v24: saved LAN/Ethernet printer endpoint (empty ip = none saved).
  static const String keyLanIp = 'printer_lan_ip';
  static const String keyLanPort = 'printer_lan_port';
  static String _lanIp = '';
  static int _lanPort = 9100;
  static String get lanIp => _lanIp;
  static int get lanPort => _lanPort;

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
    final t = prefs.getString(keyPrinterType);
    _printerType = t == 'usb' ? 'usb' : (t == 'lan' ? 'lan' : 'bluetooth');
    _lanIp = prefs.getString(keyLanIp) ?? '';
    _lanPort = prefs.getInt(keyLanPort) ?? 9100;
    // v27 item 7: receipt-section toggles (default ON).
    _sections.clear();
    for (final k in sectionKeys) {
      _sections[k] = prefs.getBool('print_sec_$k') ?? true;
    }
    return _widthMm;
  }

  /// v21/v24: persists the printer transport ('bluetooth' | 'usb' | 'lan').
  static Future<void> setPrinterType(String t) async {
    _printerType = t == 'usb' ? 'usb' : (t == 'lan' ? 'lan' : 'bluetooth');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyPrinterType, _printerType);
  }

  /// v24: persists the discovered LAN printer endpoint.
  static Future<void> setLan(String ip, int port) async {
    _lanIp = ip;
    _lanPort = port;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyLanIp, ip);
    await prefs.setInt(keyLanPort, port);
  }

  /// v24: forgets the saved LAN printer.
  static Future<void> clearLan() async {
    _lanIp = '';
    _lanPort = 9100;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(keyLanIp);
    await prefs.remove(keyLanPort);
  }

  /// v27 item 7: which receipt SECTIONS are printed (applies to Bluetooth, USB
  /// AND LAN equally — they share the renderer). Every section defaults to ON;
  /// a user can hide any of them. Persisted under 'print_sec_<key>'. The keys
  /// match the translation keys (sec_station … sec_footer).
  static const List<String> sectionKeys = [
    'sec_station',
    'sec_receipt_no',
    'sec_date',
    'sec_subscriber',
    'sec_month',
    'sec_board',
    'sec_circuit',
    'sec_amps',
    'sec_price',
    'sec_category',
    'sec_paid',
    'sec_method',
    'sec_discount',
    'sec_remaining',
    'sec_accountant',
    'sec_qr',
    'sec_footer',
  ];
  static final Map<String, bool> _sections = {};

  /// Whether receipt section [key] is enabled (default true).
  static bool showSection(String key) => _sections[key] ?? true;

  /// Persists a section on/off and updates the cache.
  static Future<void> setSection(String key, bool on) async {
    _sections[key] = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('print_sec_$key', on);
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
