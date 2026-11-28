import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/app_version.dart';

void main() {
  test('kAppVersion 与 pubspec.yaml 的 version 一致（防止漏改版本号）', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*([0-9][^+\s]*)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(match, isNotNull, reason: 'pubspec.yaml 里找不到 version: x.y.z+n');
    expect(kAppVersion, match!.group(1));
    expect(kAppBuildNumber, int.parse(match.group(2)!));
    expect(kAppVersionLabel, 'v${match.group(1)} (${match.group(2)})');
  });
}
