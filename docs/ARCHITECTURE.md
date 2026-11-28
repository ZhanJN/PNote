# 架构

> 版本 1.64.2 · 协议 `pnote-sync/8` · 数据库 schema 6

## 账号（同步分组，1.51）

同步层多了一个 `account` 概念：它是**一个名字**，不是注册账号。

- 存在 `meta.account_name`（本机偏好，不随同步走）；默认 `我的 PNote`，升级后所有设备都用它，所以老用户的两台设备仍然互相同步
- `SyncService` 把名字注入发现广播和 `state` 帧；两端名字不同就**一帧都不合并**，直接以 `AccountMismatch` 结束这一趟
- 「公开同步」只是内置的另一个名字：选它的设备彼此同名，于是在同一 Wi-Fi 内全量同步；代价是把内容也给了陌生人，所以界面要弹风险提示
- 切换时用 `meta.account_private_name` 记住上一个私有名，避免被「公开同步」顶掉

## 两条数据主线

PNote 里同时住着两类「数据」，它们刻意不共用一套模型：

| | 待办 | 笔记 |
|---|---|---|
| 真相在哪 | `pnote.db`（SQLite，`%APPDATA%`） | 磁盘上的 `.md` 文件（笔记库目录） |
| 结构 | `tasks` / `field_versions` / `meta` / `purged` 四张表 | 一个 `.md` + 同名 `.assets/` |
| 排序 | `order` 整数列，1024 的倍数整段重排 | `.groups.json` 的 `order` 记组内手排顺序，不动文件名 |
| 删除 | `deleted_at` 墓碑 + 版本 | 移到 `.trash/<时间戳>/` |
| 彻底删除 | `purged` 表（id + HLC） | `.sync.json` 的 `purged`（文件名 + HLC） |

理由：笔记的价值在于「用别的程序也能打开」，所以文件必须是真相；待办需要事务性的逐字段版本，所以放数据库。

## 分层

```
ui/          只做界面与交互，不直接写 SQL、不直接碰文件
  ↕
notes/       笔记的文件层：路径、读写、解析、渲染、组、排序、同步状态
data/        待办的持久层：schema、DAO（按域拆成 task_dao*.dart）、重复规则、时间
  ↕
sync/        纯 Dart，不 import Flutter：发现、传输、HLC、合并、mesh、编解码
platform/    平台能力：通知、路径、设备名
```

单向依赖：`ui` 可以依赖一切，`sync` 谁也不依赖（除了 `data` 暴露的纯接口 `exportState/applyRemote`），因此合并逻辑可以脱离界面单测。

## 待办：逐字段版本

每个可同步字段在 `field_versions` 里有一行 `(task_id, field, hlc_ms, hlc_c, device_id)`，值和版本**同一事务**写入。合并时逐字段比较 `(hlc_ms, hlc_c, device_id)`，大的赢，相等不写（幂等）。

- `kind`（任务/组）不进版本表，本机优先 —— 分组是「视角」，不是可交换的内容。
- 分组共用 `tasks` 表（`kind` + `parent_id`），最多两级；移动/重排改的是 `order` 与 `parent_id`，同样带版本。
- 墓碑不会让行消失：`deleted_at` 是普通字段，恢复就是把 `deleted_at` 改回空并给新版本。

## 笔记：文件即真相

- 路径：`笔记库/<年>/<月>/YYYY-MM-DD HHmm 标题.md`，素材在同名 `.md` 去掉后缀的 `.assets/` 里。
- 解析：`markdown` 包做 AST，自定义语法只有六种 —— `[[笔记]]`、`![[附件]]`、`#标题`（大纲/锚点）、`^块id`（暂未使用）、`==高亮==`（可带颜色）、`::: left/center/right` 对齐块。
- 组：库根 `.groups.json`（v3）记录组名、颜色、折叠、上下顺序、父组与置顶；一篇笔记只属于一个组（`assign`），组可多级嵌套，组本身也能置顶。组清单**随笔记同步**（整文件按 HLC 后写者胜）。
- 顺序：手动顺序存 `.groups.json` 的 `order`（按组或未分组）；时间排序（创建/修改 ↑↓）只影响当前显示，切回「手动」即恢复，绝不写盘覆盖手排顺序。
- 同步状态：`.sync.json` 存每个文件的 `{hlc, sha, size}` 与彻底删除记录；`.purge.json` 是「文件层 → 同步层」的暂存队列（文件层不知道 HLC 的细节）。
- 附件：单文件 ≤ 32 MB 才同步，按 1 MB 分块走 base64 帧。
- 编辑器（legacy，默认）：`markdown_blocks.dart` 把正文解析成 13 种块，`block_editor.dart` 每块一个 TextField（所以跨段操作靠整段框选）；预览仍用 AST。
- 编辑器（PEditor，1.64 起实验）：appflowy_editor 6.2.0 的 fork 在 `third_party/appflowy_editor`；`lib/notes/pe_markdown.dart` 做 Markdown⇄Document，`lib/ui/notes/pe_editor.dart` 做输入与 120 ms 防抖保存；设置项 `editor_kernel` 在 legacy / pe 之间切换，默认 legacy。

## 关键不变量

1. 值与其版本必须同事务写入（否则合并会读到「新值旧版本」）。
2. 版本的比较只有一处实现：`(hlc_ms, hlc_c, device_id)`。
3. 删除永不物理删除内容，除非用户确认「彻底删除」，而彻底删除也带版本、会传播。
4. 同步层不读系统时钟做排序依据，只信 HLC。
5. UI 不拼 SQL，SQL 只出现在 `data/`。
6. 笔记库永远可以被外部程序修改；`scan()` 用内容 sha 判断变化，而不是相信本地缓存。

## 目录导航

| 想知道 | 看 |
|---|---|
| 同步帧格式与合并规则 | [SYNC-PROTOCOL.md](SYNC-PROTOCOL.md) |
| 每个版本改了什么 | [CHANGELOG.md](CHANGELOG.md) |
| 待办 DAO | `lib/data/task_dao*.dart` |
| 笔记文件层 | `lib/notes/notes_store.dart`、`notes_sync.dart`、`notes_groups.dart` |
| 拖拽与长按手势 | `lib/ui/common/press_machine.dart` 与 `ui/*/*_list_body.dart` |
