import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/core_controller.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/core/permissions.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart'
    show ValidationException;
import 'package:generatormanagment/views/widgets/app_form_field.dart';
import 'package:generatormanagment/views/screens/subscribers_screen.dart';
import 'package:generatormanagment/views/screens/circuits_screen.dart';
import 'package:generatormanagment/views/widgets/sync_progress_overlay.dart';

class BoardsScreen extends StatefulWidget {
  final bool forCircuits;
  const BoardsScreen({super.key, this.forCircuits = false});

  @override
  State<BoardsScreen> createState() => _BoardsScreenState();
}

class _BoardsScreenState extends State<BoardsScreen> {
  final CoreController controller = Get.find<CoreController>();
  final AuthController auth = Get.find<AuthController>();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.loadBoards();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      controller.loadMoreBoards();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(
        title: Text(
          'boards'.tr,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        backgroundColor: const Color(0xFF1565C0),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
      ),
      // P1: never offer "add board" from the circuit flow (forCircuits). Gate
      // OUTSIDE the Obx so its builder always reads an observable (auth.can) on
      // the normal flow — putting the forCircuits check inside the Obx would
      // short-circuit before any observable is read and throw GetX's "improper
      // use of Obx" (grey error screen).
      floatingActionButton: widget.forCircuits
          ? null
          : Obx(
              () => auth.can(Perm.boards)
                  ? FloatingActionButton.extended(
                      onPressed: () => _showBoardForm(context, controller),
                      icon: const Icon(Icons.add, color: Colors.white),
                      label: Text(
                        'add_new'.tr,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      backgroundColor: const Color(0xFF1565C0),
                    )
                  : const SizedBox.shrink(),
            ),
      body: GetBuilder<CoreController>(
        builder: (ctrl) {
          if (ctrl.isLoading.value) {
            return const Center(child: CircularProgressIndicator());
          }
          if (ctrl.boards.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.grid_off, size: 80, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(
                    'no_boards'.tr,
                    style: TextStyle(color: Colors.grey[600], fontSize: 16),
                  ),
                ],
              ),
            );
          }

          return GridView.builder(
            controller: _scrollController,
            // Explicit physics so the grid always scrolls through the GetBuilder
            // wrapper to the last board (R3).
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              childAspectRatio: 0.9,
            ),
            itemCount:
                ctrl.boards.length + (ctrl.isBoardsMoreLoading.value ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == ctrl.boards.length) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(8.0),
                    child: CircularProgressIndicator(),
                  ),
                );
              }
              final board = ctrl.boards[index];
              return Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Stack(
                  children: [
                    InkWell(
                      onTap: () {
                        if (widget.forCircuits) {
                          Get.to(() => CircuitsScreen(board: board));
                        } else {
                          Get.to(() => SubscribersScreen(boardId: board.id));
                        }
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.grid_view,
                              size: 48,
                              color: Color(0xFF1565C0),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              board.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (board.code != null && board.code!.isNotEmpty)
                              Text(
                                board.code!,
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (auth.can(Perm.boards))
                      Positioned(
                        top: 4,
                        right: 4,
                        child: PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert, color: Colors.grey),
                          onSelected: (val) {
                            if (val == 'edit') {
                              _showBoardForm(context, controller, board: board);
                            } else if (val == 'delete') {
                              _showDeleteConfirm(controller, board);
                            }
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: 'edit',
                              child: ListTile(
                                leading: const Icon(
                                  Icons.edit,
                                  color: Colors.blue,
                                ),
                                title: Text('edit'.tr),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: ListTile(
                                leading: const Icon(
                                  Icons.delete,
                                  color: Colors.red,
                                ),
                                title: Text('delete'.tr),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showBoardForm(
    BuildContext context,
    CoreController controller, {
    Board? board,
  }) {
    final nameCtrl = TextEditingController(text: board?.name);
    final codeCtrl = TextEditingController(text: board?.code);
    final isEdit = board != null;

    Get.defaultDialog(
      title: isEdit ? "edit_board".tr : "add_board".tr,
      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppTextField(
              controller: nameCtrl,
              label: "board_name".tr,
              hint: "board_name_hint".tr,
              icon: Icons.dashboard_outlined,
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: codeCtrl,
              label: "code".tr,
              hint: "board_code_hint".tr,
              icon: Icons.tag,
            ),
          ],
        ),
      ),
      textConfirm: isEdit ? "save_changes".tr : "add_new".tr,
      textCancel: "cancel".tr,
      confirmTextColor: Colors.white,
      buttonColor: const Color(0xFF1565C0),
      // Await the write before closing so the dialog always closes once, after
      // the board is persisted (R2). Empty name keeps it open.
      onConfirm: () async {
        if (nameCtrl.text.trim().isEmpty) return;
        // v14: block with a loading overlay until the write completes (prevents
        // double-tap + the crash from acting before it's saved); hide it BEFORE
        // any snackbar so it never blocks the dialog close.
        SyncProgress.show('saving'.tr);
        ValidationException? verr;
        bool ok = false;
        try {
          if (isEdit) {
            await controller.updateBoard(
              Board(
                id: board.id,
                name: nameCtrl.text.trim(),
                code: codeCtrl.text.trim(),
                // Preserve scope on edit — a full-row update would otherwise
                // null these out and move the board to the legacy/Main branch.
                accountantId: board.accountantId,
                branchId: board.branchId,
                createdAt: board.createdAt,
              ),
            );
          } else {
            await controller.addBoard(
                nameCtrl.text.trim(), codeCtrl.text.trim());
          }
          ok = true;
        } on ValidationException catch (e) {
          verr = e; // R1: duplicate name — keep the dialog open, show the reason.
        } finally {
          SyncProgress.hide();
        }
        if (verr != null) {
          Get.snackbar('error'.tr, verr.messageKey.tr,
              backgroundColor: Colors.redAccent, colorText: Colors.white);
          return;
        }
        if (!ok) return;
        Get.back();
        Get.snackbar(
          "success".tr,
          isEdit ? "board_updated".tr : "board_added".tr,
          backgroundColor: Colors.green,
          colorText: Colors.white,
        );
      },
    );
  }

  void _showDeleteConfirm(CoreController controller, Board board) {
    Get.defaultDialog(
      title: "delete_board_title".tr,
      middleText: "delete_board_confirm".tr,
      textConfirm: "delete".tr,
      textCancel: "cancel".tr,
      confirmTextColor: Colors.white,
      buttonColor: Colors.red,
      onConfirm: () async {
        await controller.deleteBoard(board.id);
        Get.back();
        Get.snackbar(
          "success".tr,
          "board_deleted".tr,
          backgroundColor: Colors.red,
          colorText: Colors.white,
        );
      },
    );
  }
}
