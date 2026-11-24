/// 统一回收站（1.45）：一个页面，两个页签 ——「任务」和「笔记」。
///
/// 为什么合到一个页面：用户反馈「如果待办与笔记的回收站能互通更好」。
/// 合并的是**入口和操作手感**（同样的恢复 / 永久删除 / 多选 / 全部恢复 / 清空），
/// 不是数据模型：
///   * 任务回收站 = 数据库里的墓碑（`deleted_at` 有值），还参与同步；
///   * 笔记回收站 = 磁盘上的 `.trash/<时间戳>/` 目录，文件还在，恢复会落回 `年/月`。
///
/// 两个页签各自维护自己的加载、多选、忙状态；外面只负责标题和切换。
library;

import 'package:material_ui/material_ui.dart';

import 'package:pnote/data/task_dao.dart';
import 'package:pnote/notes/notes_store.dart';
import 'package:pnote/ui/trash/notes_trash_view.dart';
import 'package:pnote/ui/trash/tasks_trash_view.dart';

class TrashPage extends StatefulWidget {
  const TrashPage({
    super.key,
    required this.dao,
    this.store = const NotesStore(),
    this.initialTab = 0,
  });

  final TaskDao dao;
  final NotesStore store;

  /// 0 = 任务，1 = 笔记。从笔记页的回收站图标进来时传 1。
  final int initialTab;

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final GlobalKey<TasksTrashViewState> _tasksKey =
      GlobalKey<TasksTrashViewState>();
  final GlobalKey<NotesTrashViewState> _notesKey =
      GlobalKey<NotesTrashViewState>();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 1),
    );
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('回收站'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.check_circle_outline), text: '任务'),
            Tab(icon: Icon(Icons.sticky_note_2_outlined), text: '笔记'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          TasksTrashView(key: _tasksKey, dao: widget.dao),
          NotesTrashView(key: _notesKey, store: widget.store),
        ],
      ),
    );
  }
}
