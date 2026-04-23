import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

Future<ui.Image> generateSimpleTextImage(
  String text,
  double paperWidth, {
  bool addBorder = true,
  String printerProfile = 'auto',
}) async {
  final width = _paperPixelWidth(
    paperWidth,
    printerProfile: printerProfile,
  );
  const padding = 20.0;

  final fontData = await rootBundle.load('assets/fonts/NotoKufiArabic-Bold.ttf');
  final fontLoader =
      FontLoader('NotoKufiArabicBold')..addFont(Future.value(fontData));
  await fontLoader.load();

  const textStyle = TextStyle(
    fontFamily: 'NotoKufiArabicBold',
    fontSize: 26,
    color: Colors.black,
    fontWeight: FontWeight.bold,
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

  if (addBorder) {
    final borderPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawRect(Rect.fromLTWH(0, 0, width, height), borderPaint);
  }

  final textX = padding + (width - 2 * padding - tp.width) / 2;
  const textY = padding;
  tp.paint(canvas, Offset(textX, textY));

  final picture = recorder.endRecording();
  return picture.toImage(width.toInt(), height.toInt());
}
