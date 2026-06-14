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
  }) async {
    // monthPrefix expected as 'YYYY-MM'
    final db = await _dbHelper.database;
    final where = accountantId == null
        ? 'date LIKE ?'
        : 'date LIKE ? AND accountant_id = ?';
    final args =
        accountantId == null ? ['$monthPrefix%'] : ['$monthPrefix%', accountantId];
    final res = await db.query(
      'expenses',
      where: where,
      whereArgs: args,
      orderBy: 'date DESC',
      limit: limit,
      offset: offset,
    );
    return res.map((e) => Expense.fromMap(e)).toList();
  }

  Future<double> getTotalExpenses(String monthPrefix,
      {String? accountantId}) async {
    final db = await _dbHelper.database;
    final scope = accountantId == null ? '' : 'AND accountant_id = ?';
    final args =
        accountantId == null ? ['$monthPrefix%'] : ['$monthPrefix%', accountantId];
    final res = await db.rawQuery(
      'SELECT SUM(amount) as total FROM expenses WHERE date LIKE ? $scope',
      args,
    );
    if (res.isNotEmpty && res.first['total'] != null) {
      return (res.first['total'] as num).toDouble();
    }
    return 0.0;
  }

  Future<void> deleteExpense(String id, {String? accountantId}) async {
    final db = await _dbHelper.database;
    final where = accountantId == null ? 'id = ?' : 'id = ? AND accountant_id = ?';
    final args = accountantId == null ? [id] : [id, accountantId];
    await db.delete('expenses', where: where, whereArgs: args);
  }
}
