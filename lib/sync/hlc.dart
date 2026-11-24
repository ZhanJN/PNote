/// 混合逻辑时钟（Hybrid Logical Clock）。
///
/// 规则见《PNote项目说明》7.2。本文件是纯 Dart，不 import Flutter，
/// 因此可以被 `flutter test` 直接跑（不依赖界面、不依赖 Windows 编译器）。
///
/// 为什么不用设备墙钟：
///   手机/电脑的时间都可以被用户手动修改；两台设备的时钟也会互相漂移。
///   直接用时间戳比较，会出现「昨天改的内容覆盖今天改的内容」这种不可解释现象。
///   HLC 在物理毫秒之外再带一个逻辑计数器，保证「因果关系」上的先后不被颠倒。
library;

class Hlc implements Comparable<Hlc> {
  const Hlc(this.ms, this.c, this.deviceId);

  /// 物理毫秒（取自本机时钟，但只作为 HLC 的一个分量，不单独使用）。
  final int ms;

  /// 逻辑计数器：同一毫秒内发生的第几次事件。
  final int c;

  /// 产生这个版本的设备 ID。它是三元组的最后一位，用于打破完全平局。
  final String deviceId;

  /// 全序比较：先比毫秒，再比计数器，最后比设备 ID。
  /// 任何两个 Hlc 都能分出大小，且比较结果与比较顺序无关（反对称、传递）。
  @override
  int compareTo(Hlc other) {
    if (ms != other.ms) return ms < other.ms ? -1 : 1;
    if (c != other.c) return c < other.c ? -1 : 1;
    return deviceId.compareTo(other.deviceId);
  }

  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator <(Hlc other) => compareTo(other) < 0;

  Map<String, Object?> toJson() => {'ms': ms, 'c': c, 'dev': deviceId};

  factory Hlc.fromJson(Map<String, Object?> json) {
    final ms = json['ms'];
    final c = json['c'];
    final dev = json['dev'];
    if (ms is! int || c is! int || dev is! String) {
      throw const FormatException('HLC 字段缺失或类型错误（需要 ms:int, c:int, dev:String）');
    }
    return Hlc(ms, c, dev);
  }

  @override
  String toString() => '$ms.$c@$deviceId';

  @override
  bool operator ==(Object other) =>
      other is Hlc && other.ms == ms && other.c == c && other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(ms, c, deviceId);
}

/// 时钟本体。它只在内存里推进，**持久化由 DAO 在同一事务里完成**
/// （这样「写入字段」和「记住时钟」不可能只成功一半）。
class HlcClock {
  HlcClock({
    required this.deviceId,
    int lastMs = 0,
    int lastC = 0,
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now()) {
    _lastMs = lastMs;
    _lastC = lastC;
  }

  final String deviceId;
  final DateTime Function() _now;

  int _lastMs = 0;
  int _lastC = 0;

  /// 当前状态。DAO 用它把时钟写进 meta 表。
  int get lastMs => _lastMs;
  int get lastC => _lastC;

  /// 本地发生了一次修改：生成严格大于此前所有本地版本的 HLC。
  Hlc send() {
    final now = _now().millisecondsSinceEpoch;
    if (now > _lastMs) {
      _lastMs = now;
      _lastC = 0;
    } else {
      // 本机时钟没走（或往回跳了）：靠逻辑计数器保证单调递增。
      _lastC += 1;
    }
    return Hlc(_lastMs, _lastC, deviceId);
  }

  /// 收到远端 HLC 后推进本机时钟，保证此后本机产生的事件「大于远端」。
  /// 这就是 HLC 的 receive 分支，见《PNote项目说明》7.2 的公式。
  void receive(Hlc remote) {
    final now = _now().millisecondsSinceEpoch;
    final maxMs = now > _lastMs
        ? (now > remote.ms ? now : remote.ms)
        : (_lastMs > remote.ms ? _lastMs : remote.ms);

    if (maxMs == _lastMs && maxMs == remote.ms) {
      _lastC = (_lastC > remote.c ? _lastC : remote.c) + 1;
    } else if (maxMs == _lastMs) {
      _lastC += 1;
    } else if (maxMs == remote.ms) {
      _lastC = remote.c + 1;
    } else {
      _lastC = 0;
    }
    _lastMs = maxMs;
  }
}
