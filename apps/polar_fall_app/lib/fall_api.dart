import 'dart:convert';

import 'package:http/http.dart' as http;

import 'window_buffer.dart';

class FallPrediction {
  const FallPrediction(
    this.label,
    this.probability,
    this.threshold,
    this.lastTimestamp,
  );

  final String label;
  final double probability;
  final double threshold;
  final String lastTimestamp;

  bool get isFall => label == 'fall';

  factory FallPrediction.fromJson(Map<String, dynamic> json) => FallPrediction(
    json['label'] as String,
    (json['probability'] as num).toDouble(),
    (json['threshold'] as num).toDouble(),
    json['last_timestamp'] as String,
  );
}

class FallApi {
  FallApi({http.Client? client, String? url, String? key})
    : _client = client ?? http.Client(),
      _serverUrl = url ?? serverUrl,
      _apiKey = key ?? apiKey;

  static const serverUrl = String.fromEnvironment('FALL_API_URL');
  static const apiKey = String.fromEnvironment('FALL_API_KEY');
  static bool get isConfigured => serverUrl.isNotEmpty && apiKey.isNotEmpty;

  final http.Client _client;
  final String _serverUrl;
  final String _apiKey;

  Future<FallPrediction> predict(List<AccSample> window) async {
    if (_serverUrl.isEmpty || _apiKey.isEmpty) {
      throw StateError('Thiếu FALL_API_URL hoặc FALL_API_KEY');
    }
    if (window.length != WindowBuffer.size) {
      throw ArgumentError('Cần đúng ${WindowBuffer.size} mẫu');
    }
    final response = await _client
        .post(
          Uri.parse('$_serverUrl/predict'),
          headers: {'Content-Type': 'application/json', 'X-API-Key': _apiKey},
          body: jsonEncode({
            'samples': [
              for (final s in window)
                {'timestamp': s.timestamp, 'x': s.x, 'y': s.y, 'z': s.z},
            ],
          }),
        )
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.body}');
    }
    return FallPrediction.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  void close() => _client.close();
}
