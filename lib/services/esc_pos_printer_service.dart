import 'dart:async';
import 'dart:typed_data';

import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'esc_pos_colored_text_service.dart';

/// خدمة متخصصة لطباعة ESC/POS عبر Bluetooth
/// تدعم:
/// - طباعة النصوص العادية (أسود / أحمر / أسود + أحمر)
/// - إرسال البيانات آمناً عبر chunks
/// - معالجة الأخطاء الواضحة
/// - اختبار الألوان
class EscPosPrinterService {
  static const int _defaultChunkSize = 128;
  static const int _defaultDelayMs = 80;

  /// التحقق من اتصال الطابعة
  static Future<bool> isPrinterConnected() async {
    try {
      final connected = await PrintBluetoothThermal.connectionStatus;
      return connected ?? false;
    } catch (_) {
      return false;
    }
  }

  /// إرسال bytes للطابعة بشكل آمن عبر chunks
  ///
  /// ترسل البيانات على دفعات صغيرة لتجنب فقدان البيانات
  /// وضمان استقرار الاتصال
  static Future<bool> sendBytesToPrinter(
    Uint8List data, {
    int chunkSize = _defaultChunkSize,
    int delayMs = _defaultDelayMs,
  }) async {
    try {
      if (data.isEmpty) {
        return true;
      }

      final isConnected = await isPrinterConnected();
      if (!isConnected) {
        throw Exception('الطابعة غير متصلة. تأكد من اتصال Bluetooth.');
      }

      for (int i = 0; i < data.length; i += chunkSize) {
        final end = (i + chunkSize < data.length) ? i + chunkSize : data.length;
        final chunk = data.sublist(i, end);

        final sent = await PrintBluetoothThermal.writeBytes(chunk);
        if (!sent) {
          return false;
        }

        // تأخير بين الأجزاء
        if (end < data.length) {
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      }

      return true;
    } catch (e) {
      print('خطأ في إرسال البيانات: $e');
      return false;
    }
  }

  /// طباعة نص عادي بلون واحد
  ///
  /// - `text`: النص المراد طباعته
  /// - `mode`: وضع اللون (أسود / أحمر / أسود + أحمر)
  /// - `encoding`: ترميز النص (يفضل windows-1256 للعربية)
  /// - `useAlternativeRedCommand`: استخدام أمر بديل للأحمر
  static Future<bool> printPlainText({
    required String text,
    required PrintColorMode mode,
    EscPosTextEncoding encoding = EscPosTextEncoding.windows1256,
    bool useAlternativeRedCommand = false,
  }) async {
    try {
      if (text.isEmpty) {
        return false;
      }

      final bytes = await buildPlainTextEscPosBytes(
        text: text,
        mode: mode,
        encoding: encoding,
        useAlternativeRedCommand: useAlternativeRedCommand,
        feedLines: 3,
      );

      return sendBytesToPrinter(bytes);
    } catch (e) {
      print('خطأ في طباعة النص: $e');
      return false;
    }
  }

  /// طباعة نصوص مختلطة (أسود + أحمر)
  ///
  /// كل جزء يمكن أن يكون بلون مختلف
  static Future<bool> printMixedText({
    required List<PrintPart> parts,
    EscPosTextEncoding encoding = EscPosTextEncoding.windows1256,
    bool useAlternativeRedCommand = false,
  }) async {
    try {
      if (parts.isEmpty) {
        return false;
      }

      final bytes = await buildMixedTextEscPosBytes(
        parts: parts,
        encoding: encoding,
        useAlternativeRedCommand: useAlternativeRedCommand,
        feedLines: 3,
      );

      return sendBytesToPrinter(bytes);
    } catch (e) {
      print('خطأ في طباعة النصوص المختلطة: $e');
      return false;
    }
  }

  /// اختبار الألوان - طباعة عينة من النصوص بألوان مختلفة
  static Future<bool> printColorTest({
    EscPosTextEncoding encoding = EscPosTextEncoding.windows1256,
    bool useAlternativeRedCommand = false,
  }) async {
    try {
      final bytes = await buildColorTestBytes(
        encoding: encoding,
        useAlternativeRedCommand: useAlternativeRedCommand,
      );

      return sendBytesToPrinter(bytes);
    } catch (e) {
      print('خطأ في اختبار الألوان: $e');
      return false;
    }
  }

  /// اختبار الألوان الموسع (test advanced)
  static Future<bool> printAdvancedColorTest({
    EscPosTextEncoding encoding = EscPosTextEncoding.windows1256,
    bool useAlternativeRedCommand = false,
  }) async {
    try {
      final bytes = await buildColoredEscPosTestBytes(
        encoding: encoding,
        useAlternativeRedCommand: useAlternativeRedCommand,
      );

      return sendBytesToPrinter(bytes);
    } catch (e) {
      print('خطأ في الاختبار الموسع: $e');
      return false;
    }
  }

  /// الحصول على رسالة خطأ واضحة بناءً على نوع الفشل
  static String getErrorMessageForContext({
    required String context,
    String? additionalInfo,
  }) {
    final messages = <String, String>{
      'plain_text_empty': 'الرجاء إدخال نص للطباعة.',
      'mixed_text_empty': 'لا توجد نصوص مختلطة للطباعة.',
      'not_connected':
          'الطابعة غير متصلة. تأكد من:'
          '\n- تشغيل الطابعة'
          '\n- الاقتران عبر Bluetooth'
          '\n- وجود ورق'
          '\n- إغلاق الغطاء',
      'send_failed_chunk':
          'فشل إرسال جزء من البيانات للطابعة.'
          '\nتحقق من:'
          '\n- استقرار اتصال Bluetooth'
          '\n- وجود ورق في الطابعة'
          '\n- عدم انقطاع الاتصال',
      'red_not_supported_text':
          'الطابعة قد لا تدعم اللون الأحمر للنصوص.'
          '\nتأكد من:'
          '\n- استخدام ورق أسود/أحمر'
          '\n- دعم الطابعة لأوامر ESC/POS الحمراء',
      'red_not_supported_image':
          'الطابعة تدعم الأحمر للنصوص فقط.'
          '\nطباعة الصور بالأحمر قد لا تعمل.',
    };

    return messages[context] ?? 'حدث خطأ في الطباعة. $additionalInfo';
  }
}
