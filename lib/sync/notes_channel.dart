/// 笔记在同步报文里的数据形状，以及「谁读谁写」的接口。
///
/// 笔记和任务不一样：任务在数据库里，每个字段各带一个版本；笔记是磁盘上
/// 的整份文件，所以「版本」只能按**文件**记 —— 一个路径一个 HLC，再加上
/// 内容的哈希，用来判断这台机器上的这份文件自上次同步后有没有动过。
///
/// 纯 Dart，不 import Flutter（和 merge.dart 同一条规矩）。
library;

import 'package:pnote/sync/hlc.dart';

/// 一篇文章或一个附件，连同它的版本与内容。内容是原始字节：
/// `.md` 是 UTF-8 文本，图片/PDF 是二进制，统一按 base64 走报文。
class NoteBlob {
  const NoteBlob({
    required this.path,
    required this.hlc,
    required this.sha,
    required this.bytes,
  });

  /// 相对笔记库根的路径，分隔符统一是 `/`（例如 `2026/11/x.md`、
  /// `2026/11/x.md.assets/图.png`）。跨平台存法见 notes_paths.dart。
  final String path;
  final Hlc hlc;

  /// 内容的指纹（见 notes_sync.dart 的 fnv1a64）。不参与胜负判定，
  /// 只用来判断「内容有没有变」，从而避免每次同步都重发整库。
  final String sha;
  final List<int> bytes;

  int get size => bytes.length;
}

/// 一个路径的版本 + 指纹。
class NoteVersion {
  const NoteVersion({
    required this.hlc,
    required this.sha,
    required this.size,
  });

  final Hlc hlc;
  final String sha;
  final int size;

  Map<String, Object?> toJson() => {
        'hlc': hlc.toJson(),
        'sha': sha,
        'size': size,
      };

  factory NoteVersion.fromJson(Map<String, Object?> json) {
    final hlc = json['hlc'];
    final sha = json['sha'];
    final size = json['size'];
    if (hlc is! Map || sha is! String || size is! int) {
      throw const FormatException('笔记版本记录不完整（需要 hlc/sha/size）');
    }
    return NoteVersion(
      hlc: Hlc.fromJson(Map<String, Object?>.from(hlc)),
      sha: sha,
      size: size,
    );
  }
}

/// 本机笔记库的同步元信息：每个文件一个版本，外加一组「删除墓碑」与
/// 一组「彻底删除记录」。
class NotesSyncState {
  const NotesSyncState({
    this.files = const {},
    this.deleted = const {},
    this.purged = const {},
  });

  final Map<String, NoteVersion> files;

  /// 路径 -> 删除发生时的版本。文件被删掉之后仍然要记着，
  /// 否则对端会把它当成「本机没有」而再推回来。
  final Map<String, Hlc> deleted;

  /// **文件名** -> 彻底删除（清空回收站）发生时的版本（1.49）。
  ///
  /// 为什么按文件名而不是路径：回收站里的文件已经不在原路径上了，
  /// 两端的 `.trash/<时间戳>/` 桶名也各不相同，只有「文件名」是两端都认得的
  /// 那把钥匙（文件名带创建时间，实际不会重名）。收到就两边一起抹掉：
  /// 正文、素材目录、以及对方回收站里的同名副本。
  final Map<String, Hlc> purged;

  bool get isEmpty => files.isEmpty && deleted.isEmpty && purged.isEmpty;

  /// 相对远端，本机需要拉取哪些路径。
  ///
  /// 规则（与任务同一套思路，取「版本大者胜」）：
  ///   - 远端有、本机没有版本 → 要；
  ///   - 远端版本更大 → 要（本机旧了）；
  ///   - 远端版本不更大 → 不要；
  ///   - 远端删除了它，且删除版本比本机版本大 → 本机也只是删，不用拉内容；
  ///   - 任一侧彻底删除过它（版本不比内容旧）→ 不要，别把删掉的又拉回来。
  List<String> wantFrom(NotesSyncState remote) {
    final wanted = <String>[];
    for (final entry in remote.files.entries) {
      final name = _nameOf(entry.key);
      final myPurge = purged[name];
      if (myPurge != null && !(myPurge < entry.value.hlc)) continue;
      final remotePurge = remote.purged[name];
      if (remotePurge != null && !(remotePurge < entry.value.hlc)) continue;

      final mine = files[entry.key];
      if (mine == null) {
        final tomb = deleted[entry.key];
        if (tomb != null && !(tomb < entry.value.hlc)) continue;
        wanted.add(entry.key);
        continue;
      }
      if (entry.value.hlc > mine.hlc) wanted.add(entry.key);
    }
    wanted.sort();
    return wanted;
  }

  /// 两侧出现过的最新版本（用于推进本机时钟）。
  Hlc? get maxHlc {
    Hlc? best;
    for (final v in files.values) {
      if (best == null || v.hlc > best) best = v.hlc;
    }
    for (final v in deleted.values) {
      if (best == null || v > best) best = v;
    }
    for (final v in purged.values) {
      if (best == null || v > best) best = v;
    }
    return best;
  }
}

/// 路径 → 文件名。同步用的路径一律是 `/` 分隔。
String _nameOf(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

/// 一次应用远端笔记的结果，用来在界面上说「笔记 2 篇 + 附件 1 个」。
class NotesApplyReport {
  const NotesApplyReport({
    this.written = 0,
    this.deleted = 0,
    this.purged = 0,
    this.skippedLarge = 0,
    this.skippedOld = 0,
  });

  final int written;
  final int deleted;

  /// 因为对端清空了回收站而被一起抹掉的篇数（1.49）。
  final int purged;
  final int skippedLarge;
  final int skippedOld;

  bool get isNoop => written == 0 && deleted == 0 && purged == 0;

  NotesApplyReport operator +(NotesApplyReport o) => NotesApplyReport(
        written: written + o.written,
        deleted: deleted + o.deleted,
        purged: purged + o.purged,
        skippedLarge: skippedLarge + o.skippedLarge,
        skippedOld: skippedOld + o.skippedOld,
      );

  @override
  String toString() => '写入 $written · 删除 $deleted · 彻底删除 $purged · '
      '跳过（过大）$skippedLarge';
}

/// 传输层只认识这四件事，具体怎么读写文件由 notes_sync.dart 实现。
///
/// [describe] 取本机元信息；[read] 读若干路径的字节；[apply] 落远端元信息
/// 与内容；[persistClock] 把推进过的时钟写回数据库（和任务共用同一个 HLC）。
class NotesChannel {
  const NotesChannel({
    required this.describe,
    required this.read,
    required this.apply,
    required this.persistClock,
  });

  final Future<NotesSyncState> Function() describe;
  final Future<List<NoteBlob>> Function(List<String> paths) read;
  final Future<NotesApplyReport> Function(
          NotesSyncState remote, List<NoteBlob> blobs)
      apply;
  final Future<void> Function() persistClock;
}
