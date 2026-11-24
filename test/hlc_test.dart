import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/sync/hlc.dart';

void main() {
  group('Hlc 比较（INV-03）', () {
    test('先比毫秒', () {
      expect(const Hlc(1000, 0, 'A') > const Hlc(999, 5, 'Z'), isTrue);
    });

    test('毫秒相同则比计数器', () {
      expect(const Hlc(1000, 1, 'A') > const Hlc(1000, 0, 'Z'), isTrue);
    });

    test('完全相同则比设备 ID，保证全序', () {
      expect(const Hlc(1000, 0, 'B') > const Hlc(1000, 0, 'A'), isTrue);
      expect(const Hlc(1000, 0, 'A') < const Hlc(1000, 0, 'B'), isTrue);
    });

    test('比较结果与顺序无关（反对称）', () {
      const a = Hlc(5, 2, 'x');
      const b = Hlc(5, 2, 'y');
      expect(a.compareTo(b), -b.compareTo(a));
      expect(a.compareTo(a), 0);
    });
  });

  group('HlcClock', () {
    test('send 严格递增（即使时钟停住）', () {
      final fixed = DateTime.fromMillisecondsSinceEpoch(1000);
      final clock = HlcClock(deviceId: 'A', now: () => fixed);
      final h1 = clock.send();
      final h2 = clock.send();
      expect(h1.ms, 1000);
      expect(h2 > h1, isTrue);
      expect(h2.c, h1.c + 1);
    });

    test('时钟前进时计数器归零', () {
      var t = 1000;
      final clock = HlcClock(deviceId: 'A', now: () => DateTime.fromMillisecondsSinceEpoch(t));
      clock.send();
      t = 2000;
      final h = clock.send();
      expect(h.ms, 2000);
      expect(h.c, 0);
    });

    test('receive 后本机新事件大于远端', () {
      var t = 500;
      final clock = HlcClock(deviceId: 'A', now: () => DateTime.fromMillisecondsSinceEpoch(t));
      const remote = Hlc(9000, 3, 'B');
      clock.receive(remote);
      final next = clock.send();
      expect(next > remote, isTrue);
    });

    test('receive 不倒退：本地更晚时继续用自己的毫秒', () {
      var t = 10000;
      final clock = HlcClock(deviceId: 'A', now: () => DateTime.fromMillisecondsSinceEpoch(t));
      clock.send();
      clock.receive(const Hlc(5000, 0, 'B'));
      final next = clock.send();
      expect(next.ms, 10000);
      expect(next > const Hlc(10000, 0, 'A'), isTrue);
    });
  });

  group('Hlc JSON', () {
    test('往返一致', () {
      const h = Hlc(123, 4, 'dev-1');
      final back = Hlc.fromJson(h.toJson());
      expect(back, h);
    });

    test('缺字段抛异常', () {
      expect(() => Hlc.fromJson({'ms': 1}), throwsFormatException);
    });
  });
}
