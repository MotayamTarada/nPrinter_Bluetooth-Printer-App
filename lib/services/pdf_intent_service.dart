import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class IncomingPdfIntent {
  const IncomingPdfIntent({required this.path, required this.name});

  final String path;
  final String name;

  static IncomingPdfIntent? fromPlatformValue(Object? value) {
    if (value is! Map) {
      return null;
    }

    final path = value['path']?.toString().trim() ?? '';
    if (path.isEmpty) {
      return null;
    }

    final platformName = value['name']?.toString().trim() ?? '';
    return IncomingPdfIntent(
      path: path,
      name: platformName.isEmpty ? _fileNameFromPath(path) : platformName,
    );
  }

  static String _fileNameFromPath(String path) {
    final segments = path.split(RegExp(r'[\\/]'));
    final name = segments.isEmpty ? '' : segments.last.trim();
    return name.isEmpty ? 'PDF' : name;
  }
}

class PdfIntentService {
  PdfIntentService._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.nprinter_bluetooth_only/pdf_intent',
  );

  static ValueChanged<IncomingPdfIntent>? _listener;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static void setListener(ValueChanged<IncomingPdfIntent>? listener) {
    _listener = listener;

    if (!_isAndroid) {
      return;
    }

    if (listener == null) {
      _channel.setMethodCallHandler(null);
      return;
    }

    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static Future<IncomingPdfIntent?> consumeInitialPdf() async {
    if (!_isAndroid) {
      return null;
    }

    try {
      final value = await _channel.invokeMethod<Object?>('consumeInitialPdf');
      return IncomingPdfIntent.fromPlatformValue(value);
    } on MissingPluginException {
      return null;
    }
  }

  static Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'pdfOpened':
        final pdf = IncomingPdfIntent.fromPlatformValue(call.arguments);
        if (pdf != null) {
          _listener?.call(pdf);
          unawaited(_clearPendingPdf());
        }
        return null;
      default:
        throw MissingPluginException('No handler for ${call.method}');
    }
  }

  static Future<void> _clearPendingPdf() async {
    try {
      await _channel.invokeMethod<void>('clearPendingPdf');
    } on MissingPluginException {
      return;
    }
  }
}
