/// 笔记界面用到的几个纯格式化函数（1.41）。放在这里是为了能单测。
library;

/// `1234` → `1.2 KB`。
String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

/// `刚刚` / `12 分钟前` / `3 小时前` / `昨天` / `11-20` / `2025-03-04`。
String formatRelative(DateTime time, DateTime now) {
  final diff = now.difference(time);
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24 && now.day == time.day) return '${diff.inHours} 小时前';
  final yesterday = DateTime(now.year, now.month, now.day)
      .subtract(const Duration(days: 1));
  if (time.year == yesterday.year &&
      time.month == yesterday.month &&
      time.day == yesterday.day) {
    return '昨天';
  }
  String two(int v) => v.toString().padLeft(2, '0');
  if (time.year == now.year) return '${two(time.month)}-${two(time.day)}';
  return '${time.year}-${two(time.month)}-${two(time.day)}';
}

/// 列表里的年月分组标题：`2026 年 11 月`。
String formatMonthHeader(DateTime time) => '${time.year} 年 ${time.month} 月';
