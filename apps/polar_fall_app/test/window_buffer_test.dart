import 'package:flutter_test/flutter_test.dart';
import 'package:polar_fall_app/window_buffer.dart';

void main() {
  test('200 samples per window, 100 overlap, stable snapshots', () {
    final buffer = WindowBuffer();
    final windows = <List<AccSample>>[];
    for (var i = 1; i <= 400; i++) {
      final window = buffer.add(AccSample('$i', i, 0, 0));
      if (window != null) windows.add(window);
      if (i == 199) expect(windows, isEmpty);
      if (i == 200 || i == 299) expect(windows.length, 1);
    }
    expect(windows.map((w) => w.length), [200, 200, 200]);
    expect(windows.map((w) => w.first.x), [1, 101, 201]);
    expect(windows.map((w) => w.last.x), [200, 300, 400]);
  });
  test('reset prevents windows spanning disconnected sessions', () {
    final buffer = WindowBuffer();
    for (var i = 0; i < 150; i++) {
      buffer.add(AccSample('$i', -1, 0, 0));
    }
    buffer.reset();
    for (var i = 0; i < 199; i++) {
      expect(buffer.add(AccSample('$i', 1, 0, 0)), isNull);
    }
    final window = buffer.add(const AccSample('199', 1, 0, 0));
    expect(window!.every((sample) => sample.x == 1), isTrue);
  });
}
