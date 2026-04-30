/// اختبار شامل لنظام الطباعة ESC/POS
///
/// هذا الملف يحتوي على اختبارات للتحقق من أن جميع مسارات الطباعة تعمل بشكل صحيح
///
/// متطلبات الاختبار:
/// 1. طابعة Bluetooth nPrinter متصلة
/// 2. ورق Black/Red
/// 3. الطابعة مشغلة
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nprinter_bluetooth_only/services/esc_pos_colored_text_service.dart';

void main() {
  group('ESC/POS Printing System Tests', () {
    // Test 1: بناء bytes النصوص العادية - أسود
    test('buildPlainTextEscPosBytes - Black Color', () async {
      final bytes = await buildPlainTextEscPosBytes(
        text: 'نص أسود',
        mode: PrintColorMode.black,
      );

      expect(bytes, isNotEmpty);
      expect(bytes, contains(0x1B)); // ESC
      expect(bytes, contains(0x40)); // Reset command
    });

    // Test 2: بناء bytes النصوص العادية - أحمر
    test('buildPlainTextEscPosBytes - Red Color', () async {
      final bytes = await buildPlainTextEscPosBytes(
        text: 'نص أحمر',
        mode: PrintColorMode.red,
      );

      expect(bytes, isNotEmpty);
      expect(bytes, contains(0x1B)); // ESC
      expect(bytes, contains(0x01)); // Red indicator
    });

    // Test 3: بناء bytes النصوص المختلطة
    test('buildMixedTextEscPosBytes - Mixed Colors', () async {
      final parts = [
        const PrintPart('أسود'),
        const PrintPart('أحمر', red: true),
      ];

      final bytes = await buildMixedTextEscPosBytes(parts: parts);

      expect(bytes, isNotEmpty);
      expect(bytes, contains(0x1B)); // ESC
    });

    // Test 4: اختبار التحويل من نص ملون (تنسيق [red]...)
    test('parseColoredTextParts - Parse Red Tags', () {
      final text = 'بداية [red]نص أحمر[/red] نهاية';
      final parts = parseColoredTextParts(text);

      expect(parts, isNotEmpty);
      expect(parts.length, greaterThanOrEqualTo(1));

      // تحقق من أن هناك جزء أحمر
      final hasRed = parts.any((p) => p.red);
      expect(hasRed, isTrue);
    });

    // Test 5: اختبار ترميز النصوص
    test('encodeText - Arabic Text Encoding', () async {
      final text = 'مرحبا بك في نظام الطباعة';
      final encoded = await encodeText(text);

      expect(encoded, isNotEmpty);
      expect(encoded, isA<List<int>>());
    });

    // Test 6: اختبار الترميز البديل
    test('encodeText - Fallback Encoding', () async {
      final text = 'الكود المحسّن';
      final encodedWindows = await encodeText(
        text,
        encoding: EscPosTextEncoding.windows1256,
      );
      final encodedCP864 = await encodeText(
        text,
        encoding: EscPosTextEncoding.cp864,
      );

      expect(encodedWindows, isNotEmpty);
      expect(encodedCP864, isNotEmpty);
    });

    // Test 7: اختبار الألوان الموسع
    test('buildColoredEscPosTestBytes - Generate Test Pattern', () async {
      final bytes = await buildColoredEscPosTestBytes();

      expect(bytes, isNotEmpty);
      // يجب أن تحتوي على أوامر ESC
      expect(bytes.contains(0x1B), isTrue);
      // يجب أن تحتوي على نهاية السطر
      expect(bytes.contains(0x0A), isTrue);
    });

    // Test 8: اختبار بناء bytes اختبار الألوان
    test('buildColorTestBytes - Simple Color Test', () async {
      final bytes = await buildColorTestBytes();

      expect(bytes, isNotEmpty);
      // يجب أن تحتوي على أوامر ESC للألوان
      expect(bytes.contains(0x1B), isTrue);
      expect(bytes.contains(0x72), isTrue); // ESC r command
    });

    // Test 9: اختبار الترميز للـ Enum
    test('EscPosTextEncoding - Charset Mapping', () {
      final windows = EscPosTextEncoding.windows1256;
      final cp864 = EscPosTextEncoding.cp864;

      expect(windows.charset, equals('windows-1256'));
      expect(cp864.charset, equals('cp864'));
      expect(windows.codePageId, equals(92));
      expect(cp864.codePageId, equals(28));
    });

    // Test 10: اختبار PrintPart
    test('PrintPart - Data Model', () {
      final blackPart = const PrintPart('أسود');
      final redPart = const PrintPart('أحمر', red: true);

      expect(blackPart.text, equals('أسود'));
      expect(blackPart.red, isFalse);
      expect(redPart.text, equals('أحمر'));
      expect(redPart.red, isTrue);
    });

    // Test 11: اختبار تحويل PrintColorMode من قيمة نصية
    test('printColorModeFromValue - Enum Conversion', () {
      expect(printColorModeFromValue('black'), equals(PrintColorMode.black));
      expect(printColorModeFromValue('red'), equals(PrintColorMode.red));
      expect(
        printColorModeFromValue('black_red'),
        equals(PrintColorMode.blackAndRed),
      );

      // اختبر القيم البديلة
      expect(printColorModeFromValue('1'), equals(PrintColorMode.red));
      expect(printColorModeFromValue('49'), equals(PrintColorMode.red));
    });

    // Test 12: اختبار الحالات الحدية - نصوص فارغة
    test('buildPlainTextEscPosBytes - Empty Text', () async {
      final bytes = await buildPlainTextEscPosBytes(
        text: '',
        mode: PrintColorMode.black,
      );

      // يجب أن تحتوي على أوامر التهيئة حتى لو كان النص فارغاً
      expect(bytes, isNotEmpty);
      expect(bytes, contains(0x1B)); // ESC
    });

    // Test 13: اختبار الحالات الحدية - قائمة parts فارغة
    test('buildMixedTextEscPosBytes - Empty Parts', () async {
      final bytes = await buildMixedTextEscPosBytes(parts: []);

      // يجب أن تحتوي على أوامر التهيئة
      expect(bytes, isNotEmpty);
    });

    // Test 14: اختبار feed lines
    test('buildPlainTextEscPosBytes - Feed Lines Count', () async {
      final bytes = await buildPlainTextEscPosBytes(
        text: 'نص',
        mode: PrintColorMode.black,
        feedLines: 5,
      );

      // يجب أن تحتوي على 5 أسطر طعام (0x0A)
      final feedCount = bytes.where((b) => b == 0x0A).length;
      expect(feedCount, equals(5));
    });

    // Test 15: اختبار الأمر البديل للأحمر
    test('buildPlainTextEscPosBytes - Alternative Red Command', () async {
      final bytesDefault = await buildPlainTextEscPosBytes(
        text: 'أحمر',
        mode: PrintColorMode.red,
        useAlternativeRedCommand: false,
      );

      final bytesAlternative = await buildPlainTextEscPosBytes(
        text: 'أحمر',
        mode: PrintColorMode.red,
        useAlternativeRedCommand: true,
      );

      // يجب أن تكون مختلفة
      expect(bytesDefault, isNotEmpty);
      expect(bytesAlternative, isNotEmpty);
      // يجب أن تحتوي على أوامر مختلفة
      expect(bytesDefault, isNot(bytesAlternative));
    });
  });

  group('Color Print Modes', () {
    test('PrintColorMode - All Modes', () {
      // تحقق من أن جميع الأنماط موجودة
      expect(PrintColorMode.black, isNotNull);
      expect(PrintColorMode.red, isNotNull);
      expect(PrintColorMode.blackAndRed, isNotNull);
    });
  });

  group('Text Encoding', () {
    test('EscPosTextEncoding - All Encodings', () {
      expect(EscPosTextEncoding.windows1256, isNotNull);
      expect(EscPosTextEncoding.cp864, isNotNull);
    });
  });
}

/// ============================================================================
/// ملاحظات الاختبار
/// ============================================================================
/// 
/// لتشغيل الاختبارات:
/// ```bash
/// flutter test test/printing_system_test.dart
/// ```
/// 
/// الاختبارات المدرجة:
/// 1. ✓ اختبار بناء bytes النصوص العادية - أسود
/// 2. ✓ اختبار بناء bytes النصوص العادية - أحمر
/// 3. ✓ اختبار بناء bytes النصوص المختلطة
/// 4. ✓ اختبار تحليل النصوص بصيغة [red]...[/red]
/// 5. ✓ اختبار ترميز النصوص العربية
/// 6. ✓ اختبار الترميز البديل (CP864)
/// 7. ✓ اختبار نمط الاختبار الموسع
/// 8. ✓ اختبار نمط الاختبار البسيط
/// 9. ✓ اختبار تعيين الترميز
/// 10. ✓ اختبار نموذج PrintPart
/// 11. ✓ اختبار تحويل PrintColorMode
/// 12. ✓ اختبار الحالات الحدية - نصوص فارغة
/// 13. ✓ اختبار الحالات الحدية - parts فارغة
/// 14. ✓ اختبار عدد feed lines
/// 15. ✓ اختبار الأمر البديل للأحمر
/// 
/// الاختبارات اليدوية المطلوبة:
/// - اختبار الطباعة الفعلية على الطابعة
/// - اختبار الألوان الأسود/الأحمر على الورق الحقيقي
/// - اختبار النصوص العربية
/// - اختبار الاتصال والفصل المتكرر
