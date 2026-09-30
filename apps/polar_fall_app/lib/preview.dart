import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

@Preview(name: 'Thẻ gia tốc', size: Size(360, 220))
Widget previewAcceleration() {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('X: 100   Y: 200   Z: 980\nĐơn vị: milli-g'),
          ),
        ),
      ),
    ),
  );
}