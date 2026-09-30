class AccSample {
  const AccSample(this.timestamp, this.x, this.y, this.z);
  // Nanoseconds since 2000-01-01, string at the platform boundary.
  final String timestamp;
  final int x, y, z;

  factory AccSample.fromMap(Map<dynamic, dynamic> value) => AccSample(
    value['timestamp'] as String,
    (value['x'] as num).toInt(),
    (value['y'] as num).toInt(),
    (value['z'] as num).toInt(),
  );
}

/// Emits windows 1–200, 101–300, 201–400. Retains only the overlap.
class WindowBuffer {
  static const size = 200;
  static const step = 100;
  final _samples = <AccSample>[];

  List<AccSample>? add(AccSample sample) {
    _samples.add(sample);
    if (_samples.length < size) return null;
    final window = List<AccSample>.unmodifiable(_samples);
    _samples.removeRange(0, step);
    return window;
  }

  void reset() => _samples.clear();
}
