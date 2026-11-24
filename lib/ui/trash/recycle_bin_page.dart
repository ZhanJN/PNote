/// 老入口：单独一个「任务回收站」页面（1.45 起退成薄壳）。
///
/// 1.45 把回收站合并成 [TrashPage]（「任务 / 笔记」两个页签），
/// 具体逻辑搬进了 `tasks_trash_view.dart`。这个类保留是因为：
///   * 旧的测试（`test/recycle_bin_page_test.dart`）直接 pump 它；
///   * 万一哪天需要「只开任务回收站」的独立页面，还是从这儿进最省事。
///
/// 语义（与《PNote项目说明》7.4 一致）：
///   删除 = 打墓碑，任务从列表里消失，但仍然在库里、仍然参与同步。
///   恢复 = 给 deleted_at 写一个「值为 null 的新版本」，于是它又变回未删除。
///   永久删除 = 真的从库里删掉，并把它记进 purged，让另一台设备也删掉。
library;

import 'package:material_ui/material_ui.dart';

import 'package:pnote/data/task_dao.dart';
import 'package:pnote/ui/trash/tasks_trash_view.dart';

class RecycleBinPage extends StatelessWidget {
  const RecycleBinPage({super.key, required this.dao});

  final TaskDao dao;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('回收站')),
      body: TasksTrashView(dao: dao),
    );
  }
}
