import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/controllers/billing_controller.dart';
import 'package:generatormanagment/controllers/dashboard_controller.dart';

class CoreController extends GetxController {
  final BoardRepository _boardRepo = BoardRepository();
  final CircuitRepository _circuitRepo = CircuitRepository();
  final SubscriberRepository _subscriberRepo = SubscriberRepository();
  final MonthlyPriceRepository _priceRepo = MonthlyPriceRepository();

  var boards = <Board>[].obs;
  var circuits = <Circuit>[].obs; // Currently selected board's circuits
  var subscribers = <Subscriber>[].obs;
  var isLoading = false.obs;

  @override
  void onInit() {
    super.onInit();
  }

  @override
  void onReady() {
    super.onReady();
    loadBoards();
  }

  // Helper to refresh dashboard when data changes
  void _refreshDashboard() {
    if (Get.isRegistered<DashboardController>()) {
      Get.find<DashboardController>().loadStats();
    }
  }

  // --- Boards ---
  Future<void> loadBoards() async {
    isLoading.value = true;
    try {
      boards.value = await _boardRepo.getAll();
    } finally {
      isLoading.value = false;
    }
    update();
  }

  Future<void> addBoard(String name, String? code) async {
    Board b = Board(id: const Uuid().v4(), name: name, code: code);
    await _boardRepo.insert(b);
    loadBoards();
    _refreshDashboard();
    update();
  }

  Future<void> updateBoard(Board b) async {
    await _boardRepo.update(b);
    loadBoards();
    _refreshDashboard();
    update();
  }

  Future<void> deleteBoard(String id) async {
    await _boardRepo.delete(id);
    loadBoards();
    _refreshDashboard();
    update();
  }

  // --- Circuits ---
  Future<void> loadCircuits(String boardId) async {
    isLoading.value = true;
    try {
      circuits.value = await _circuitRepo.getByBoardId(boardId);
    } finally {
      isLoading.value = false;
    }
    update();
  }

  Future<void> addCircuit(String boardId, String name, String? phase) async {
    Circuit c = Circuit(
      id: const Uuid().v4(),
      boardId: boardId,
      name: name,
      phase: phase,
    );
    await _circuitRepo.insert(c);
    loadCircuits(boardId);
    _refreshDashboard();
    update();
  }

  Future<void> deleteCircuit(String id, String boardId) async {
    await _circuitRepo.delete(id);
    loadCircuits(boardId);
    _refreshDashboard();
    update();
  }

  // --- Subscribers ---
  Future<void> loadSubscribers({String? query}) async {
    isLoading.value = true;
    try {
      subscribers.value = await _subscriberRepo.getAll(query: query);
    } finally {
      isLoading.value = false;
    }
    update();
  }

  Future<void> addSubscriber(Subscriber sub) async {
    await _subscriberRepo.insert(sub);
    loadSubscribers(); // Refresh list if showing all
    _refreshDashboard();
    update();
  }

  Future<void> updateSubscriber(Subscriber sub) async {
    await _subscriberRepo.update(sub);
    loadSubscribers();
    _refreshDashboard();
    update();
  }

  Future<void> deleteSubscriber(String id) async {
    await _subscriberRepo.delete(id);
    loadSubscribers();
    _refreshDashboard();
    update();
  }

  Future<void> loadFilteredSubscribers(String filter) async {
    isLoading.value = true;
    try {
      String month;
      double price;

      // Try to get from BillingController if available (active state)
      if (Get.isRegistered<BillingController>()) {
        final billing = Get.find<BillingController>();
        month = billing.selectedMonth.value;
        price = billing.currentPrice.value?.pricePerAmp ?? 0.0;
      } else {
        // Fallback to current month and DB price
        month = DateFormat('yyyy-MM').format(DateTime.now());
        final priceObj = await _priceRepo.getByMonth(month);
        price = priceObj?.pricePerAmp ?? 0.0;
      }

      subscribers.value = await _subscriberRepo.getByPaymentStatus(
        month: month,
        pricePerAmp: price,
        isPaid: filter == 'paid',
      );
    } catch (e) {
      print("Error loading filtered subscribers: $e");
    } finally {
      isLoading.value = false;
    }
    update();
  }

  Future<void> loadBoardSubscribers(String boardId) async {
    isLoading.value = true;
    try {
      subscribers.value = await _subscriberRepo.getByBoard(boardId);
    } finally {
      isLoading.value = false;
    }
    update();
  }
}
