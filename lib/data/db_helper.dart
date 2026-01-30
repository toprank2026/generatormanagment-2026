import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';

class DbHelper {
  static final DbHelper _instance = DbHelper._internal();
  static Database? _database;

  factory DbHelper() {
    return _instance;
  }

  DbHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String path = join(documentsDirectory.path, "moldati.db");
    return await openDatabase(path, version: 1, onCreate: _onCreate);
  }

  Future _onCreate(Database db, int version) async {
    // 1. Users
    await db.execute('''
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        username TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        role TEXT NOT NULL, 
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // 2. Boards
    await db.execute('''
      CREATE TABLE boards (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        code TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // 3. Circuits (Jawza)
    await db.execute('''
      CREATE TABLE circuits (
        id TEXT PRIMARY KEY,
        board_id TEXT NOT NULL,
        name TEXT NOT NULL,
        phase TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (board_id) REFERENCES boards (id) ON DELETE CASCADE
      )
    ''');

    // 4. Subscribers
    await db.execute('''
      CREATE TABLE subscribers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT,
        amps REAL NOT NULL,
        board_id TEXT NOT NULL,
        circuit_id TEXT NOT NULL,
        status TEXT DEFAULT 'active', 
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (board_id) REFERENCES boards (id),
        FOREIGN KEY (circuit_id) REFERENCES circuits (id)
      )
    ''');

    // 5. Monthly Prices
    await db.execute('''
      CREATE TABLE monthly_prices (
        month TEXT PRIMARY KEY, -- Format YYYY-MM
        price_per_amp REAL NOT NULL,
        locked INTEGER DEFAULT 0,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // 6. Receipts
    await db.execute('''
      CREATE TABLE receipts (
        uuid TEXT PRIMARY KEY,
        receipt_no INTEGER NOT NULL,
        subscriber_id TEXT NOT NULL,
        month TEXT NOT NULL,
        amps_snapshot REAL NOT NULL,
        price_snapshot REAL NOT NULL,
        paid_amount REAL NOT NULL,
        remaining_after REAL NOT NULL,
        accountant_id TEXT,
        performed_by_user_id TEXT,
        issued_at TEXT NOT NULL,
        status TEXT DEFAULT 'valid', -- valid, refunded
        qr_token TEXT,
        FOREIGN KEY (subscriber_id) REFERENCES subscribers (id)
      )
    ''');

    // 7. Refunds
    await db.execute('''
      CREATE TABLE refunds (
        uuid TEXT PRIMARY KEY,
        receipt_uuid TEXT NOT NULL,
        amount REAL NOT NULL,
        reason TEXT,
        performed_by_user_id TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (receipt_uuid) REFERENCES receipts (uuid)
      )
    ''');

    // 8. Expenses
    await db.execute('''
      CREATE TABLE expenses (
        id TEXT PRIMARY KEY,
        category TEXT NOT NULL,
        amount REAL NOT NULL,
        note TEXT,
        date TEXT NOT NULL,
        created_by_user_id TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // Indexes
    await db.execute('CREATE INDEX idx_subscribers_name ON subscribers(name)');
    await db.execute('CREATE INDEX idx_receipts_month ON receipts(month)');
    await db.execute(
      'CREATE INDEX idx_receipts_subscriber ON receipts(subscriber_id)',
    );
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }

  Future<String> getDbPath() async {
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    return join(documentsDirectory.path, "moldati.db");
  }
}
