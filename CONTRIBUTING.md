# Contributing to Generator Management System

Thank you for your interest in contributing to the Generator Management System! This document provides guidelines and best practices for developers.

## 📋 Table of Contents

- [Code Style](#code-style)
- [Git Workflow](#git-workflow)
- [Adding New Features](#adding-new-features)
- [Testing Guidelines](#testing-guidelines)
- [Database Migrations](#database-migrations)
- [Localization](#localization)
- [Pull Request Process](#pull-request-process)

---

## 🎨 Code Style

### Dart Code Conventions

Follow the official [Dart Style Guide](https://dart.dev/guides/language/effective-dart/style):

- Use `lowerCamelCase` for variables and methods
- Use `UpperCamelCase` for classes and types
- Use `lowercase_with_underscores` for file names
- Always use trailing commas for multi-line function calls

**Example:**
```dart
class SubscriberController extends GetxController {
  var subscribers = <Subscriber>[].obs;
  
  Future<void> loadSubscribers() async {
    // Implementation
  }
}
```

### File Organization

```dart
// 1. Imports (sorted alphabetically)
import 'package:flutter/material.dart';
import 'package:get/get.dart';

// 2. Class declaration with documentation
/// Manages subscriber-related operations
class SubscriberController extends GetxController {
  // 3. Private fields
  final SubscriberRepository _repo = SubscriberRepository();
  
  // 4. Public observable fields
  var subscribers = <Subscriber>[].obs;
  var isLoading = false.obs;
  
  // 5. Lifecycle methods
  @override
  void onReady() {
    super.onReady();
    loadSubscribers();
  }
  
  // 6. Public methods
  Future<void> loadSubscribers() async {
    // Implementation
  }
  
  // 7. Private methods
  void _helperMethod() {
    // Implementation
  }
}
```

---

## 🌿 Git Workflow

### Branch Naming

- `feature/description` - New features
- `bugfix/description` - Bug fixes
- `hotfix/description` - Urgent fixes
- `refactor/description` - Code refactoring
- `docs/description` - Documentation updates

**Examples:**
```bash
feature/add-expense-categories
bugfix/fix-bluetooth-printing
hotfix/auth-crash-fix
```

### Commit Messages

Follow conventional commits format:

```
type(scope): description

[optional body]

[optional footer]
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation
- `style`: Code style changes
- `refactor`: Code refactoring
- `test`: Adding tests
- `chore`: Maintenance tasks

**Examples:**
```
feat(subscribers): add bulk import functionality
fix(bluetooth): resolve Arabic text rendering issue
docs(readme): update API integration guide
refactor(controllers): extract common dashboard refresh logic
```

---

## ✨ Adding New Features

### Step-by-Step Guide

#### 1. Database Schema

If your feature requires new tables, update `db_helper.dart`:

```dart
await db.execute('''
  CREATE TABLE feature_table (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TEXT,
    updated_at TEXT
  )
''');
```

**Important:** Increment the database version number:
```dart
static const int _version = 2; // Increment this
```

#### 2. Data Model

Create your model in `lib/data/models/`:

```dart
class FeatureModel {
  String id;
  String name;
  String? createdAt;
  
  FeatureModel({
    required this.id,
    required this.name,
    this.createdAt,
  });
  
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'created_at': createdAt,
    };
  }
  
  factory FeatureModel.fromMap(Map<String, dynamic> map) {
    return FeatureModel(
      id: map['id'],
      name: map['name'],
      createdAt: map['created_at'],
    );
  }
}
```

#### 3. Repository

Create repository in `lib/data/repositories/`:

```dart
class FeatureRepository {
  final DbHelper _dbHelper = DbHelper();

  Future<List<FeatureModel>> getAll() async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query('feature_table');
    return List.generate(maps.length, (i) => FeatureModel.fromMap(maps[i]));
  }

  Future<void> insert(FeatureModel model) async {
    final db = await _dbHelper.database;
    await db.insert(
      'feature_table',
      model.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> update(FeatureModel model) async {
    final db = await _dbHelper.database;
    await db.update(
      'feature_table',
      model.toMap(),
      where: 'id = ?',
      whereArgs: [model.id],
    );
  }

  Future<void> delete(String id) async {
    final db = await _dbHelper.database;
    await db.delete(
      'feature_table',
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
```

#### 4. Controller

Create controller in `lib/controllers/`:

```dart
import 'package:get/get.dart';
import 'package:generatormanagment/data/models/feature_model.dart';
import 'package:generatormanagment/data/repositories/feature_repository.dart';
import 'package:generatormanagment/controllers/dashboard_controller.dart';

class FeatureController extends GetxController {
  final FeatureRepository _repo = FeatureRepository();
  
  var items = <FeatureModel>[].obs;
  var isLoading = false.obs;
  
  @override
  void onReady() {
    super.onReady();
    loadItems();
  }
  
  Future<void> loadItems() async {
    isLoading.value = true;
    try {
      items.value = await _repo.getAll();
    } catch (e) {
      Get.snackbar('Error', 'Failed to load items: $e');
    } finally {
      isLoading.value = false;
    }
    update();
  }
  
  Future<void> addItem(FeatureModel item) async {
    await _repo.insert(item);
    loadItems();
    _refreshDashboard();
    update();
  }
  
  Future<void> updateItem(FeatureModel item) async {
    await _repo.update(item);
    loadItems();
    _refreshDashboard();
    update();
  }
  
  Future<void> deleteItem(String id) async {
    await _repo.delete(id);
    loadItems();
    _refreshDashboard();
    update();
  }
  
  void _refreshDashboard() {
    if (Get.isRegistered<DashboardController>()) {
      Get.find<DashboardController>().loadStats();
    }
  }
}
```

#### 5. Screen/UI

Create screen in `lib/views/screens/`:

```dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/feature_controller.dart';

class FeatureScreen extends StatelessWidget {
  const FeatureScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final FeatureController controller = Get.put(FeatureController());

    return Scaffold(
      appBar: AppBar(
        title: Text('feature_title'.tr),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddDialog(controller),
        child: const Icon(Icons.add),
      ),
      body: GetBuilder<FeatureController>(
        builder: (ctrl) {
          if (ctrl.isLoading.value) {
            return const Center(child: CircularProgressIndicator());
          }

          if (ctrl.items.isEmpty) {
            return Center(
              child: Text('no_items'.tr),
            );
          }

          return ListView.builder(
            itemCount: ctrl.items.length,
            itemBuilder: (context, index) {
              final item = ctrl.items[index];
              return ListTile(
                title: Text(item.name),
                trailing: IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () => ctrl.deleteItem(item.id),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showAddDialog(FeatureController controller) {
    // Implementation
  }
}
```

#### 6. Translations

Add translations in `lib/utils/translations.dart`:

```dart
// English
'feature_title': 'Feature Name',
'no_items': 'No items found',
'add_item': 'Add Item',

// Arabic
'feature_title': 'اسم الميزة',
'no_items': 'لا توجد عناصر',
'add_item': 'إضافة عنصر',
```

---

## 🧪 Testing Guidelines

### Unit Tests

Create test files in `test/` directory:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:generatormanagment/controllers/feature_controller.dart';

void main() {
  group('FeatureController Tests', () {
    late FeatureController controller;

    setUp(() {
      controller = FeatureController();
    });

    test('Initial state should have empty items', () {
      expect(controller.items.length, 0);
    });

    test('Adding item should update items list', () async {
      // Test implementation
    });
  });
}
```

### Widget Tests

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generatormanagment/views/screens/feature_screen.dart';

void main() {
  testWidgets('FeatureScreen should display title', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: FeatureScreen()),
    );

    expect(find.text('Feature Name'), findsOneWidget);
  });
}
```

---

## 🗄️ Database Migrations

When modifying the database schema:

1. **Increment version** in `db_helper.dart`:
```dart
static const int _version = 3; // New version
```

2. **Add migration logic** in `_onUpgrade`:
```dart
Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
  if (oldVersion < 2) {
    await db.execute('ALTER TABLE users ADD COLUMN email TEXT');
  }
  if (oldVersion < 3) {
    await db.execute('''
      CREATE TABLE new_feature (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL
      )
    ''');
  }
}
```

---

## 🌍 Localization

### Adding a New Language

1. Add locale in `main.dart`:
```dart
locale: const Locale('fr', 'FR'),
fallbackLocale: const Locale('en', 'US'),
translations: Messages(),
```

2. Add translations in `translations.dart`:
```dart
'fr_FR': {
  'app_name': 'Gestion de Générateur',
  'login': 'Connexion',
  // ... more translations
}
```

### Translation Best Practices

- Use descriptive keys: `subscriber_added_successfully` not `msg1`
- Keep strings concise for UI space constraints
- Test with both LTR (English) and RTL (Arabic) languages
- Use placeholders for dynamic content: `'welcome_user': 'Welcome, {name}'`

---

## 🔄 Pull Request Process

1. **Create Feature Branch**
```bash
git checkout -b feature/your-feature-name
```

2. **Make Changes**
- Write clean, documented code
- Follow code style guidelines
- Add tests if applicable

3. **Commit Changes**
```bash
git add .
git commit -m "feat(scope): description"
```

4. **Push Branch**
```bash
git push origin feature/your-feature-name
```

5. **Create Pull Request**
- Provide clear description of changes
- Reference related issues
- Ensure all tests pass
- Request code review

### PR Checklist

- [ ] Code follows project style guidelines
- [ ] Self-review completed
- [ ] Comments added for complex logic
- [ ] Documentation updated
- [ ] No console errors or warnings
- [ ] Translations added for new strings
- [ ] Database migrations handled properly
- [ ] Tested on both Android and iOS (if applicable)

---

## 📝 Code Review Guidelines

### As a Reviewer

- Be constructive and respectful
- Focus on code quality, not coding style preferences
- Test the changes locally if possible
- Check for security vulnerabilities
- Verify translations are complete

### As an Author

- Respond to all comments
- Be open to feedback
- Make requested changes promptly
- Thank reviewers for their time

---

## 🚀 Release Process

1. Update version in `pubspec.yaml`
2. Update CHANGELOG.md
3. Create release branch
4. Perform final testing
5. Merge to main
6. Tag release
7. Build and deploy

---

## ❓ Questions?

If you have questions or need help:

1. Check existing documentation
2. Search closed issues/PRs
3. Ask in project discussions
4. Contact maintainers

---

**Happy Coding! 🎉**
