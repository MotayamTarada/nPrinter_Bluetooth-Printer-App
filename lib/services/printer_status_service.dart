import 'dart:io';

import 'package:flutter/services.dart';

class PrinterStatusCheck {
  const PrinterStatusCheck({
    required this.checked,
    required this.supported,
    required this.canPrint,
    required this.issues,
    required this.warnings,
  });

  const PrinterStatusCheck.skipped()
    : checked = false,
      supported = false,
      canPrint = true,
      issues = const <String>[],
      warnings = const <String>[];

  final bool checked;
  final bool supported;
  final bool canPrint;
  final List<String> issues;
  final List<String> warnings;

  bool get hasBlockingIssue => !canPrint;

  String get issueSummary {
    final labels = issues.map(_issueLabel).where((label) => label.isNotEmpty);
    return labels.isEmpty ? 'تعذر التأكد من جاهزية الطابعة' : labels.join('، ');
  }

  String get warningSummary {
    final labels = warnings.map(_warningLabel).where((label) => label.isNotEmpty);
    return labels.join('، ');
  }

  factory PrinterStatusCheck.fromNative(Map<dynamic, dynamic>? raw) {
    if (raw == null) {
      return const PrinterStatusCheck.skipped();
    }

    return PrinterStatusCheck(
      checked: raw['checked'] == true,
      supported: raw['supported'] == true,
      canPrint: raw['canPrint'] != false,
      issues: _stringList(raw['issues']),
      warnings: _stringList(raw['warnings']),
    );
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) {
      return const <String>[];
    }
    return value.map((entry) => entry.toString()).toList(growable: false);
  }

  static String _issueLabel(String code) {
    switch (code) {
      case 'invalid_mac':
        return 'عنوان MAC للطابعة غير صحيح';
      case 'adapter_unavailable':
        return 'البلوتوث غير متاح على الجهاز';
      case 'bluetooth_disabled':
        return 'البلوتوث مغلق';
      case 'permission_missing':
        return 'صلاحية الاتصال بالبلوتوث غير متاحة';
      case 'connect_failed':
        return 'تعذر الاتصال بالطابعة';
      case 'offline':
        return 'الطابعة غير جاهزة';
      case 'cover_open':
        return 'غطاء الطابعة مفتوح';
      case 'paper_stop':
        return 'الطابعة متوقفة بسبب الورق';
      case 'paper_end':
        return 'الورق مخلص أو حساس الورق لا يقرأ وجود ورق';
      case 'error':
        return 'الطابعة تبلغ عن خلل';
      case 'cutter_error':
        return 'يوجد خلل في القاطع';
      case 'unrecoverable_error':
        return 'يوجد خطأ داخلي في الطابعة';
      case 'auto_recoverable_error':
        return 'يوجد خلل مؤقت في الطابعة';
      default:
        return '';
    }
  }

  static String _warningLabel(String code) {
    switch (code) {
      case 'paper_near_end':
        return 'الورق على وشك النفاد';
      default:
        return '';
    }
  }
}

class PrinterStatusService {
  PrinterStatusService._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.nprinter_bluetooth_only/printer_status',
  );

  static Future<PrinterStatusCheck> checkEscPosStatus(String mac) async {
    if (!Platform.isAndroid) {
      return const PrinterStatusCheck.skipped();
    }

    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'checkEscPosStatus',
        <String, Object>{'mac': mac},
      );
      return PrinterStatusCheck.fromNative(raw);
    } on PlatformException {
      return const PrinterStatusCheck.skipped();
    }
  }
}
