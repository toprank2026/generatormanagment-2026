import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';

class DbHelper {
  static final DbHelper _instance = DbHelper._internal();
  static Database? _database;

  /// Fixed id of the default branch every organization gets. Using a constant
  /// (not a random UUID) keeps the Main Branch the SAME row across all of an
  /// owner's devices once synced, and lets the v4->v5 migration backfill legacy
  /// rows without generating an id. Multi-Branch is a full-isolation partition:
  /// every business row belongs to exactly one branch (Main by default).
  static const String kMainBranchId = 'main';

  /// When set (tests), the DB opens at this path instead of the app documents
  /// dir — lets host tests point at an ffi in-memory DB without path_provider.
  static String? testPath;

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
    final String path = testPath ?? await _defaultPath();
    return await openDatabase(
      path,
      version: 5,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  // Business tables that are mirrored to the server, with their primary keys.
  // `accountants` is the server-visible accountant IDENTITY (id/username/name,
  // never the password) so the admin panel can list/count/filter accountants
  // and printed invoices resolve the name on any device; credentials stay local
  // in the (un-synced) `users` table.
  static const Map<String, String> syncedTables = {
    'boards': 'id',
    'circuits': 'id',
    'subscribers': 'id',
    // monthly_prices is keyed per branch (synthetic id = "<month>|<branchId>")
    // since v5 so each branch can price independently.
    'monthly_prices': 'id',
    'receipts': 'uuid',
    'refunds': 'uuid',
    'expenses': 'id',
    'accountants': 'id',
    // Branches — server-visible org partitions (synced identity, like accountants).
    'branches': 'id',
  };

  /// Creates the change-capture outbox + AFTER INSERT/UPDATE/DELETE triggers so
  /// every local mutation is recorded for the sync engine — without touching the
  /// repositories. Idempotent (IF NOT EXISTS).
  Future<void> _createSyncInfra(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_outbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        entity TEXT NOT NULL,
        op TEXT NOT NULL,          -- 'upsert' | 'delete'
        local_id TEXT NOT NULL,
        ts TEXT NOT NULL DEFAULT (datetime('now'))
      )
    ''');
    for (final entry in syncedTables.entries) {
      final t = entry.key;
      final pk = entry.value;
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${t}_sync_ai AFTER INSERT ON $t BEGIN
          INSERT INTO sync_outbox(entity, op, local_id) VALUES('$t', 'upsert', NEW.$pk);
        END;
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${t}_sync_au AFTER UPDATE ON $t BEGIN
          INSERT INTO sync_outbox(entity, op, local_id) VALUES('$t', 'upsert', NEW.$pk);
        END;
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${t}_sync_ad AFTER DELETE ON $t BEGIN
          INSERT INTO sync_outbox(entity, op, local_id) VALUES('$t', 'delete', OLD.$pk);
        END;
      ''');
    }
  }

  /// Idempotent ALTER ... ADD COLUMN (mixed installs may already have it).
  Future<void> _addColumn(
      Database db, String table, String column, String type) async {
    try {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
    } catch (_) {
      // Column already present — safe to ignore.
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createSyncInfra(db);
    }
    if (oldVersion < 3) {
      // Per-accountant attribution: every owned business entity gains an
      // accountant_id (the assigned/creating accountant; NULL = owner-owned).
      // receipts.accountant_id already exists; monthly_prices stays owner-global
      // and refunds has no in-app create path, so both are skipped.
      for (final t in ['boards', 'circuits', 'subscribers', 'expenses']) {
        await _addColumn(db, t, 'accountant_id', 'TEXT');
      }
      // Local accountant sub-users gain a display name + active flag.
      await _addColumn(db, 'users', 'name', 'TEXT');
      await _addColumn(db, 'users', 'active', 'INTEGER DEFAULT 1');
      // Server-visible accountant identity (synced; no credentials).
      await db.execute('''
        CREATE TABLE IF NOT EXISTS accountants (
          id TEXT PRIMARY KEY,
          username TEXT,
          name TEXT,
          active INTEGER DEFAULT 1,
          created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
      ''');
      // Create the accountants sync triggers (others already exist → skipped).
      await _createSyncInfra(db);
    }
    if (oldVersion < 4) {
      // Per-accountant permissions (comma-separated keys; empty = collect+print
      // only). Stored on the local credential row AND the synced identity.
      await _addColumn(db, 'users', 'permissions', 'TEXT');
      await _addColumn(db, 'accountants', 'permissions', 'TEXT');
    }
    if (oldVersion < 5) {
      // ---- Multi-Branch (full isolation, additive) ----
      const main = kMainBranchId;
      // 1) Branch identity table (synced, like accountants — no credentials).
      await db.execute('''
        CREATE TABLE IF NOT EXISTS branches (
          id TEXT PRIMARY KEY,
          name TEXT,
          code TEXT,
          is_main INTEGER DEFAULT 0,
          active INTEGER DEFAULT 1,
          created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
      ''');
      // 2) branch_id on every per-branch business table (mirror of accountant_id).
      for (final t in [
        'boards',
        'circuits',
        'subscribers',
        'receipts',
        'refunds',
        'expenses',
      ]) {
        await _addColumn(db, t, 'branch_id', 'TEXT');
      }
      // 3) Reshape monthly_prices for per-branch pricing: month-PK -> synthetic
      //    id "<month>|<branchId>" + branch_id column. Only if not already done.
      final mpCols = await db.rawQuery('PRAGMA table_info(monthly_prices)');
      final mpHasBranch = mpCols.any((c) => c['name'] == 'branch_id');
      if (!mpHasBranch) {
        await db.execute('DROP TRIGGER IF EXISTS monthly_prices_sync_ai');
        await db.execute('DROP TRIGGER IF EXISTS monthly_prices_sync_au');
        await db.execute('DROP TRIGGER IF EXISTS monthly_prices_sync_ad');
        await db.execute('ALTER TABLE monthly_prices RENAME TO monthly_prices_old');
        await db.execute('''
          CREATE TABLE monthly_prices (
            id TEXT PRIMARY KEY,
            month TEXT NOT NULL,
            price_per_amp REAL NOT NULL,
            locked INTEGER DEFAULT 0,
            branch_id TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
          )
        ''');
        // (data copied after triggers exist, below, so the new rows enqueue.)
      }
      // 4) Recreate sync infra so the `branches` + reshaped `monthly_prices`
      //    triggers exist (others are IF NOT EXISTS → skipped).
      await _createSyncInfra(db);
      // 5) Copy old prices into the new shape (now the trigger enqueues them).
      if (!mpHasBranch) {
        await db.execute(
          "INSERT INTO monthly_prices(id, month, price_per_amp, locked, branch_id, created_at) "
          "SELECT month || '|' || '$main', month, price_per_amp, locked, '$main', created_at FROM monthly_prices_old",
        );
        await db.execute('DROP TABLE monthly_prices_old');
      }
      // 6) Map all legacy rows into the Main Branch (full isolation: every row
      //    belongs to a branch). These UPDATEs enqueue to sync_outbox so the
      //    branch_id propagates to the server mirror on the next sync.
      for (final t in [
        'boards',
        'circuits',
        'subscribers',
        'receipts',
        'refunds',
        'expenses',
      ]) {
        await db.execute("UPDATE $t SET branch_id = '$main' WHERE branch_id IS NULL");
      }
      // The Main Branch row itself is seeded idempotently by BranchRepository
      // (.ensureMain), called on launch by the branch-context layer.
    }
  }

  Future<String> _defaultPath() async {
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    return join(documentsDirectory.path, "moldati.db");
  }

  /// Closes + clears the cached connection (used between tests).
  static Future<void> resetForTest() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }

  Future _onCreate(Database db, int version) async {
    // 1. Users (local credentials for the owner-created accountant sub-users;
    //    NOT synced — `name` is the printed/display name, `active` enables login)
    await db.execute('''
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        username TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        role TEXT NOT NULL,
        name TEXT,
        active INTEGER DEFAULT 1,
        permissions TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // 1b. Accountants — server-visible identity (synced; no credentials).
    await db.execute('''
      CREATE TABLE accountants (
        id TEXT PRIMARY KEY,
        username TEXT,
        name TEXT,
        active INTEGER DEFAULT 1,
        permissions TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // 1c. Branches — org partitions (synced identity). Every business row below
    //     carries a branch_id; full-isolation, branch is the active context.
    await db.execute('''
      CREATE TABLE branches (
        id TEXT PRIMARY KEY,
        name TEXT,
        code TEXT,
        is_main INTEGER DEFAULT 0,
        active INTEGER DEFAULT 1,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // 2. Boards
    await db.execute('''
      CREATE TABLE boards (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        code TEXT,
        accountant_id TEXT,
        branch_id TEXT,
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
        accountant_id TEXT,
        branch_id TEXT,
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
        accountant_id TEXT,
        branch_id TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (board_id) REFERENCES boards (id),
        FOREIGN KEY (circuit_id) REFERENCES circuits (id)
      )
    ''');

    // 5. Monthly Prices — per branch (synthetic id = "<month>|<branchId>").
    await db.execute('''
      CREATE TABLE monthly_prices (
        id TEXT PRIMARY KEY,
        month TEXT NOT NULL, -- Format YYYY-MM
        price_per_amp REAL NOT NULL,
        locked INTEGER DEFAULT 0,
        branch_id TEXT,
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
        branch_id TEXT,
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
        branch_id TEXT,
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
        accountant_id TEXT,
        branch_id TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // Indexes
    await db.execute('CREATE INDEX idx_subscribers_name ON subscribers(name)');
    await db.execute('CREATE INDEX idx_receipts_month ON receipts(month)');
    await db.execute(
      'CREATE INDEX idx_receipts_subscriber ON receipts(subscriber_id)',
    );

    // Sync change-capture (outbox + triggers).
    await _createSyncInfra(db);
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }

  Future<String> getDbPath() async {
    return testPath ?? await _defaultPath();
  }
}
