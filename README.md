# Generator Management System (Moldati)

A comprehensive Flutter application for managing generator subscribers, billing, circuits, and boards with Bluetooth thermal printing support.

## 📱 Features

- **User Management**: Admin and accountant roles with permission-based access
- **Subscriber Management**: Complete CRUD operations for subscribers
- **Board & Circuit Management**: Organize subscribers by electrical boards and circuits
- **Billing & Payments**: Monthly pricing, payment collection, and receipt generation
- **Bluetooth Printing**: Direct thermal printer support with Arabic text rendering
- **Dashboard Analytics**: Real-time statistics and insights
- **Bilingual**: Full Arabic and English support
- **Data Management**: Backup and restore functionality
- **Offline-First**: Local SQLite database with optional cloud sync capability

---

## 🏗️ Architecture

### Project Structure

```
lib/
├── controllers/           # GetX Controllers (Business Logic)
│   ├── auth_controller.dart
│   ├── billing_controller.dart
│   ├── core_controller.dart
│   ├── dashboard_controller.dart
│   ├── expense_controller.dart
│   └── settings_controller.dart
│
├── data/                  # Data Layer
│   ├── models/           # Data Models
│   │   ├── billing_models.dart
│   │   ├── core_models.dart
│   │   ├── expense_model.dart
│   │   └── user_model.dart
│   ├── repositories/     # Data Access Layer
│   │   ├── billing_repositories.dart
│   │   ├── core_repositories.dart
│   │   ├── expense_repository.dart
│   │   └── user_repository.dart
│   └── db_helper.dart    # SQLite Database Helper
│
├── views/                # UI Layer
│   ├── screens/          # Application Screens
│   └── widgets/          # Reusable Widgets
│
├── utils/                # Utilities
│   ├── bluetooth_print_service.dart
│   ├── pdf_service.dart
│   └── translations.dart
│
└── main.dart             # Application Entry Point
```

### Design Patterns

- **MVC with GetX**: Model-View-Controller pattern using GetX state management
- **Repository Pattern**: Data access abstraction layer
- **Reactive Programming**: GetBuilder and Obx for reactive UI updates
- **Dependency Injection**: GetX dependency injection for controllers

---

## 🚀 Getting Started

### Prerequisites

- Flutter SDK (3.0 or higher)
- Dart SDK (3.0 or higher)
- Android Studio / VS Code
- Android device or emulator for testing

### Installation

1. **Clone the repository**
```bash
git clone <repository-url>
cd generatormanagment
```

2. **Install dependencies**
```bash
flutter pub get
```

3. **Run the app**
```bash
flutter run
```

### First Time Setup

1. On first launch, you'll be prompted to create an admin account
2. Enter a username and password
3. You'll be logged in automatically and can start using the app

---

## 📖 User Guide

### Login & Authentication

- **First Launch**: Create admin account
- **Subsequent Logins**: Use your credentials
- **Roles**: Admin (full access) or Accountant (limited access)

### Managing Subscribers

1. Navigate to Subscribers screen from Dashboard
2. Tap the "+" button (Admin only)
3. Fill in subscriber details:
   - Name, Phone, Amps
   - Select Board and Circuit
4. Save the subscriber

### Monthly Billing Cycle & Payment Collection

#### Understanding the Monthly Billing System

The app uses a **monthly billing cycle** where each subscriber is charged based on their electricity usage (amps) multiplied by the monthly price per amp.

**How it works:**
1. **Set Monthly Price**: Admin sets the price per amp for each month (e.g., January 2024: 5000 IQD/amp)
2. **Automatic Calculation**: The system calculates each subscriber's monthly bill:
   - `Monthly Bill = Subscriber's Amps × Price per Amp`
   - Example: 10 amps × 5000 IQD = 50,000 IQD per month
3. **Payment Tracking**: Track who has paid and who hasn't for each month
4. **Receipt Generation**: Print receipts for each payment collected

#### Setting Monthly Prices (Admin Only)

**Every month, you need to set the electricity price:**

1. Go to **Payments** tab in the bottom navigation
2. Select the current month (e.g., January 2024)
3. Tap **Set Price** button
4. Enter the price per amp for this month
5. Tap **Save**

> **📌 Important**: Set the price at the beginning of each month before collecting payments!

**Example:**
- January 2024: 5,000 IQD per amp
- February 2024: 5,500 IQD per amp (price can change monthly)

#### Collecting Payments from Subscribers

**Monthly Collection Process:**

1. **Navigate to Subscriber**:
   - Go to Dashboard → Tap "Unpaid Subscribers" card
   - OR go to Subscribers list → Filter by unpaid
   - OR search for specific subscriber

2. **Open Subscriber Details**:
   - Tap on the subscriber's name
   - You'll see their billing information

3. **Select Billing Month**:
   - Choose the month you're collecting for (e.g., January 2024)
   - System shows the calculated amount due

4. **Collect Payment**:
   - Tap **"COLLECT NOW"** button
   - Enter the payment amount (pre-filled with due amount)
   - Tap **"CONFIRM & PRINT"**

5. **Receipt Printing** (Optional):
   - If Bluetooth printer is configured, receipt prints automatically
   - Receipt includes:
     - Business name
     - Subscriber details
     - Amount paid
     - Date and time
     - Accountant name
     - Board and circuit information
     - QR code for verification

#### What Happens Every Month?

**Month-by-Month Workflow:**

**🗓️ Start of Each Month (Day 1-5):**
1. Admin sets the new monthly price per amp
2. Dashboard shows all subscribers as "unpaid" for new month
3. Total fees show expected revenue for the month

**💰 During the Month (Day 1-30):**
1. **Collect payments** from subscribers as they come to pay
2. **Track progress** on Dashboard:
   - Collected Revenue (increases with each payment)
   - Remaining Fees (decreases with each payment)
   - Paid Subscribers count (increases)
   - Unpaid Subscribers count (decreases)
3. **Print receipts** for each payment
4. **Monitor unpaid subscribers** for follow-up

**📊 End of Month (Day 25-30):**
1. Review Dashboard statistics
2. Follow up with unpaid subscribers
3. Generate reports (export data for records)
4. Prepare for next month's billing

**🔄 Next Month:**
- Previous month's payments are locked
- New billing cycle starts
- Set new price and repeat the process

#### Payment Status Indicators

**Dashboard Cards:**
- 🟢 **Paid Subscribers**: Completed payment for selected month
- 🔴 **Unpaid Subscribers**: Not yet paid for selected month
- 💵 **Collected Revenue**: Total money received this month
- 📊 **Remaining Fees**: Money still owed by unpaid subscribers

**In Subscriber Details:**
- ✅ **"Paid Full"**: No amount due for this month
- ⚠️ **Amount Due**: Shows exact amount owed
- 🧾 **Payment History**: Shows all previous receipts

#### Example Monthly Workflow

**Scenario**: You manage 50 subscribers, average 10 amps each

**Day 1 (January 1st):**
- Set price: 5,000 IQD per amp
- Expected revenue: 50 subscribers × 10 amps × 5,000 = 2,500,000 IQD
- Dashboard shows: 0 paid, 50 unpaid

**Day 10:**
- Collected from 20 subscribers
- Dashboard shows: 20 paid, 30 unpaid
- Collected: 1,000,000 IQD
- Remaining: 1,500,000 IQD

**Day 20:**
- Collected from 15 more subscribers
- Dashboard shows: 35 paid, 15 unpaid
- Collected: 1,750,000 IQD
- Remaining: 750,000 IQD

**Day 30:**
- Collected from remaining 15 subscribers
- Dashboard shows: 50 paid, 0 unpaid
- Collected: 2,500,000 IQD ✅
- Month complete!

**February 1st:**
- New month begins
- Set new price (may be same or different)
- All subscribers reset to "unpaid" for February
- Repeat the process

#### Tips for Efficient Monthly Collection

1. **Set Reminder**: Set price on the 1st of every month
2. **Use Filters**: Use Dashboard cards to quickly find unpaid subscribers
3. **Print Receipts**: Always print receipts for record-keeping
4. **Regular Follow-up**: Contact unpaid subscribers mid-month
5. **Export Data**: Backup data at month-end for accounting
6. **Track Trends**: Monitor which subscribers pay early vs late

### Bluetooth Printing Setup

1. Go to Settings
2. Scroll to "Printer Settings"
3. Tap to scan for paired Bluetooth devices
4. Select your thermal printer
5. Configure Business Name for receipts

### Data Backup & Restore

**Export Data:**
1. Settings → Backup Data (Export)
2. Select destination folder
3. Backup file saved with timestamp

**Import Data:**
1. Settings → Restore Data (Import)
2. Select backup file from Documents folder
3. Confirm restore (WARNING: overwrites current data)

---

## 👨‍💻 Developer Guide

### Adding a New Feature

#### 1. Create the Data Model

**Location**: `lib/data/models/`

```dart
class YourModel {
  String id;
  String name;
  // Add fields

  YourModel({required this.id, required this.name});

  Map<String, dynamic> toMap() {
    return {'id': id, 'name': name};
  }

  factory YourModel.fromMap(Map<String, dynamic> map) {
    return YourModel(id: map['id'], name: map['name']);
  }
}
```

#### 2. Create the Repository

**Location**: `lib/data/repositories/`

```dart
class YourRepository {
  final DbHelper _dbHelper = DbHelper();

  Future<void> insert(YourModel model) async {
    final db = await _dbHelper.database;
    await db.insert('your_table', model.toMap());
  }

  Future<List<YourModel>> getAll() async {
    final db = await _dbHelper.database;
    final maps = await db.query('your_table');
    return maps.map((m) => YourModel.fromMap(m)).toList();
  }

  Future<void> update(YourModel model) async {
    final db = await _dbHelper.database;
    await db.update('your_table', model.toMap(), 
      where: 'id = ?', whereArgs: [model.id]);
  }

  Future<void> delete(String id) async {
    final db = await _dbHelper.database;
    await db.delete('your_table', where: 'id = ?', whereArgs: [id]);
  }
}
```

#### 3. Create the Controller

**Location**: `lib/controllers/`

```dart
class YourController extends GetxController {
  final YourRepository _repo = YourRepository();
  var items = <YourModel>[].obs;
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
    } finally {
      isLoading.value = false;
    }
    update(); // Trigger UI update
  }

  Future<void> addItem(YourModel item) async {
    await _repo.insert(item);
    loadItems();
    
    // Refresh dashboard if needed
    if (Get.isRegistered<DashboardController>()) {
      Get.find<DashboardController>().loadStats();
    }
    
    update();
  }
}
```

#### 4. Create the Screen

**Location**: `lib/views/screens/`

```dart
class YourScreen extends StatelessWidget {
  const YourScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final YourController controller = Get.put(YourController());

    return Scaffold(
      appBar: AppBar(title: Text('your_title'.tr)),
      body: GetBuilder<YourController>(
        builder: (ctrl) {
          if (ctrl.isLoading.value) {
            return const Center(child: CircularProgressIndicator());
          }

          return ListView.builder(
            itemCount: ctrl.items.length,
            itemBuilder: (context, index) {
              final item = ctrl.items[index];
              return ListTile(title: Text(item.name));
            },
          );
        },
      ),
    );
  }
}
```

#### 5. Add Database Table

**Location**: `lib/data/db_helper.dart`

Add table creation in `_onCreate` method:

```dart
await db.execute('''
  CREATE TABLE your_table (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TEXT
  )
''');
```

#### 6. Add Translations

**Location**: `lib/utils/translations.dart`

```dart
'your_key': 'English Text',
// In ar_AR section:
'your_key': 'النص العربي',
```

### State Management Best Practices

1. **Always call `update()`** after modifying data in controllers
2. **Use GetBuilder** for screens that need to react to `update()` calls
3. **Use Obx** for individual reactive widgets
4. **Refresh Dashboard** when modifying data that affects stats

### Dashboard Auto-Update

When adding features that affect dashboard statistics:

```dart
// In your controller method
Future<void> yourMethod() async {
  // Your logic here
  
  // Refresh dashboard
  if (Get.isRegistered<DashboardController>()) {
    Get.find<DashboardController>().loadStats();
  }
  
  update();
}
```

---

## 🌐 API Integration Guide

### Preparing for Laravel Backend

The app currently uses local SQLite. To integrate with a Laravel API:

#### 1. Create API Service

**Location**: `lib/services/api_service.dart`

```dart
import 'package:http/http.dart' as http;
import 'dart:convert';

class ApiService {
  static const String baseUrl = 'https://your-api.com/api';
  
  Future<List<dynamic>> getSubscribers() async {
    final response = await http.get(
      Uri.parse('$baseUrl/subscribers'),
      headers: {'Authorization': 'Bearer $token'},
    );
    
    if (response.statusCode == 200) {
      return json.decode(response.body)['data'];
    }
    throw Exception('Failed to load subscribers');
  }

  Future<void> createSubscriber(Map<String, dynamic> data) async {
    final response = await http.post(
      Uri.parse('$baseUrl/subscribers'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: json.encode(data),
    );
    
    if (response.statusCode != 201) {
      throw Exception('Failed to create subscriber');
    }
  }
}
```

#### 2. Update Repository

Modify repositories to use API instead of local DB:

```dart
class SubscriberRepository {
  final ApiService _api = ApiService();
  final DbHelper _db = DbHelper(); // Keep for offline support

  Future<List<Subscriber>> getAll({String? query}) async {
    try {
      // Try API first
      final data = await _api.getSubscribers();
      final subscribers = data.map((d) => Subscriber.fromMap(d)).toList();
      
      // Cache locally
      await _cacheLocally(subscribers);
      
      return subscribers;
    } catch (e) {
      // Fallback to local DB if offline
      return await _getFromLocal();
    }
  }
}
```

#### 3. Laravel API Endpoints Structure

```
POST   /api/login                    - User login
POST   /api/logout                   - User logout
GET    /api/user                     - Get authenticated user

GET    /api/subscribers              - List subscribers
POST   /api/subscribers              - Create subscriber
GET    /api/subscribers/{id}         - Get subscriber
PUT    /api/subscribers/{id}         - Update subscriber
DELETE /api/subscribers/{id}         - Delete subscriber

GET    /api/boards                   - List boards
POST   /api/boards                   - Create board
// ... similar CRUD endpoints

GET    /api/receipts                 - List receipts
POST   /api/receipts                 - Create receipt

GET    /api/dashboard/stats          - Dashboard statistics
```

#### 4. Sync Strategy

**Option A: Online-First**
- Always use API when connected
- Cache responses locally
- Use local data when offline

**Option B: Offline-First (Current)**
- Use local SQLite database
- Sync to API in background
- Handle conflicts with timestamp comparison

---

## 🔧 Configuration

### Bluetooth Printing

The app uses `blue_thermal_printer` package. Compatible with ESC/POS thermal printers.

**Supported Features:**
- Text printing (English & Arabic)
- QR code generation
- Custom receipt layouts
- Image rendering for Arabic text

### Localization

Add new languages in `lib/utils/translations.dart`:

```dart
Map<String, Map<String, String>> get keys => {
  'en_US': { /* English translations */ },
  'ar_AR': { /* Arabic translations */ },
  'fr_FR': { /* Add French */ },
};
```

---

## 📦 Dependencies

Key packages used:

- **get**: State management and dependency injection
- **sqflite**: Local SQLite database
- **blue_thermal_printer**: Bluetooth thermal printing
- **shared_preferences**: Local key-value storage
- **uuid**: Unique ID generation
- **intl**: Internationalization and formatting
- **pdf**: PDF generation
- **path_provider**: File system paths

---

## 🧪 Testing

### Running Tests

```bash
flutter test
```

### Manual Testing Checklist

- [ ] Create admin account
- [ ] Add subscriber
- [ ] Collect payment
- [ ] Print receipt via Bluetooth
- [ ] Add board and circuit
- [ ] Export/import data
- [ ] Switch language
- [ ] Test permissions (admin vs accountant)

---

## 📱 Deployment

### Android

1. **Update version** in `pubspec.yaml`
2. **Build APK**:
```bash
flutter build apk --release
```

3. **Build App Bundle** (for Play Store):
```bash
flutter build appbundle --release
```

### iOS

1. **Update version** in `pubspec.yaml` and Xcode
2. **Build**:
```bash
flutter build ios --release
```

---

## 🤝 Contributing

1. Fork the repository
2. Create feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📄 License

This project is proprietary software. All rights reserved.

---

## 📞 Support

For support and queries:
- Email: support@example.com
- Documentation: [Link to detailed docs]

---

## 🗺️ Roadmap

- [ ] Cloud synchronization with Laravel API
- [ ] Advanced reporting and analytics
- [ ] Multi-generator management
- [ ] SMS notifications for payments
- [ ] Mobile money integration
- [ ] Web admin dashboard
- [ ] Real-time collaboration features

---

**Built with ❤️ using Flutter**
