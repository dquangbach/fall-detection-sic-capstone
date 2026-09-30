import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:polar_fall_app/fall_api.dart';
import 'package:polar_fall_app/window_buffer.dart';

void main() {
  test(
    'sends exactly 200 Polar samples and parses the server result',
    () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), 'http://192.168.1.20:8000/predict');
        expect(request.headers['X-API-Key'], 'test-secret');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final samples = body['samples'] as List;
        expect(samples.length, 200);
        expect(samples.last, {
          'timestamp': '1990000000',
          'x': 1,
          'y': 2,
          'z': 3,
        });
        return http.Response(
          jsonEncode({
            'label': 'fall',
            'probability': 0.92,
            'threshold': 0.5,
            'last_timestamp': '1990000000',
          }),
          200,
        );
      });
      final api = FallApi(
        client: client,
        url: 'http://192.168.1.20:8000',
        key: 'test-secret',
      );
      addTearDown(api.close);
      final window = List.generate(
        200,
        (i) => AccSample('${i * 10000000}', 1, 2, 3),
      );
      final result = await api.predict(window);
      expect(result.isFall, isTrue);
      expect(result.probability, 0.92);
    },
  );
}
