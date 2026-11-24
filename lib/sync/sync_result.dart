/// 一次同步的结果，以及失败时的可读原因。
/// 原则：界面上永远只显示这里的中文短句，绝不把异常堆栈扔给用户。
library;

import 'package:pnote/sync/merge.dart';
import 'package:pnote/sync/notes_channel.dart';

enum SyncFailure {
  /// 服务没起来（端口全被占用、或 start 抛过错）。
  notStarted,

  /// 广播发出去了，但没有任何对端回应。
  noPeer,

  /// 发现了对端，但 TCP 连不上（防火墙、对方刚退出）。
  connectFailed,

  /// 连上了，但对方超时没回数据。
  timeout,

  /// 对方回的数据不是本协议的（版本不一致或数据损坏）。
  protocol,

  /// 本机数据库出错。
  localError,
}

class SyncResult {
  const SyncResult.success({
    required this.peerName,
    required this.stats,
    this.notes,
  })  : failure = null,
        detail = null;

  const SyncResult.failed(this.failure, {this.detail, this.peerName = ''})
      : stats = null,
        notes = null;

  bool get ok => failure == null;

  final SyncFailure? failure;
  final String? detail;
  final String peerName;
  final MergeStats? stats;

  /// 这一趟里笔记/附件的落盘统计（1.47 起）。没有笔记通道时为 null。
  final NotesApplyReport? notes;

  /// 给用户看的一句话。
  String get message {
    if (ok) {
      final s = stats!;
      final who = peerName.isEmpty ? '对端' : '「$peerName」';
      final extra = _notesSuffix(notes);
      return '已与$who 同步：$s$extra';
    }
    final extra = (detail == null || detail!.isEmpty) ? '' : '（$detail）';
    return switch (failure!) {
      SyncFailure.notStarted => '同步服务没启动：可能是端口被占用，重启 App 再试$extra',
      SyncFailure.noPeer => '没找到另一台设备：确认两台连的是同一个 Wi‑Fi、'
          '都开着 PNote，然后重新点一次「同步」$extra',
      SyncFailure.connectFailed =>
        '发现了设备但连不上：可能是防火墙拦住了，或对方刚关掉 App$extra',
      SyncFailure.timeout => '对方没有及时回复：网络可能很慢，稍后再试$extra',
      SyncFailure.protocol => '对方和你不是同一个版本，或数据损坏了$extra',
      SyncFailure.localError => '本机保存失败：请重启 App 再试$extra',
    };
  }

  /// 失败原因的极短说法，用在「另外 1 台没成功：连接超时」这种括号里。
  String get shortReason => switch (failure) {
        null => '',
        SyncFailure.notStarted => '同步服务没启动',
        SyncFailure.noPeer => '没找到设备',
        SyncFailure.connectFailed => '连不上',
        SyncFailure.timeout => '连接超时',
        SyncFailure.protocol => '版本不一致',
        SyncFailure.localError => '本机保存失败',
      };

  @override
  String toString() => 'SyncResult(ok=$ok, failure=$failure, peer=$peerName)';
}

/// 「· 笔记 写入 2 删除 1」这一截；没有变化时返回空串。
String _notesSuffix(NotesApplyReport? report) {
  if (report == null || report.isNoop) return '';
  final purge = report.purged > 0 ? ' 彻底删除 ${report.purged}' : '';
  return ' · 笔记 写入 ${report.written} 删除 ${report.deleted}$purge';
}

/// 一次「按下同步」的完整结果：可能同时和好几台设备交换过（1.14 起）。
///
/// 规则（对应项目说明 7.12）：一台设备按下同步，会依次和同一局域网里
/// **所有**被发现的设备交换状态；因为合并是幂等 + 交换律 + 结合律的，
/// 从任意一台按下都能收敛到同一个结果。
class SyncBatch {
  const SyncBatch(this.results);

  /// 只涉及一台设备（或直接失败）时用这个包一下。
  factory SyncBatch.single(SyncResult result) => SyncBatch([result]);

  const SyncBatch.empty() : results = const [];

  final List<SyncResult> results;

  List<SyncResult> get successes => [for (final r in results) if (r.ok) r];

  List<SyncResult> get failures => [for (final r in results) if (!r.ok) r];

  int get total => results.length;

  int get okCount => successes.length;

  bool get ok => results.isNotEmpty && failures.isEmpty;

  /// 所有成功设备的合并统计之和。
  MergeStats get stats => successes
      .map((r) => r.stats ?? const MergeStats())
      .fold(const MergeStats(), (a, b) => a + b);

  /// 所有成功设备的笔记统计之和（1.47）。
  NotesApplyReport get notes => successes
      .map((r) => r.notes ?? const NotesApplyReport())
      .fold(const NotesApplyReport(), (a, b) => a + b);

  /// 给用户看的一句话。
  String get message {
    if (results.isEmpty) return const SyncResult.failed(SyncFailure.noPeer).message;

    final done = successes;
    final bad = failures;

    // 一台都没成功：给出第一台的原因，并说明还有几台也没成。
    if (done.isEmpty) {
      final first = bad.first;
      final whose = first.peerName.isEmpty ? '' : '「${first.peerName}」';
      final extra = bad.length > 1 ? '（另外 ${bad.length - 1} 台也没成功）' : '';
      return '$whose${first.message}$extra';
    }

    final who = done.length == 1 ? '「${done.first.peerName}」' : ' ${done.length} 台设备';
    // 1.49：两边的提示说的是「各自收到了什么」，所以带上「本机」二字，
    // 免得用户看到两台数字不一样以为没同步上。
    final base = '本机已与$who同步：$stats${_notesSuffix(notes)}';
    if (bad.isEmpty) return base;

    final names =
        bad.map((r) => r.peerName.isEmpty ? '有一台' : '「${r.peerName}」').join('、');
    final reason = bad.first.shortReason;
    return '$base（$names没成功：$reason）';
  }

  @override
  String toString() => 'SyncBatch(total=$total, ok=$okCount)';
}
