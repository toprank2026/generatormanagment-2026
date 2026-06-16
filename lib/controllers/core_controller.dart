import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/controllers/billing_controller.dart';
import 'package:generatormanagment/controllers/dashboard_controller.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';

class CoreController extends GetxController {
  final BoardRepository _boardRepo = BoardRepository();
  final CircuitRepository _circuitRepo = CircuitRepository();
  final SubscriberRepository _subscriberRepo = SubscriberRepository();
  final AuthController _auth = Get.find();
  final BranchController _branch = Get.find();

  // Boards, circuits and subscribers are SHARED across all accountants (the
  // owner's common customer base), so their reads/deletes are never scoped by
  // accountant — only receipts/expenses are per-accountant (see billing/reports).
  // They ARE, however, scoped by the active BRANCH (full isolation): reads pass
  // the active branch id and creates stamp it.

  /// Active-branch read scope (null = consolidated / All branches).
  String? get _branchScope => _branch.scopeBranchId;

  var boards = <Board>[].obs;
  var circuits = <Circuit>[].obs; // Currently selected board's circuits
  var subscribers = <Subscriber>[].obs;
  var isLoading = false.obs;

  // Pagination (subscribers). Large page (R1/D1): effectively "show all" for
  // normal data sizes; infinite scroll (loadMore) still loads the rest at scale.
  static const int itemsPerPage = 100;
  var currentPage = 1.obs;
  var hasNextPage = false.obs;
  var isMoreLoading = false.obs;
  // Keep track of current query to maintain state across pages
  String? _currentQuery;

  // Pagination (boards) — large page (R1): show all for normal sizes.
  static const int boardsPerPage = 100;
  var boardsPage = 1.obs;
  var boardsHasNext = false.obs;
  var isBoardsMoreLoading = false.obs;

  // Pagination (circuits) — large page (R1): show all for normal sizes.
  static const int circuitsPerPage = 100;
  var circuitsPage = 1.obs;
  var circuitsHasNext = false.obs;
  var isCircuitsMoreLoading = false.obs;
  // Keep track of current board to maintain state across pages
  String? _currentCircuitsBoardId;

  @override
  void onInit() {
    super.onInit();
    // Re-scope lists when the acting user changes (owner <-> accountant).
    ever(_auth.currentUser, (_) {
      loadBoards();
      loadSubscribers();
    });
    // Re-scope lists when the active branch switches (full system-context swap).
    ever(_branch.currentBranch, (_) {
      loadBoards();
      loadSubscribers();
    });
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
  Future<void> loadBoards({int page = 1}) async {
    if (page == 1) {
      isLoading.value = true;
      boards.clear();
    } else {
      isBoardsMoreLoading.value = true;
    }

    boardsPage.value = page;

    try {
      // Fetch one extra item to check if there is a next page
      final result = await _boardRepo.getAll(
        limit: boardsPerPage + 1,
        offset: (page - 1) * boardsPerPage,
        accountantId: null,
        branchId: _branchScope,
      );

      List<Board> newItems;
      if (result.length > boardsPerPage) {
        boardsHasNext.value = true;
        newItems = result.sublist(0, boardsPerPage);
      } else {
        boardsHasNext.value = false;
        newItems = result;
      }

      if (page == 1) {
        boards.assignAll(newItems);
      } else {
        boards.addAll(newItems);
      }
    } finally {
      isLoading.value = false;
      isBoardsMoreLoading.value = false;
    }
    update();
  }

  void loadMoreBoards() {
    if (boardsHasNext.value &&
        !isBoardsMoreLoading.value &&
        !isLoading.value) {
      loadBoards(page: boardsPage.value + 1);
    }
  }

  Future<void> addBoard(String name, String? code, {String? accountantId}) async {
    Board b = Board(
      id: const Uuid().v4(),
      name: name,
      code: code,
      accountantId: accountantId,
      branchId: _branch.writeBranchId,
    );
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
    await _boardRepo.delete(id, accountantId: null);
    loadBoards();
    _refreshDashboard();
    update();
  }

  // --- Circuits ---
  Future<void> loadCircuits(String boardId, {int page = 1}) async {
    if (page == 1) {
      isLoading.value = true;
      circuits.clear();
    } else {
      isCircuitsMoreLoading.value = true;
    }

    _currentCircuitsBoardId = boardId;
    circuitsPage.value = page;

    try {
      // Fetch one extra item to check if there is a next page
      final result = await _circuitRepo.getByBoardId(
        boardId,
        limit: circuitsPerPage + 1,
        offset: (page - 1) * circuitsPerPage,
        accountantId: null,
        branchId: _branchScope,
      );

      List<Circuit> newItems;
      if (result.length > circuitsPerPage) {
        circuitsHasNext.value = true;
        newItems = result.sublist(0, circuitsPerPage);
      } else {
        circuitsHasNext.value = false;
        newItems = result;
      }

      if (page == 1) {
        circuits.assignAll(newItems);
      } else {
        circuits.addAll(newItems);
      }
    } finally {
      isLoading.value = false;
      isCircuitsMoreLoading.value = false;
    }
    update();
  }

  void loadMoreCircuits() {
    if (circuitsHasNext.value &&
        !isCircuitsMoreLoading.value &&
        !isLoading.value &&
        _currentCircuitsBoardId != null) {
      loadCircuits(_currentCircuitsBoardId!, page: circuitsPage.value + 1);
    }
  }

  Future<void> addCircuit(String boardId, String name, String? phase,
      {String? accountantId}) async {
    Circuit c = Circuit(
      id: const Uuid().v4(),
      boardId: boardId,
      name: name,
      phase: phase,
      accountantId: accountantId,
      branchId: _branch.writeBranchId,
    );
    await _circuitRepo.insert(c);
    loadCircuits(boardId);
    _refreshDashboard();
    update();
  }

  Future<void> deleteCircuit(String id, String boardId) async {
    await _circuitRepo.delete(id, accountantId: null);
    loadCircuits(boardId);
    _refreshDashboard();
    update();
  }

  // --- Subscribers ---
  Future<void> loadSubscribers({String? query, int page = 1}) async {
    if (page == 1) {
      isLoading.value = true;
      subscribers.clear();
    } else {
      isMoreLoading.value = true;
    }

    _currentQuery = query;
    currentPage.value = page;

    try {
      // Fetch one extra item to check if there is a next page
      final result = await _subscriberRepo.getAll(
        query: query,
        limit: itemsPerPage + 1,
        offset: (page - 1) * itemsPerPage,
        accountantId: null,
        branchId: _branchScope,
      );

      List<Subscriber> newItems;
      if (result.length > itemsPerPage) {
        hasNextPage.value = true;
        newItems = result.sublist(0, itemsPerPage);
      } else {
        hasNextPage.value = false;
        newItems = result;
      }

      if (page == 1) {
        subscribers.assignAll(newItems);
      } else {
        subscribers.addAll(newItems);
      }
    } finally {
      isLoading.value = false;
      isMoreLoading.value = false;
    }
    update();
  }

  void loadMore() {
    if (hasNextPage.value && !isMoreLoading.value && !isLoading.value) {
      loadSubscribers(query: _currentQuery, page: currentPage.value + 1);
    }
  }

  Future<void> addSubscriber(Subscriber sub) async {
    // Stamp the active branch (full isolation): the view doesn't know about
    // branches, so the controller assigns the new subscriber to the current one.
    sub.branchId ??= _branch.writeBranchId;
    await _validateSubscriber(sub); // R7/R8 — throws ValidationException
    await _subscriberRepo.insert(sub);
    loadSubscribers(); // Refresh list if showing all
    _refreshDashboard();
    update();
  }

  Future<void> updateSubscriber(Subscriber sub) async {
    sub.branchId ??= _branch.writeBranchId;
    await _validateSubscriber(sub, exceptId: sub.id);
    await _subscriberRepo.update(sub);
    loadSubscribers();
    _refreshDashboard();
    update();
  }

  /// R8 (unique name, per branch) + R7 (one active subscriber per socket, per
  /// branch). Throws [ValidationException] with a translation key for the UI.
  Future<void> _validateSubscriber(Subscriber sub, {String? exceptId}) async {
    final branch = sub.branchId ?? _branch.writeBranchId;
    if (await _subscriberRepo.nameExists(sub.name,
        branchId: branch, exceptId: exceptId)) {
      throw ValidationException('duplicate_name');
    }
    if (await _subscriberRepo.isCircuitTaken(sub.circuitId,
        branchId: branch, exceptId: exceptId)) {
      throw ValidationException('circuit_in_use');
    }
  }

  Future<void> deleteSubscriber(String id) async {
    await _subscriberRepo.delete(id, accountantId: null);
    loadSubscribers();
    _refreshDashboard();
    update();
  }

  Future<void> loadFilteredSubscribers(String filter) async {
    isLoading.value = true;
    try {
      // The selected month drives paid/unpaid; the price is now category-aware
      // and resolved inside the query (per subscriber's category), so no single
      // price is needed here.
      final String month = Get.isRegistered<BillingController>()
          ? Get.find<BillingController>().selectedMonth.value
          : DateFormat('yyyy-MM').format(DateTime.now());

      subscribers.value = await _subscriberRepo.getByPaymentStatus(
        month: month,
        isPaid: filter == 'paid',
        accountantId: null,
        branchId: _branchScope,
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
      subscribers.value = await _subscriberRepo.getByBoard(boardId,
          accountantId: null, branchId: _branchScope);
    } finally {
      isLoading.value = false;
    }
    update();
  }
}
