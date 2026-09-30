import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:polar_fall_app/main.dart';

void main() {
  testWidgets(
    'preview supports the flow without calling native Polar channels',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final name in ['polar_fall/methods', 'polar_fall/events']) {
        messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
          calls.add('$name/${call.method}');
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(MethodChannel(name), null),
        );
      }

      await tester.pumpWidget(previewPolarDevices());
      await tester.tap(find.text('Quét Polar'));
      await tester.pump();
      await tester.tap(find.text('Polar H10 (mẫu)'));
      await tester.pump();
      await tester.ensureVisible(find.text('Bắt đầu ACC'));
      await tester.tap(find.text('Bắt đầu ACC'));
      await tester.pump();
      expect(
        find.text('Window: 200 · Step: 100 · Đã tạo: 3 cửa sổ'),
        findsOneWidget,
      );
      await tester.tap(find.text('Dừng ACC'));
      await tester.pump();
      await tester.ensureVisible(find.text('Ngắt kết nối'));
      await tester.tap(find.text('Ngắt kết nối'));
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, 1000));
      await tester.pumpAndSettle();
      expect(find.text('Chưa kết nối'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(previewPolarStreaming());
      expect(find.text('Tổng mẫu phiên này: 400'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(calls, isEmpty);
    },
  );
}
