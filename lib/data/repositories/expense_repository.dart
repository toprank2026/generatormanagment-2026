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

  Future<List<Expense>> getExpensesByMonth(String monthPrefix) async {
    // monthPrefix expected as 'YYYY-MM'
    final db = await _dbHelper.database;
    final res = await db.query(
      'expenses',
      where: 'date LIKE ?',
      whereArgs: ['$monthPrefix%'],
      orderBy: 'date DESC',
    );
    return res.map((e) => Expense.fromMap(e)).toList();
  }

  Future<double> getTotalExpenses(String monthPrefix) async {
    final db = await _dbHelper.database;
    final res = await db.rawQuery(
      'SELECT SUM(amount) as total FROM expenses WHERE date LIKE ?',
      ['$monthPrefix%'],
    );
    if (res.isNotEmpty && res.first['total'] != null) {
      return (res.first['total'] as num).toDouble();
    }
    return 0.0;
  }

  Future<void> deleteExpense(String id) async {
    final db = await _dbHelper.database;
    await db.delete('expenses', where: 'id = ?', whereArgs: [id]);
  }
}
