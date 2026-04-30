import 'dart:typed_data';

import 'package:charset_converter/charset_converter.dart';

enum PrintColorMode { black, red, blackAndRed }

enum EscPosTextEncoding { windows1256, cp864 }

class PrintPart {
  const PrintPart(this.text, {this.red = false});

  final String text;
  final bool red;
}

extension EscPosTextEncodingDetails on EscPosTextEncoding {
  String get charset {
    switch (this) {
      case EscPosTextEncoding.windows1256:
        return 'windows-1256';
      case EscPosTextEncoding.cp864:
        return 'cp864';
    }
  }

  int get codePageId {
    switch (this) {
      case EscPosTextEncoding.windows1256:
        return 92;
      case EscPosTextEncoding.cp864:
        return 28;
    }
  }
}

Future<List<int>> encodeText(
  String text, {
  EscPosTextEncoding encoding = EscPosTextEncoding.windows1256,
}) async {
  try {
    return await CharsetConverter.encode(encoding.charset, text);
  } catch (_) {
    final fallback = encoding == EscPosTextEncoding.windows1256
        ? EscPosTextEncoding.cp864
        : EscPosTextEncoding.windows1256;
    return CharsetConverter.encode(fallback.charset, text);
  }
}

List<PrintPart> parseColoredTextParts(String text) {
  final parts = <PrintPart>[];
  final pattern = RegExp(r'\[red\]([\s\S]*?)\[/red\]', caseSensitive: false);
  var offset = 0;

  for (final match in pattern.allMatches(text)) {
    if (match.start > offset) {
      parts.add(PrintPart(text.substring(offset, match.start)));
    }
    parts.add(PrintPart(match.group(1) ?? '', red: true));
    offset = match.end;
  }

  if (offset < text.length) {
    parts.add(PrintPart(text.substring(offset)));
  }

  return parts.where((part) => part.text.isNotEmpty).toList();
}

PrintColorMode printColorModeFromValue(String value) {
  switch (value.trim().toLowerCase()) {
    case 'red':
    case '1':
    case '49':
    case 'n=1':
      return PrintColorMode.red;
    case 'black_red':
      return PrintColorMode.blackAndRed;
    default:
      return PrintColorMode.black;
  }
}

List<int> _selectPrintColorBytes(
  bool red, {
  bool useAlternativeRedCommand = false,
}) {
  if (red && useAlternativeRedCommand) {
    return const <int>[0x1B, 0x63, 0x30, 0x01];
  }
  return <int>[0x1B, 0x72, red ? 0x01 : 0x00];
}

Future<Uint8List> buildColoredEscPosBytes({
  required PrintColorMode mode,
  String? plainText,
  List<PrintPart>? parts,
  EscPosTextEncoding encoding = EscPosTextEncoding.windows1256,
  bool center = false,
  bool useAlternativeRedCommand = false,
  int feedLines = 3,
  bool cutPaper = false,
}) async {
  final bytes = <int>[];

  bytes.addAll(const <int>[0x1B, 0x40]);
  bytes.addAll(<int>[0x1B, 0x74, encoding.codePageId]);
  bytes.addAll(<int>[0x1B, 0x61, center ? 0x01 : 0x00]);

  switch (mode) {
    case PrintColorMode.black:
      bytes.addAll(_selectPrintColorBytes(false));
      bytes.addAll(await encodeText(plainText ?? '', encoding: encoding));
      break;
    case PrintColorMode.red:
      bytes.addAll(
        _selectPrintColorBytes(
          true,
          useAlternativeRedCommand: useAlternativeRedCommand,
        ),
      );
      bytes.addAll(await encodeText(plainText ?? '', encoding: encoding));
      break;
    case PrintColorMode.blackAndRed:
      final effectiveParts =
          parts ??
          (plainText == null
              ? const <PrintPart>[]
              : parseColoredTextParts(plainText));
      for (final part in effectiveParts) {
        bytes.addAll(
          _selectPrintColorBytes(
            part.red,
            useAlternativeRedCommand: useAlternativeRedCommand,
          ),
        );
        bytes.addAll(await encodeText(part.text, encoding: encoding));
      }
      break;
  }

  bytes.addAll(_selectPrintColorBytes(false));
  if (feedLines > 0) {
    bytes.addAll(List<int>.filled(feedLines.clamp(0, 255).toInt(), 0x0A));
  }
  if (cutPaper) {
    bytes.addAll(const <int>[0x1D, 0x56, 0x00]);
  }

  return Uint8List.fromList(bytes);
}

Future<Uint8List> buildColoredEscPosTestBytes({
  EscPosTextEncoding encoding = EscPosTextEncoding.windows1256,
  bool useAlternativeRedCommand = false,
}) {
  return buildColoredEscPosBytes(
    mode: PrintColorMode.blackAndRed,
    parts: const <PrintPart>[
      PrintPart('TEST BLACK\n'),
      PrintPart('TEST RED\n', red: true),
      PrintPart('BLACK PART / '),
      PrintPart('RED PART\n', red: true),
      PrintPart('هذا نص أسود\n'),
      PrintPart('هذا نص أحمر\n', red: true),
    ],
    encoding: encoding,
    useAlternativeRedCommand: useAlternativeRedCommand,
    feedLines: 3,
  );
}

/// بناء bytes للنصوص العادية (أسود أو أحمر فقط)
Future<Uint8List> buildPlainTextEscPosBytes({
  required String text,
  required PrintColorMode mode,
  EscPosTextEncoding encoding = EscPosTextEncoding.windows1256,
  bool useAlternativeRedCommand = false,
  int feedLines = 3,
}) async {
  final bytes = <int>[];

  bytes.addAll(const <int>[0x1B, 0x40]); // Reset
  bytes.addAll(<int>[0x1B, 0x74, encoding.codePageId]); // Set code page

  // اختيار اللون
  switch (mode) {
    case PrintColorMode.black:
      bytes.addAll(const <int>[0x1B, 0x72, 0x00]); // Black
      break;
    case PrintColorMode.red:
      if (useAlternativeRedCommand) {
        bytes.addAll(const <int>[0x1B, 0x63, 0x30, 0x01]); // Alternative red
      } else {
        bytes.addAll(const <int>[0x1B, 0x72, 0x01]); // Red
      }
      break;
    case PrintColorMode.blackAndRed:
      bytes.addAll(const <int>[0x1B, 0x72, 0x00]); // Default to black
      break;
  }

  // ترميز ونسخ النص
  final encodedText = await encodeText(text, encoding: encoding);
  bytes.addAll(encodedText);

  // الرجوع للون الأسود وإضافة feed lines
  bytes.addAll(const <int>[0x1B, 0x72, 0x00]); // Back to black
  bytes.addAll(List<int>.filled(feedLines.clamp(0, 255).toInt(), 0x0A)); // Feed

  return Uint8List.fromList(bytes);
}

/// بناء bytes للنصوص المختلطة (أسود + أحمر)
Future<Uint8List> buildMixedTextEscPosBytes({
  required List<PrintPart> parts,
  EscPosTextEncoding encoding = EscPosTextEncoding.windows1256,
  bool useAlternativeRedCommand = false,
  int feedLines = 3,
}) async {
  final bytes = <int>[];

  bytes.addAll(const <int>[0x1B, 0x40]); // Reset
  bytes.addAll(<int>[0x1B, 0x74, encoding.codePageId]); // Set code page

  // معالجة كل جزء
  for (final part in parts) {
    if (part.red) {
      if (useAlternativeRedCommand) {
        bytes.addAll(const <int>[0x1B, 0x63, 0x30, 0x01]); // Alternative red
      } else {
        bytes.addAll(const <int>[0x1B, 0x72, 0x01]); // Red
      }
    } else {
      bytes.addAll(const <int>[0x1B, 0x72, 0x00]); // Black
    }

    final encodedText = await encodeText(part.text, encoding: encoding);
    bytes.addAll(encodedText);
  }

  // الرجوع للون الأسود وإضافة feed lines
  bytes.addAll(const <int>[0x1B, 0x72, 0x00]); // Back to black
  bytes.addAll(List<int>.filled(feedLines.clamp(0, 255).toInt(), 0x0A)); // Feed

  return Uint8List.fromList(bytes);
}

/// دالة لاختبار الألوان البسيط (نصوص عادية)
Future<Uint8List> buildColorTestBytes({
  EscPosTextEncoding encoding = EscPosTextEncoding.windows1256,
  bool useAlternativeRedCommand = false,
}) async {
  final parts = <PrintPart>[
    const PrintPart('BLACK TEST\n'),
    const PrintPart('RED TEST\n', red: true),
    const PrintPart('BLACK AGAIN\n'),
  ];

  return buildMixedTextEscPosBytes(
    parts: parts,
    encoding: encoding,
    useAlternativeRedCommand: useAlternativeRedCommand,
    feedLines: 3,
  );
}
