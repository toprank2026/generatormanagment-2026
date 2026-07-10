import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/controllers/dashboard_controller.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/controllers/month_controller.dart';

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

  // v22 item 2: ids of subscribers PAID for the selected month (one query per
  // list load, not per row) — every list row paints its green/red dot from it.
  final Set<String> paidIds = <String>{};
  // v22 item 9: circuit id → display name, so rows show their جوزة without N+1.
  final Map<String, String> circuitNames = <String, String>{};
  // v34 item 6: board id → display name — the subscriber row shows its BOARD
  // above the جوزة (same batch-map pattern, no per-row queries).
  final Map<String, String> boardNames = <String, String>{};
  // v22 item 10: board id → (paid, unpaid) subscriber counts for the selected
  // month (one GROUP BY query per boards load) — shown under each board name.
  final Map<String, ({int paid, int unpaid})> boardPaidCounts =
      <String, ({int paid, int unpaid})>{};
  // v26 item 2: per-subscriber COVERAGE (cash+discount) for the selected month
  // and the month's per-branch category prices — so every list row can show
  // the amount still to collect, with zero per-row queries.
  final Map<String, double> _rowCoverage = <String, double>{};
  final Map<String, Map<String, double>> _rowPricesByBranch =
      <String, Map<String, double>>{};
  // v27 item 1: total amps of the board whose subscriber list is showing.
  final boardAmpsTotal = 0.0.obs;

  /// Refreshes the row metadata (paid-ids set + circuit-name map + coverage +
  /// prices) for the active branch + globally-selected month. Called on page-1
  /// list loads.
  Future<void> _loadRowMeta() async {
    try {
      final month = Get.find<MonthController>().selectedMonth.value;
      final paid = await _subscriberRepo.paidSubscriberIds(
          month: month, branchId: _branchScope);
      final allCircuits =
          await _circuitRepo.getAllInBranch(branchId: _branchScope);
      final allBoards = await _boardRepo.getAll(branchId: _branchScope);
      final coverage = await _subscriberRepo.coverageBySubscriber(
          month: month, branchId: _branchScope);
      final prices = await MonthlyPriceRepository().pricesForMonthByBranch(month);
      paidIds
        ..clear()
        ..addAll(paid);
      circuitNames
        ..clear()
        ..addEntries(allCircuits.map((c) => MapEntry(c.id, c.name)));
      boardNames
        ..clear()
        ..addEntries(allBoards.map((b) => MapEntry(b.id, b.name)));
      _rowCoverage
        ..clear()
        ..addAll(coverage);
      _rowPricesByBranch
        ..clear()
        ..addAll(prices);
    } catch (_) {/* row badges are best-effort; the list itself still loads */}
  }

  /// v26 item 2: the amount still to collect from [sub] for the selected month
  /// (due = amps × its category's price − coverage, clamped at 0). Returns null
  /// when the month has NO price for the subscriber's branch+category (not yet
  /// billable — the row hides the line; the no-price banner explains why).
  /// Same price/coverage rules as the paid/unpaid dot, so the two never
  /// contradict each other on a row.
  double? dueFor(Subscriber sub) {
    final branchKey = sub.branchId ?? DbHelper.kMainBranchId;
    final price = _rowPricesByBranch[branchKey]?[
        SubscriberCategory.normalize(sub.category)];
    if (price == null) return null;
    final due = sub.amps * price - (_rowCoverage[sub.id] ?? 0);
    return due < 0 ? 0 : due;
  }

  // Pagination (subscribers). Large page (R1/D1): effectively "show all" for
  // normal data sizes; infinite scroll (loadMore) still loads the rest at scale.
  static const int itemsPerPage = 100;
  var currentPage = 1.obs;
  var hasNextPage = false.obs;
  var isMoreLoading = false.obs;
  // Keep track of current query to maintain state across pages
  String? _currentQuery;
  // Active category-tab filter (R5): null = All categories. Preserved across
  // pages so loadMore keeps the same category.
  String? _currentCategory;
  // v23 item 7: which subscriber-list VARIANT is currently loaded, so the shared
  // `loadMore` continues the right one. Exactly one of these is non-null at a
  // time; both null = the plain "All subscribers" list.
  String? _currentFilter; // 'paid' | 'unpaid' | null
  String? _currentBoardId; // board-scoped list | null

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
    // item 9: every board/circuit/subscriber write funnels through here (loads
    // don't), so this is the choke point to auto-sync after a write (online).
    SyncController.poke();
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
      // v22 item 10: refresh the per-board paid/unpaid counts with page 1
      // (best-effort — the grid still renders without the badges).
      if (page == 1) {
        try {
          final month = Get.find<MonthController>().selectedMonth.value;
          final counts = await _subscriberRepo.paymentCountsByBoard(
              month: month, branchId: _branchScope);
          boardPaidCounts
            ..clear()
            ..addAll(counts);
        } catch (_) {}
      }
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
    final branch = _branch.writeBranchId;
    // R1: reject a duplicate board name within the branch.
    if (await _boardRepo.nameExists(name, branchId: branch)) {
      throw ValidationException('duplicate_board_name');
    }
    Board b = Board(
      id: const Uuid().v4(),
      name: name,
      code: code,
      accountantId: accountantId ?? _auth.scopeAccountantId, // item 5: link to creator
      branchId: branch,
      // v20: stamp creation time so boards sort in true creation order (the
      // list orders by created_at; without this the column would be NULL).
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
    await _boardRepo.insert(b);
    loadBoards();
    _refreshDashboard();
    update();
  }

  Future<void> updateBoard(Board b) async {
    // R1: reject a name that collides with ANOTHER board in the same branch.
    if (await _boardRepo.nameExists(b.name,
        branchId: b.branchId ?? _branch.writeBranchId, exceptId: b.id)) {
      throw ValidationException('duplicate_board_name');
    }
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
    final branch = _branch.writeBranchId;
    // R1: reject a duplicate feed/circuit name within the same board.
    if (await _circuitRepo.nameExists(name, boardId, branchId: branch)) {
      throw ValidationException('duplicate_circuit_name');
    }
    Circuit c = Circuit(
      id: const Uuid().v4(),
      boardId: boardId,
      name: name,
      phase: phase,
      accountantId: accountantId ?? _auth.scopeAccountantId, // item 5: link to creator
      branchId: branch,
      // v20: stamp creation time so circuits sort in true creation order.
      createdAt: DateTime.now().toUtc().toIso8601String(),
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
  Future<void> loadSubscribers(
      {String? query, int page = 1, String? category}) async {
    if (page == 1) {
      isLoading.value = true;
      subscribers.clear();
    } else {
      isMoreLoading.value = true;
    }

    _currentQuery = query;
    _currentCategory = category;
    _currentFilter = null; // v23: "All" mode — loadMore continues getAll
    _currentBoardId = null;
    currentPage.value = page;

    try {
      // v22 items 2+9: refresh the paid-dot set + circuit-name map with page 1.
      if (page == 1) await _loadRowMeta();
      // Fetch one extra item to check if there is a next page
      final result = await _subscriberRepo.getAll(
        query: query,
        limit: itemsPerPage + 1,
        offset: (page - 1) * itemsPerPage,
        accountantId: null,
        branchId: _branchScope,
        category: category, // R5: category-tab filter (null = all)
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

  /// v23 item 7: paginate whichever subscriber-list VARIANT is on screen. The
  /// three loaders keep `_currentFilter`/`_currentBoardId` mutually exclusive,
  /// so this dispatches the correct next-page loader.
  void loadMore() {
    if (!hasNextPage.value || isMoreLoading.value || isLoading.value) return;
    final next = currentPage.value + 1;
    if (_currentBoardId != null) {
      loadBoardSubscribers(_currentBoardId!, query: _currentQuery, page: next);
    } else if (_currentFilter != null) {
      loadFilteredSubscribers(_currentFilter!,
          category: _currentCategory, query: _currentQuery, page: next);
    } else {
      loadSubscribers(
          query: _currentQuery, page: next, category: _currentCategory);
    }
  }

  Future<void> addSubscriber(Subscriber sub) async {
    // Stamp the active branch (full isolation): the view doesn't know about
    // branches, so the controller assigns the new subscriber to the current one.
    sub.branchId ??= _branch.writeBranchId;
    // item 5: link a subscriber created by an accountant to that accountant.
    sub.accountantId ??= _auth.scopeAccountantId;
    // v22 item 5: stamp creation time so subscribers sort in true creation
    // order (the lists order by created_at; without this it would be NULL).
    sub.createdAt ??= DateTime.now().toUtc().toIso8601String();
    await _validateSubscriber(sub); // R7/R8 — throws ValidationException
    await _subscriberRepo.insert(sub);
    loadSubscribers(); // Refresh list if showing all
    _refreshDashboard();
    update();
  }

  Future<void> updateSubscriber(Subscriber sub) async {
    sub.branchId ??= _branch.writeBranchId;
    // item 5 (review fix): preserve the ORIGINAL creator's accountant_id on edit
    // (the edit form doesn't carry it) instead of wiping it to null. v22: same
    // for created_at, or editing would wipe it and break creation ordering.
    if (sub.accountantId == null || sub.createdAt == null) {
      final orig = await _subscriberRepo.getById(sub.id);
      sub.accountantId ??= orig?.accountantId;
      sub.createdAt ??= orig?.createdAt;
    }
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

  /// Paid/Unpaid list. v23 item 7: paginated with the canonical fetch-(N+1)
  /// pattern (was loading ALL matching rows at once — a crash risk at scale).
  Future<void> loadFilteredSubscribers(String filter,
      {String? category, String? query, int page = 1}) async {
    if (page == 1) {
      isLoading.value = true;
      subscribers.clear();
    } else {
      isMoreLoading.value = true;
    }
    _currentFilter = filter; // v23: paid/unpaid mode
    _currentBoardId = null;
    _currentQuery = query;
    _currentCategory = category;
    currentPage.value = page;
    try {
      // The globally-selected month (R9) drives paid/unpaid; the price is
      // category-aware and resolved inside the query (per subscriber's
      // category), so no single price is needed here.
      final String month = Get.find<MonthController>().selectedMonth.value;
      if (page == 1) await _loadRowMeta(); // v22 items 2+9
      final result = await _subscriberRepo.getByPaymentStatus(
        month: month,
        isPaid: filter == 'paid',
        accountantId: null,
        branchId: _branchScope,
        category: category, // R5: category-tab filter (null = all)
        query: query, // v22 item 1: search composes with paid/unpaid
        limit: itemsPerPage + 1,
        offset: (page - 1) * itemsPerPage,
      );
      final List<Subscriber> newItems;
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
    } catch (e) {
      print("Error loading filtered subscribers: $e");
    } finally {
      isLoading.value = false;
      isMoreLoading.value = false;
    }
    update();
  }

  /// Board-scoped list. v23 item 7: paginated (was unbounded).
  Future<void> loadBoardSubscribers(String boardId,
      {String? query, int page = 1}) async {
    if (page == 1) {
      isLoading.value = true;
      subscribers.clear();
    } else {
      isMoreLoading.value = true;
    }
    _currentBoardId = boardId; // v23: board mode
    _currentFilter = null;
    _currentQuery = query;
    currentPage.value = page;
    try {
      if (page == 1) {
        await _loadRowMeta(); // v22 items 2+9
        // v27 item 1: board total amps (ignores search — it's the whole board).
        boardAmpsTotal.value = await _subscriberRepo.sumAmpsByBoard(boardId,
            branchId: _branchScope);
      }
      final result = await _subscriberRepo.getByBoard(
        boardId,
        accountantId: null,
        branchId: _branchScope,
        query: query, // v22 item 1: search composes with the board scope
        limit: itemsPerPage + 1,
        offset: (page - 1) * itemsPerPage,
      );
      final List<Subscriber> newItems;
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
}
