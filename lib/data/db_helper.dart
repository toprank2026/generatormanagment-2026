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
      version: 12,
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
    // Settlements (v11) — accountant wallet settlement requests (synced).
    'settlements': 'id',
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
      // During a multi-step upgrade a synced table may not exist yet (it's
      // created in a LATER _onUpgrade branch). _createSyncInfra is re-run after
      // that branch, so skip a missing table now and create its triggers then.
      final tableExists = (await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        [t],
      )).isNotEmpty;
      if (!tableExists) continue;
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
    if (oldVersion < 6) {
      // ---- Enhancements v6 (additive) ----
      // R4: subscriber categories with per-category pricing.
      // 1) subscribers.category — enum 'commercial'|'standard'|'gold'. The
      //    DEFAULT backfills every legacy row to 'standard', so billing is
      //    unchanged on upgrade until the owner sets the other categories' prices.
      await _addColumn(
          db, 'subscribers', 'category', "TEXT DEFAULT 'standard'");
      // 2) monthly_prices is now keyed per CATEGORY too: synthetic id grows from
      //    "<month>|<branchId>" -> "<month>|<branchId>|<category>". Add the column
      //    and append '|standard' to legacy 2-part ids (re-enqueues to sync; the
      //    old 2-part server rows are harmlessly orphaned, push-only mirror).
      await _addColumn(
          db, 'monthly_prices', 'category', "TEXT DEFAULT 'standard'");
      await db.execute(
          "UPDATE monthly_prices SET category = 'standard' WHERE category IS NULL OR category = ''");
      await db.execute(
          "UPDATE monthly_prices SET id = id || '|standard' WHERE id NOT LIKE '%|%|%'");
      // R3 (audit) snapshot: the category in force when a receipt was collected,
      // so historical reports stay correct if a subscriber's category changes.
      await _addColumn(db, 'receipts', 'category_snapshot', 'TEXT');
      // R5/R7: a circuit may belong to at most ONE active subscriber per branch.
      // Resolve legacy duplicates BEFORE the repo guard takes effect: keep the
      // most-recently-inserted active subscriber per (circuit, branch); deactivate
      // the rest (these UPDATEs enqueue so the server mirror deactivates them too).
      await db.execute('''
        UPDATE subscribers SET status = 'inactive'
        WHERE status = 'active' AND rowid NOT IN (
          SELECT MAX(rowid) FROM subscribers
          WHERE status = 'active'
          GROUP BY circuit_id, IFNULL(branch_id, '$kMainBranchId')
        )
      ''');
    }
    if (oldVersion < 7) {
      // ---- v7 (additive): receipt DISCOUNT (P5) ----
      // A discount is applied ONLY on a full payment: the subscriber pays cash
      // (paid_amount) AND a discount_value is WAIVED, and is considered fully
      // paid (coverage = paid_amount + discount_value >= due). Legacy receipts
      // default discount_type 'none'/value 0, so paid/unpaid math is unchanged.
      await _addColumn(db, 'receipts', 'discount_type', "TEXT DEFAULT 'none'");
      await _addColumn(db, 'receipts', 'discount_value', 'REAL DEFAULT 0');
      await _addColumn(db, 'receipts', 'discount_amps', 'REAL');
    }
    if (oldVersion < 8) {
      // v8 (audit/scale): add indexes on the hot scope/join columns.
      await _createV8Indexes(db);
    }
    if (oldVersion < 9) {
      // v9 (audit/conflict-resolution): per-row updated_at edit timestamp.
      await _addUpdatedAtColumns(db);
    }
    if (oldVersion < 10) {
      // v10 (Flash item 5): owner-chosen pricing start DAY within the month
      // (metadata only — billing stays month-based, no proration).
      await _addColumn(db, 'monthly_prices', 'start_date', 'TEXT');
    }
    if (oldVersion < 11) {
      // v11 (Flash): receipt payment method + accountant wallet settlements.
      await _addColumn(db, 'receipts', 'payment_method', "TEXT DEFAULT 'cash'");
      await db.execute('''
        CREATE TABLE IF NOT EXISTS settlements (
          id TEXT PRIMARY KEY,
          accountant_id TEXT,
          branch_id TEXT,
          amount REAL NOT NULL,
          status TEXT DEFAULT 'pending',
          requested_at TEXT,
          decided_at TEXT,
          decided_by TEXT,
          note TEXT,
          created_at TEXT DEFAULT CURRENT_TIMESTAMP,
          updated_at TEXT
        )
      ''');
      // Create the settlements sync triggers (others already exist → skipped).
      await _createSyncInfra(db);
    }
    if (oldVersion < 12) {
      // v12 (Flash): settlements gain a method ('cash'|'card') for the second
      // (credit-card) wallet.
      await _addColumn(db, 'settlements', 'method', "TEXT DEFAULT 'cash'");
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
        category TEXT DEFAULT 'standard', -- 'commercial' | 'standard' | 'gold' (R4)
        accountant_id TEXT,
        branch_id TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (board_id) REFERENCES boards (id),
        FOREIGN KEY (circuit_id) REFERENCES circuits (id)
      )
    ''');

    // 5. Monthly Prices — per branch AND per category (R4): synthetic
    //    id = "<month>|<branchId>|<category>". Each category prices independently.
    await db.execute('''
      CREATE TABLE monthly_prices (
        id TEXT PRIMARY KEY,
        month TEXT NOT NULL, -- Format YYYY-MM
        price_per_amp REAL NOT NULL,
        locked INTEGER DEFAULT 0,
        branch_id TEXT,
        category TEXT DEFAULT 'standard',
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
        category_snapshot TEXT, -- subscriber category at collection time (R4 audit)
        discount_type TEXT DEFAULT 'none', -- 'none'|'ampere'|'value' (P5)
        discount_value REAL DEFAULT 0,     -- IQD waived (P5)
        discount_amps REAL,                -- amps waived (ampere type, audit)
        performed_by_user_id TEXT,
        issued_at TEXT NOT NULL,
        status TEXT DEFAULT 'valid', -- valid, refunded
        qr_token TEXT,
        payment_method TEXT DEFAULT 'cash', -- v11: 'cash' | 'card'
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

    // 9. Settlements (v11): accountant wallet settlement requests. Balance is
    // DERIVED (Σ collected − Σ approved); a settlement records the requested
    // amount, approved/rejected by the owner from the panel.
    await db.execute('''
      CREATE TABLE settlements (
        id TEXT PRIMARY KEY,
        accountant_id TEXT,
        branch_id TEXT,
        amount REAL NOT NULL,
        method TEXT DEFAULT 'cash', -- v12: 'cash' | 'card' (which wallet)
        status TEXT DEFAULT 'pending', -- 'pending' | 'approved' | 'rejected'
        requested_at TEXT,
        decided_at TEXT,
        decided_by TEXT,
        note TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        updated_at TEXT
      )
    ''');

    // Indexes
    await db.execute('CREATE INDEX idx_subscribers_name ON subscribers(name)');
    await db.execute('CREATE INDEX idx_receipts_month ON receipts(month)');
    await db.execute(
      'CREATE INDEX idx_receipts_subscriber ON receipts(subscriber_id)',
    );

    // Sync change-capture (outbox + triggers) — MUST run before the v8 indexes,
    // one of which is on sync_outbox.
    await _createSyncInfra(db);

    await _createV8Indexes(db);
    await _addUpdatedAtColumns(db);
    // v10 (Flash item 5): pricing start-day metadata.
    await _addColumn(db, 'monthly_prices', 'start_date', 'TEXT');
  }

  /// v9 (audit/conflict-resolution): a per-row edit timestamp on each business
  /// table. The model toMap() stamps it on every insert/update (= the edit
  /// time), and SyncService.push sends it as `data.updated_at`; the server then
  /// applies last-EDIT-wins + sticky tombstones. Idempotent (`_addColumn`
  /// swallows "duplicate column"), so it's safe from both _onCreate and
  /// _onUpgrade. Refunds have no in-app write path, but the column is added for
  /// schema consistency.
  Future<void> _addUpdatedAtColumns(Database db) async {
    const tables = [
      'subscribers',
      'boards',
      'circuits',
      'receipts',
      'refunds',
      'expenses',
      'monthly_prices',
    ];
    for (final t in tables) {
      await _addColumn(db, t, 'updated_at', 'TEXT');
    }
  }

  /// v8 (audit/scale): indexes for the hot scope/join columns that previously
  /// caused full table scans on every dashboard/report/paid-unpaid load. All
  /// `IF NOT EXISTS` so they're safe to (re)run from _onCreate AND _onUpgrade.
  Future<void> _createV8Indexes(Database db) async {
    const stmts = [
      'CREATE INDEX IF NOT EXISTS idx_mp_lookup ON monthly_prices(month, branch_id, category)',
      'CREATE INDEX IF NOT EXISTS idx_receipts_branch_month ON receipts(branch_id, month, status)',
      'CREATE INDEX IF NOT EXISTS idx_receipts_sub_month ON receipts(subscriber_id, month, status)',
      'CREATE INDEX IF NOT EXISTS idx_subscribers_branch_cat ON subscribers(branch_id, category)',
      'CREATE INDEX IF NOT EXISTS idx_subscribers_branch_status ON subscribers(branch_id, status, circuit_id)',
      'CREATE INDEX IF NOT EXISTS idx_circuits_board ON circuits(board_id, branch_id)',
      'CREATE INDEX IF NOT EXISTS idx_boards_branch ON boards(branch_id)',
      'CREATE INDEX IF NOT EXISTS idx_expenses_branch_date ON expenses(branch_id, date)',
      'CREATE INDEX IF NOT EXISTS idx_outbox_entity_local ON sync_outbox(entity, local_id, seq)',
    ];
    for (final s in stmts) {
      await db.execute(s);
    }
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }

  /// v12 (item 4): wipe ALL local data — every user table (business rows, the
  /// local `users` credentials, accountants, settlements, the sync outbox, …),
  /// not just the synced business tables. Used by logout so the next account on
  /// this device sees NOTHING of the previous one. The schema is kept (tables
  /// emptied, not dropped). Internal SQLite tables are left alone.
  Future<void> wipeAllTables() async {
    final db = await database;
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata'",
    );
    await db.transaction((txn) async {
      for (final r in rows) {
        await txn.delete(r['name'] as String);
      }
    });
  }

  Future<String> getDbPath() async {
    return testPath ?? await _defaultPath();
  }
}
