import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/expense_model.dart';
import 'package:sqflite/sqflite.dart';

class ExpenseRepository {
  final DbHelper _dbHelper = DbHelper();

  Future<void> addExpense(Expense expense) async {
    final db = await _dbHelper.database;
    await db.insert(
      'expenses',
      expense.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Expense>> getExpensesByMonth(
    String monthPrefix, {
    required int limit,
    required int offset,
    String? accountantId,
    String? branchId,
  }) async {
    // monthPrefix expected as 'YYYY-MM'
    final db = await _dbHelper.database;
    final clauses = <String>['date LIKE ?'];
    final args = <dynamic>['$monthPrefix%'];
    if (accountantId != null) {
      clauses.add('accountant_id = ?');
      args.add(accountantId);
    }
    if (branchId != null) {
      clauses.add('branch_id = ?');
      args.add(branchId);
    }
    final res = await db.query(
      'expenses',
      where: clauses.join(' AND '),
      whereArgs: args,
      orderBy: 'date DESC',
      limit: limit,
      offset: offset,
    );
    return res.map((e) => Expense.fromMap(e)).toList();
  }

  Future<double> getTotalExpenses(String monthPrefix,
      {String? accountantId, String? branchId}) async {
    final db = await _dbHelper.database;
    final scopes = <String>[];
    final args = <dynamic>['$monthPrefix%'];
    if (accountantId != null) {
      scopes.add('AND accountant_id = ?');
      args.add(accountantId);
    }
    if (branchId != null) {
      scopes.add('AND branch_id = ?');
      args.add(branchId);
    }
    final res = await db.rawQuery(
      'SELECT SUM(amount) as total FROM expenses WHERE date LIKE ? ${scopes.join(' ')}',
      args,
    );
    if (res.isNotEmpty && res.first['total'] != null) {
      return (res.first['total'] as num).toDouble();
    }
    return 0.0;
  }

  /// Deletes one expense. [accountantId] scopes an accountant to THEIR OWN rows.
  /// v30 T3: [ownerOnly] scopes the admin/owner to OWNER-CREATED rows
  /// (accountant_id null/empty) — the admin may view accountants' expenses but
  /// never delete them (defense-in-depth under the controller's canDelete gate).
  Future<void> deleteExpense(String id,
      {String? accountantId, bool ownerOnly = false}) async {
    final db = await _dbHelper.database;
    String where = 'id = ?';
    final args = <dynamic>[id];
    if (accountantId != null) {
      where += ' AND accountant_id = ?';
      args.add(accountantId);
    }
    if (ownerOnly) {
      where += " AND (accountant_id IS NULL OR accountant_id = '')";
    }
    await db.delete('expenses', where: where, whereArgs: args);
  }
}
