import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widget_previews.dart';

import 'fall_api.dart';
import 'window_buffer.dart';

void main() => runApp(const PolarFallApp());

enum PolarPreviewState { devices, streaming }

@Preview(name: 'Polar · Quét thiết bị', size: Size(390, 844))
Widget previewPolarDevices() =>
    const PolarFallApp(previewState: PolarPreviewState.devices);

@Preview(name: 'Polar · Đang đọc ACC', size: Size(390, 844))
Widget previewPolarStreaming() =>
    const PolarFallApp(previewState: PolarPreviewState.streaming);

class PolarFallApp extends StatelessWidget {
  const PolarFallApp({super.key, this.previewState});
  final PolarPreviewState? previewState;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Polar Fall Detection',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: const Color(0xff087f8c)),
    home: PolarPage(previewState: previewState),
  );
}

class PolarPage extends StatefulWidget {
  const PolarPage({super.key, this.previewState});
  final PolarPreviewState? previewState;
  @override
  State<PolarPage> createState() => _PolarPageState();
}

class _PolarPageState extends State<PolarPage> {
  static const _methods = MethodChannel('polar_fall/methods');
  static const _events = EventChannel('polar_fall/events');
  final _devices = <String, Map<Object?, Object?>>{};
  final _buffer = WindowBuffer();
  FallApi? _fallApi;
  StreamSubscription<dynamic>? _subscription;
  bool _bluetooth = false, _scanning = false, _ready = false;
  bool _streaming = false, _busy = false;
  String? _streamKind;
  String? _deviceId, _error;
  String _status = 'Chưa kết nối';
  int _rate = 0, _total = 0, _windows = 0;
  int _ecgRate = 0, _ecgTotal = 0;
  int? _latestVoltageUv;
  String? _ecgFileName;
  final _ecgWave = <int>[];
  AccSample? _latest;
  FallPrediction? _prediction;
  String? _predictionError;
  List<AccSample>? _pendingWindow;
  bool _sendingPrediction = false;
  int _session = 0;

  void _endPredictionSession() {
    _session++;
    _pendingWindow = null;
    _prediction = null;
    _predictionError = null;
  }

  void _queuePrediction(List<AccSample> window) {
    if (widget.previewState != null || !FallApi.isConfigured) return;
    if (_rate != 100) {
      _predictionError = 'Model cần 100 Hz; cảm biến đang chạy $_rate Hz.';
      return;
    }
    // Keep the newest window when inference/network is slower than the stream.
    _pendingWindow = window;
    if (!_sendingPrediction) unawaited(_drainPredictions());
  }

  Future<void> _drainPredictions() async {
    _sendingPrediction = true;
    try {
      while (_pendingWindow != null) {
        final window = _pendingWindow!;
        final requestSession = _session;
        _pendingWindow = null;
        try {
          final result = await _fallApi!.predict(window);
          if (mounted && requestSession == _session) {
            setState(() {
              _prediction = result;
              _predictionError = null;
            });
          }
        } catch (error) {
          if (mounted && requestSession == _session) {
            setState(() {
              _prediction = null;
              _predictionError = 'Không dự đoán được: $error';
            });
          }
        }
      }
    } finally {
      _sendingPrediction = false;
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.previewState != null) {
      _bluetooth = true;
      _addPreviewDevice();
      if (widget.previewState == PolarPreviewState.streaming) {
        _deviceId = 'DEMO1234';
        _ready = true;
        _status = 'Sẵn sàng đọc ACC/ECG';
        _previewAcc();
      }
      return; // Preview never subscribes to the native Bluetooth channel.
    }
    _fallApi = FallApi();
    _subscription = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error) {
        if (mounted) setState(() => _error = error.toString());
      },
    );
  }

  void _addPreviewDevice() {
    _devices['DEMO1234'] = {
      'id': 'DEMO1234',
      'name': 'Polar H10 (mẫu)',
      'rssi': -48,
      'connectable': true,
    };
  }

  void _previewAcc() {
    _onEvent({
      'type': 'stream',
      'state': 'started',
      'kind': 'acc',
      'sampleRate': 100,
    });
    _onEvent({
      'type': 'acc',
      'samples': List.generate(
        400,
        (i) => {'timestamp': '${i * 10000000}', 'x': 120, 'y': -80, 'z': 980},
      ),
    });
  }

  void _previewCommand(String name, Map<String, Object>? arguments) {
    switch (name) {
      case 'scan':
        setState(_addPreviewDevice);
      case 'connect':
        _onEvent({
          'type': 'connection',
          'state': 'connected',
          'id': arguments!['id'],
        });
        _onEvent({'type': 'ready'});
      case 'disconnect':
        _onEvent({'type': 'connection', 'state': 'disconnected'});
      case 'startAcc':
        _previewAcc();
      case 'stopAcc':
        _onEvent({'type': 'stream', 'state': 'stopped', 'kind': 'acc'});
      case 'startEcg':
        _onEvent({
          'type': 'stream',
          'state': 'started',
          'kind': 'ecg',
          'sampleRate': 130,
          'fileName': 'preview.csv',
        });
        _onEvent({
          'type': 'ecg',
          'samples': List.generate(
            260,
            (i) => {
              'timestamp': '${i * 7692308}',
              'voltageUv': i % 130 == 10
                  ? 1100
                  : (i % 130 == 12 ? -320 : ((i % 40) - 20) * 3),
            },
          ),
        });
      case 'stopEcg':
        _onEvent({'type': 'stream', 'state': 'stopped', 'kind': 'ecg'});
      case 'stopScan':
        break;
    }
  }

  void _onEvent(dynamic raw) {
    if (!mounted) return;
    final event = Map<Object?, Object?>.from(raw as Map);
    setState(() {
      switch (event['type']) {
        case 'bluetooth':
          _bluetooth = event['enabled'] == true;
          if (!_bluetooth) {
            _endPredictionSession();
            _ready = false;
            _scanning = false;
            _streaming = false;
            _streamKind = null;
            _buffer.reset();
          }
        case 'device':
          _devices[event['id'] as String] = event;
        case 'connection':
          final state = event['state'];
          _status = switch (state) {
            'connected' => 'Đã kết nối · chờ SDK sẵn sàng',
            'connecting' => 'Đang kết nối',
            'reconnecting' => 'Mất kết nối · đang thử lại',
            _ => 'Chưa kết nối',
          };
          _deviceId = event['id'] as String?;
          _scanning = false;
          if (state != 'connected') {
            _endPredictionSession();
            _ready = false;
            _streaming = false;
            _streamKind = null;
            _buffer.reset();
          }
        case 'ready':
          _ready = true;
          _status = 'Sẵn sàng đọc ACC/ECG';
        case 'stream':
          _streaming = event['state'] == 'started';
          _streamKind = _streaming ? event['kind'] as String? : null;
          _endPredictionSession();
          _buffer.reset();
          if (_streaming) {
            if (_streamKind == 'ecg') {
              _ecgRate = (event['sampleRate'] as num).toInt();
              _ecgTotal = 0;
              _latestVoltageUv = null;
              _ecgWave.clear();
              _ecgFileName = event['fileName'] as String?;
            } else {
              _rate = (event['sampleRate'] as num).toInt();
              _total = 0;
              _windows = 0;
              _latest = null;
            }
          } else if (event['kind'] == 'ecg' && event['fileName'] != null) {
            _ecgFileName = event['fileName'] as String?;
          }
        case 'acc':
          if (!_streaming || _streamKind != 'acc') return;
          for (final rawSample in event['samples'] as List) {
            final sample = AccSample.fromMap(rawSample as Map);
            _latest = sample;
            _total++;
            final window = _buffer.add(sample);
            if (window != null) {
              _windows++;
              _queuePrediction(window);
            }
          }
        case 'ecg':
          if (!_streaming || _streamKind != 'ecg') return;
          for (final rawSample in event['samples'] as List) {
            final sample = Map<Object?, Object?>.from(rawSample as Map);
            final voltage = (sample['voltageUv'] as num).toInt();
            _latestVoltageUv = voltage;
            _ecgTotal++;
            _ecgWave.add(voltage);
          }
          if (_ecgWave.length > 650) {
            _ecgWave.removeRange(0, _ecgWave.length - 650);
          }
        case 'error':
          _error = event['message'] as String?;
      }
    });
  }

  Future<void> _command(String name, [Map<String, Object>? arguments]) async {
    if (widget.previewState != null) {
      _previewCommand(name, arguments);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _methods.invokeMethod<void>(name, arguments);
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? error.code);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleScan() async {
    final starting = !_scanning;
    if (starting) setState(_devices.clear);
    await _command(starting ? 'scan' : 'stopScan');
    if (mounted && _error == null) setState(() => _scanning = starting);
  }

  @override
  void dispose() {
    _subscription?.cancel(); // Native onCancel stops tasks and disconnects.
    _fallApi?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Polar Fall Detection')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (widget.previewState != null)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text('PREVIEW · Dữ liệu mẫu, không kết nối Bluetooth'),
            ),
          Text(
            'Kết nối cảm biến',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Bluetooth: ${_bluetooth ? "đang bật" : "tắt hoặc chưa cấp quyền"}',
          ),
          Text('$_status${_deviceId == null ? "" : " · $_deviceId"}'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: !_busy && _bluetooth && _deviceId == null
                    ? _toggleScan
                    : null,
                icon: Icon(_scanning ? Icons.stop : Icons.bluetooth_searching),
                label: Text(_scanning ? 'Dừng quét' : 'Quét Polar'),
              ),
              OutlinedButton(
                onPressed: !_busy && _deviceId != null
                    ? () => _command('disconnect')
                    : null,
                child: const Text('Ngắt kết nối'),
              ),
            ],
          ),
          if (_deviceId == null)
            for (final device in _devices.values)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(device['name'] as String),
                subtitle: Text('${device["id"]} · ${device["rssi"]} dBm'),
                trailing: const Icon(Icons.chevron_right),
                onTap: !_busy && device['connectable'] == true
                    ? () => _command('connect', {'id': device['id'] as String})
                    : null,
              ),
          if (_scanning && _devices.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('Đang tìm… Hãy bật/đeo Polar và đặt gần iPhone.'),
            ),
          const Divider(height: 32),
          Text(
            'Gia tốc từ Polar',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const Text('Đơn vị: milli-g · có trọng lực'),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'X: ${_latest?.x ?? "—"}   Y: ${_latest?.y ?? "—"}   Z: ${_latest?.z ?? "—"}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text('Tần số SDK: ${_rate == 0 ? "—" : "$_rate Hz"}'),
                  Text('Tổng mẫu phiên này: $_total'),
                  Text('Window: 200 · Step: 100 · Đã tạo: $_windows cửa sổ'),
                  if (_rate > 0)
                    Text(
                      'Mỗi cửa sổ ${(200 / _rate).toStringAsFixed(2)} s · bước ${(100 / _rate).toStringAsFixed(2)} s',
                    ),
                ],
              ),
            ),
          ),
          FilledButton(
            onPressed:
                !_busy && (_streamKind == 'acc' || (!_streaming && _ready))
                ? () => _command(_streaming ? 'stopAcc' : 'startAcc')
                : null,
            child: Text(_streamKind == 'acc' ? 'Dừng ACC' : 'Bắt đầu ACC'),
          ),
          const Divider(height: 32),
          Text(
            'ECG từ Polar',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const Text('Một kênh · điện thế µV · tần số lấy từ SDK'),
          const Text('Thu ECG không cần server; chưa dùng model ECG.'),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Tần số: ${_ecgRate == 0 ? "—" : "$_ecgRate Hz"} · Tổng mẫu: $_ecgTotal',
                  ),
                  Text(
                    'Điện thế mới nhất: ${_latestVoltageUv?.toString() ?? "—"} µV',
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 120,
                    width: double.infinity,
                    child: CustomPaint(painter: _EcgPainter(_ecgWave)),
                  ),
                  if (_ecgFileName != null)
                    SelectableText(
                      'CSV trong Files → Polar Fall App: $_ecgFileName',
                    ),
                ],
              ),
            ),
          ),
          FilledButton(
            onPressed:
                !_busy && (_streamKind == 'ecg' || (!_streaming && _ready))
                ? () => _command(_streamKind == 'ecg' ? 'stopEcg' : 'startEcg')
                : null,
            child: Text(
              _streamKind == 'ecg' ? 'Dừng ECG' : 'Bắt đầu ECG & lưu CSV',
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          const SizedBox(height: 12),
          Text(
            'Dự đoán từ laptop',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (_streamKind == 'ecg')
            const Text(
              'ECG đang được thu và lưu; chưa chạy bộ phân loại AF trên H10.',
            )
          else if (widget.previewState != null)
            const Text('Preview dùng dữ liệu mẫu; không gọi server.')
          else if (!FallApi.isConfigured)
            const Text(
              'Chưa cấu hình FALL_API_URL và FALL_API_KEY khi chạy app.',
            )
          else if (_prediction != null) ...[
            Text(
              _prediction!.isFall ? 'NGHI NGỜ TÉ NGÃ' : 'Bình thường',
              style: TextStyle(
                color: _prediction!.isFall
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
            Text(
              'P(ngã): ${(_prediction!.probability * 100).toStringAsFixed(1)}% '
              '· ngưỡng ${(_prediction!.threshold * 100).toStringAsFixed(0)}%',
            ),
          ] else
            const Text('Đang chờ đủ 200 mẫu và phản hồi từ laptop.'),
          if (_predictionError != null)
            SelectableText(
              _predictionError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: SelectableText(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 20),
          const Text(
            'ACC chỉ giữ trong bộ nhớ. ECG được lưu thành CSV trên iPhone.',
          ),
        ],
      ),
    ),
  );
}

class _EcgPainter extends CustomPainter {
  const _EcgPainter(this.samples);
  final List<int> samples;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.height / 2;
    final axis = Paint()
      ..color = const Color(0xffd0dfe1)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, center), Offset(size.width, center), axis);
    if (samples.length < 2) return;
    var peak = 200;
    for (final value in samples) {
      if (value.abs() > peak) peak = value.abs();
    }
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = i * size.width / (samples.length - 1);
      final y = center - samples[i] * (size.height * 0.45 / peak);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xff087f8c)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _EcgPainter oldDelegate) => true;
}
