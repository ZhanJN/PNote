import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pnote/ui/common/horizontal_chip_bar.dart';

Widget _host({int chips = 20, double width = 220}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: HorizontalChipBar(
            height: 40,
            children: [
              for (var i = 0; i < chips; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Chip(label: Text('分组$i')),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

double _offset(WidgetTester tester) {
  final state = tester.state<ScrollableState>(find.byType(Scrollable));
  return state.position.pixels;
}

void main() {
  testWidgets('鼠标滚轮向下滚，横向条跟着往右滚', (tester) async {
    await tester.pumpWidget(_host());
    expect(_offset(tester), 0);

    final center = tester.getCenter(find.byType(HorizontalChipBar));
    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: center,
        scrollDelta: const Offset(0, 80),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pump();

    expect(_offset(tester), greaterThan(0));
  });

  testWidgets('鼠标可以拖动横向条', (tester) async {
    await tester.pumpWidget(_host());
    expect(_offset(tester), 0);

    await tester.drag(
      find.byType(ListView),
      const Offset(-120, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(_offset(tester), greaterThan(0));
  });

  testWidgets('内容放得下时滚轮不会动（把滚轮留给页面）', (tester) async {
    await tester.pumpWidget(_host(chips: 1, width: 400));

    final center = tester.getCenter(find.byType(HorizontalChipBar));
    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: center,
        scrollDelta: const Offset(0, 80),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pump();

    expect(_offset(tester), 0);
  });
}
