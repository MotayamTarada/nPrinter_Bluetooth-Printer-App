import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'esc_pos_colored_text_service.dart';

class _PrintFontConfig {
  const _PrintFontConfig({
    required this.family,
    required this.assetPath,
    required this.weight,
  });

  final String family;
  final String assetPath;
  final FontWeight weight;
}

final Set<String> _loadedPrintFonts = <String>{};

void _drawBorderAroundTextBounds({
  required Canvas canvas,
  required double imageWidth,
  required double imageHeight,
  required double textY,
  required double textHeight,
}) {
  const borderPadding = 10.0;
  const safeInset = 1.0;

  final left = safeInset;
  var top = textY - borderPadding;
  final right = imageWidth - safeInset;
  var bottom = textY + textHeight + borderPadding;

  if (top < safeInset) {
    top = safeInset;
  }
  if (bottom > imageHeight - safeInset) {
    bottom = imageHeight - safeInset;
  }
  if (right <= left || bottom <= top) {
    return;
  }

  final borderPaint = Paint()
    ..color = Colors.black
    ..strokeWidth = 2
    ..style = PaintingStyle.stroke;
  canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), borderPaint);
}

double _paperPixelWidth(double paperWidthMm, {String printerProfile = 'auto'}) {
  switch (printerProfile) {
    case '58':
      return 384;
    case '80':
      return 576;
    case '112_832':
      return 832;
    case '112_896':
      return 896;
  }

  if (paperWidthMm <= 58) {
    return 384;
  }
  if (paperWidthMm <= 72) {
    return 512;
  }
  if (paperWidthMm >= 108) {
    // Common printable width for 112mm class printers.
    return 832;
  }
  return 576;
}

_PrintFontConfig _resolvePrintFont(String fontFamily) {
  switch (fontFamily) {
    case 'Tajawal':
      return const _PrintFontConfig(
        family: 'Tajawal',
        assetPath: 'assets/fonts/Tajawal-Regular.ttf',
        weight: FontWeight.normal,
      );
    case 'Cairo':
      return const _PrintFontConfig(
        family: 'Cairo',
        assetPath: 'assets/fonts/Cairo-Bold.ttf',
        weight: FontWeight.bold,
      );
    case 'Almarai':
      return const _PrintFontConfig(
        family: 'Almarai',
        assetPath: 'assets/fonts/Almarai-Bold.ttf',
        weight: FontWeight.bold,
      );
    case 'Changa':
      return const _PrintFontConfig(
        family: 'Changa',
        assetPath: 'assets/fonts/Changa-Bold.ttf',
        weight: FontWeight.bold,
      );
    case 'Amiri':
      return const _PrintFontConfig(
        family: 'Amiri',
        assetPath: 'assets/fonts/Amiri-Bold.ttf',
        weight: FontWeight.bold,
      );
    case 'ReemKufi':
      return const _PrintFontConfig(
        family: 'ReemKufi',
        assetPath: 'assets/fonts/ReemKufi-Bold.ttf',
        weight: FontWeight.bold,
      );
    default:
      return const _PrintFontConfig(
        family: 'NotoKufiArabicBold',
        assetPath: 'assets/fonts/NotoKufiArabic-Bold.ttf',
        weight: FontWeight.bold,
      );
  }
}

Future<void> _ensurePrintFontLoaded(_PrintFontConfig font) async {
  if (_loadedPrintFonts.contains(font.family)) {
    return;
  }

  final fontData = await rootBundle.load(font.assetPath);
  final fontLoader = FontLoader(font.family)..addFont(Future.value(fontData));
  await fontLoader.load();
  _loadedPrintFonts.add(font.family);
}

Future<ui.Image> generateSimpleTextImage(
  String text,
  double paperWidth, {
  bool addBorder = true,
  String printerProfile = 'auto',
  String printColor = 'black',
  double fontSize = 26,
  String fontFamily = 'NotoKufiArabicBold',
}) async {
  final width = _paperPixelWidth(paperWidth, printerProfile: printerProfile);
  const padding = 20.0;

  final printFont = _resolvePrintFont(fontFamily);
  await _ensurePrintFontLoaded(printFont);

  // Keep typed text rasterized as pure black pixels.
  // Printer-side color command (ESC r) decides black/red output.
  // This avoids anti-aliased red shades that can appear as mixed colors.
  const textPaintColor = Colors.black;

  final textStyle = TextStyle(
    fontFamily: printFont.family,
    fontSize: fontSize.clamp(12, 72).toDouble(),
    color: textPaintColor,
    fontWeight: printFont.weight,
  );

  final tp = TextPainter(
    text: TextSpan(text: text, style: textStyle),
    textDirection: TextDirection.rtl,
    textAlign: TextAlign.center,
  )..layout(maxWidth: width - 2 * padding);

  final height = tp.height + 2 * padding;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));

  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = Colors.white,
  );

  final textX = padding + (width - 2 * padding - tp.width) / 2;
  const textY = padding;
  if (addBorder) {
    _drawBorderAroundTextBounds(
      canvas: canvas,
      imageWidth: width,
      imageHeight: height,
      textY: textY,
      textHeight: tp.height,
    );
  }
  tp.paint(canvas, Offset(textX, textY));

  final picture = recorder.endRecording();
  return picture.toImage(width.toInt(), height.toInt());
}

Future<ui.Image> generateTaggedTextImage(
  List<PrintPart> parts,
  double paperWidth, {
  bool addBorder = true,
  String printerProfile = 'auto',
  double fontSize = 26,
  String fontFamily = 'NotoKufiArabicBold',
}) async {
  final width = _paperPixelWidth(paperWidth, printerProfile: printerProfile);
  const padding = 20.0;

  final printFont = _resolvePrintFont(fontFamily);
  await _ensurePrintFontLoaded(printFont);

  final baseStyle = TextStyle(
    fontFamily: printFont.family,
    fontSize: fontSize.clamp(12, 72).toDouble(),
    color: Colors.black,
    fontWeight: printFont.weight,
  );

  final spans = <InlineSpan>[
    for (final part in parts)
      TextSpan(
        text: part.text,
        style: baseStyle.copyWith(
          color: part.red ? const Color(0xFFD10000) : Colors.black,
        ),
      ),
  ];
  final tp = TextPainter(
    text: TextSpan(style: baseStyle, children: spans),
    textDirection: TextDirection.rtl,
    textAlign: TextAlign.center,
  )..layout(maxWidth: width - 2 * padding);

  final height = tp.height + 2 * padding;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));

  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = Colors.white,
  );

  final textX = padding + (width - 2 * padding - tp.width) / 2;
  const textY = padding;
  if (addBorder) {
    _drawBorderAroundTextBounds(
      canvas: canvas,
      imageWidth: width,
      imageHeight: height,
      textY: textY,
      textHeight: tp.height,
    );
  }
  tp.paint(canvas, Offset(textX, textY));

  final picture = recorder.endRecording();
  return picture.toImage(width.toInt(), height.toInt());
}

Future<ui.Image> generateTaggedTextLayerImage(
  List<PrintPart> parts,
  double paperWidth, {
  required bool redLayer,
  bool addBorder = true,
  String printerProfile = 'auto',
  double fontSize = 26,
  String fontFamily = 'NotoKufiArabicBold',
}) async {
  final width = _paperPixelWidth(paperWidth, printerProfile: printerProfile);
  const padding = 20.0;

  final printFont = _resolvePrintFont(fontFamily);
  await _ensurePrintFontLoaded(printFont);

  final baseStyle = TextStyle(
    fontFamily: printFont.family,
    fontSize: fontSize.clamp(12, 72).toDouble(),
    color: Colors.black,
    fontWeight: printFont.weight,
  );

  final spans = <InlineSpan>[
    for (final part in parts)
      TextSpan(
        text: part.text,
        style: baseStyle.copyWith(
          // Keep full original text in layout, but paint only target layer.
          color: ((redLayer && part.red) || (!redLayer && !part.red))
              ? Colors.black
              : Colors.white,
        ),
      ),
  ];
  final tp = TextPainter(
    text: TextSpan(style: baseStyle, children: spans),
    textDirection: TextDirection.rtl,
    textAlign: TextAlign.center,
  )..layout(maxWidth: width - 2 * padding);

  final height = tp.height + 2 * padding;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));

  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = Colors.white,
  );

  final textX = padding + (width - 2 * padding - tp.width) / 2;
  const textY = padding;
  if (addBorder) {
    _drawBorderAroundTextBounds(
      canvas: canvas,
      imageWidth: width,
      imageHeight: height,
      textY: textY,
      textHeight: tp.height,
    );
  }
  tp.paint(canvas, Offset(textX, textY));

  final picture = recorder.endRecording();
  return picture.toImage(width.toInt(), height.toInt());
}
