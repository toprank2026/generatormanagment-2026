import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/branch_model.dart';
import 'package:generatormanagment/data/repositories/branch_repository.dart';

/// Branch context layer (full isolation): the device has ONE active branch at a
/// time; every business read scopes to it and every create stamps it. Switching
/// a branch switches the whole system context (it is NOT a filter over shared
/// data). The owner may also pick "All branches" (consolidated) for reporting
/// only — represented by [currentBranch] == null.
///
/// Mirrors the existing acting-user layer in AuthController (persisted +
/// restored on launch); controllers `ever(currentBranch)`-reload on a switch.
class BranchController extends GetxController {
  final BranchRepository _repo = BranchRepository();

  /// The active branch. A concrete branch in normal operation (defaults to the
  /// Main Branch). `null` = consolidated / All branches (owner reporting only).
  final Rxn<Branch> currentBranch = Rxn<Branch>();
  final RxList<Branch> branches = <Branch>[].obs;

  static const String _kActiveBranchId = 'active_branch_id';
  static const String _kAll = '__ALL__';

  /// Branch id to scope reads/writes by. `null` = consolidated (no filter).
  String? get scopeBranchId => currentBranch.value?.id;

  /// The active branch id used to STAMP new rows (never consolidated — a new row
  /// always belongs to a concrete branch; falls back to Main).
  String get writeBranchId =>
      currentBranch.value?.id ?? DbHelper.kMainBranchId;

  bool get isConsolidated => currentBranch.value == null;

  @override
  void onInit() {
    super.onInit();
    // Default to a Main Branch context immediately so the very first reads are
    // already branch-scoped (never an un-scoped flash), then refine from the DB.
    currentBranch.value = Branch(
      id: DbHelper.kMainBranchId,
      name: 'الفرع الرئيسي',
      isMain: true,
    );
    init();
  }

  Future<void> init() async {
    await _repo.ensureMain();
    await loadBranches();
    await _restoreActive();
  }

  Future<void> loadBranches() async {
    branches.assignAll(await _repo.getAll());
    update();
  }

  Future<void> _restoreActive() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_kActiveBranchId);
    if (id == _kAll) {
      currentBranch.value = null; // consolidated (owner)
    } else {
      final wanted = id ?? DbHelper.kMainBranchId;
      currentBranch.value = branches.firstWhereOrNull((b) => b.id == wanted) ??
          branches.firstWhereOrNull((b) => b.id == DbHelper.kMainBranchId) ??
          (branches.isNotEmpty ? branches.first : currentBranch.value);
    }
    update();
  }

  /// Switch the active branch. Pass `null` for the consolidated (All) view.
  Future<void> setBranch(Branch? branch) async {
    currentBranch.value = branch;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActiveBranchId, branch?.id ?? _kAll);
    update();
  }

  /// Switch to the consolidated / All-branches view (owner reporting only).
  Future<void> setConsolidated() => setBranch(null);

  /// R7: after a branch-switch clear+pull, re-establish branches from the
  /// freshly-pulled local DB and activate [targetId] (null = consolidated).
  /// Setting the active branch fires every controller's `ever(currentBranch)`
  /// reload against the new data, so the whole app re-binds to the branch.
  Future<void> reloadAndActivate(String? targetId) async {
    await _repo.ensureMain();
    await loadBranches();
    if (targetId == null) {
      await setBranch(null);
      return;
    }
    final b = branches.firstWhereOrNull((x) => x.id == targetId) ??
        branches.firstWhereOrNull((x) => x.id == DbHelper.kMainBranchId) ??
        (branches.isNotEmpty ? branches.first : null);
    await setBranch(b);
  }

  // --- Owner CRUD (gated by AuthController.canMultiBranch at the UI layer) ---

  /// Create a new branch and refresh the list. Returns the created branch.
  Future<Branch> addBranch(String name, {String? code, bool active = true}) async {
    final id = const Uuid().v4();
    await _repo.create(id: id, name: name, code: code, active: active);
    await loadBranches();
    return branches.firstWhereOrNull((b) => b.id == id) ??
        Branch(id: id, name: name, code: code, active: active);
  }

  /// Edit a branch; keeps [currentBranch] in sync if the active one changed.
  Future<void> editBranch(String id,
      {String? name, String? code, bool? active}) async {
    await _repo.update(id: id, name: name, code: code, active: active);
    await loadBranches();
    if (currentBranch.value?.id == id) {
      currentBranch.value =
          branches.firstWhereOrNull((b) => b.id == id) ?? currentBranch.value;
    }
  }

  /// Delete a branch (and its isolated data). The Main Branch is protected. If
  /// the deleted branch was active, fall back to the Main Branch.
  Future<void> removeBranch(String id) async {
    if (id == DbHelper.kMainBranchId) return;
    final wasActive = currentBranch.value?.id == id;
    await _repo.delete(id);
    await loadBranches();
    if (wasActive) {
      await setBranch(
        branches.firstWhereOrNull((b) => b.id == DbHelper.kMainBranchId) ??
            (branches.isNotEmpty ? branches.first : null),
      );
    }
  }
}
