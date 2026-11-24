/// 笔记库位置的纯逻辑（1.42）：库跟着 exe 走，但不跟着 `pc\` 被覆盖。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pnote/notes/notes_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('笔记库放在哪', () {
    test('正式版目录：PNote_V2\\pc\\pnote.exe → PNote_V2\\PNote笔记库', () {
      final exe = p.join('D:', 'PNote_V2', 'pc', 'pnote.exe');
      expect(
        notesFolderForExecutable(exe),
        p.join('D:', 'PNote_V2', kNotesFolderName),
      );
    });

    test('不在 pc 里时（构建输出）就放 exe 旁边', () {
      final exe = p.join('D:', 'work', 'build', 'runner', 'Release', 'pnote.exe');
      expect(
        notesFolderForExecutable(exe),
        p.join('D:', 'work', 'build', 'runner', 'Release', kNotesFolderName),
      );
    });

    test('目录名大小写不影响判断', () {
      final exe = p.join('D:', 'PNote_V2', 'PC', 'pnote.exe');
      expect(
        notesFolderForExecutable(exe),
        p.join('D:', 'PNote_V2', kNotesFolderName),
      );
    });
  });

  group('交给系统的绝对路径（1.46.1）', () {
    // 库内相对路径统一存成 `2026/11/x.md`（见 NotesStore.list）；直接拼出来
    // 会得到 `…\2026/11/x.md`，explorer 的 /select, 会退回「桌面」。
    test('相对路径里的 / 要换成本机分隔符', () {
      // 用「本机绝对路径」当库根：以前写死 `D:\…`，在 Linux 的 CI 上
      // 那不是绝对路径，isAbsolute 断言就会挂（1.50.2）。
      final root = Directory(
        p.join(Directory.current.path, 'PNote_V2', kNotesFolderName),
      );
      final path = nativePathIn(root, '2026/11/2026-11-23 2334 125.md');
      expect(path.contains('/'), Platform.isWindows ? isFalse : anything);
      expect(path.contains('\\'), Platform.isWindows ? anything : isFalse);
      expect(path, endsWith('2026-11-23 2334 125.md'));
      expect(p.isAbsolute(path), isTrue);
      expect(p.normalize(path), path);
    });

    test('已经是本机分隔符时保持不变', () {
      final root = Directory(
        p.join(Directory.current.path, 'PNote_V2', kNotesFolderName),
      );
      final rel = p.join('2026', '11', 'a.md');
      expect(nativePathIn(root, rel), p.join(root.path, rel));
    });
  });
}
