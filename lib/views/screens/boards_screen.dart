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
      body: SafeArea(child: GetBuilder<CoreController>(
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
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.0,
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
                        // v22 item 10: reload on return so the paid/unpaid
                        // badges reflect payments collected inside.
                        if (widget.forCircuits) {
                          Get.to(() => CircuitsScreen(board: board))
                              ?.then((_) => controller.loadBoards());
                        } else {
                          Get.to(() => SubscribersScreen(boardId: board.id))
                              ?.then((_) => controller.loadBoards());
                        }
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.all(10.0),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.grid_view,
                              size: 34,
                              color: Color(0xFF1565C0),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              board.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
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
                                  fontSize: 11,
                                ),
                              ),
                            // v22 item 10: paid/unpaid subscriber counts for
                            // the selected month (green = paid, red = unpaid),
                            // only when the board HAS subscribers.
                            if ((ctrl.boardPaidCounts[board.id]?.paid ?? 0) +
                                    (ctrl.boardPaidCounts[board.id]?.unpaid ??
                                        0) >
                                0) ...[
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.green,
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    '${ctrl.boardPaidCounts[board.id]!.paid}',
                                    style: const TextStyle(
                                      color: Colors.green,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.red,
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    '${ctrl.boardPaidCounts[board.id]!.unpaid}',
                                    style: const TextStyle(
                                      color: Colors.red,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (auth.can(Perm.boards))
                      Positioned(
                        top: 4,
                        // v22 item 11: the edit/delete 3-dots menu sits in the
                        // LEFT corner of the card (was the right).
                        left: 4,
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
      )),
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
      // v22 item 8: close-FIRST-then-act (a throw stranded the dialog open; a
      // double-tapped confirm over-popped a real route). Raw-navigator pop —
      // Get.back would be swallowed by an open snackbar and leave the dialog up.
      onConfirm: () async {
        Navigator.of(context, rootNavigator: true).pop();
        try {
          // v35 item 5: refused when the board's cascade would erase receipts
          // already inside a settlement (would corrupt accountant wallets).
          final ok = await controller.deleteBoard(board.id);
          if (!ok) {
            Get.snackbar('error'.tr, 'delete_blocked_settled'.tr,
                backgroundColor: Colors.orange, colorText: Colors.white);
            return;
          }
        } catch (e) {
          Get.snackbar('error'.tr, '$e',
              backgroundColor: Colors.redAccent, colorText: Colors.white);
          return;
        }
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
