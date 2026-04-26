import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:pdfx/pdfx.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'generate_image_service.dart';
import 'printer_status_service.dart';

Future<void> requestBluetoothPermissions() async {
  if (await Permission.bluetoothConnect.isDenied) {
    await Permission.bluetoothConnect.request();
  }
  if (await Permission.bluetoothScan.isDenied) {
    await Permission.bluetoothScan.request();
  }
  if (await Permission.location.isDenied) {
    await Permission.location.request();
  }
}

PaperSize _resolvePaperSize(double paperWidthMm) {
  return paperWidthMm >= 72 ? PaperSize.mm80 : PaperSize.mm58;
}

bool _isFitToWidthMode(String fitMode) => fitMode == 'fit_width';

PosAlign _resolvePrintAlignment(String alignment) {
  switch (alignment) {
    case 'left':
      return PosAlign.left;
    case 'right':
      return PosAlign.right;
    default:
      return PosAlign.center;
  }
}

bool _supportsCommandType(String commandType) {
  return commandType == 'auto' ||
      commandType == 'esc' ||
      commandType == 'tspl' ||
      commandType == 'cpcl';
}

String _resolveEffectiveCommandType(String commandType) {
  if (commandType == 'auto') {
    return 'esc';
  }
  return commandType;
}

bool _isEscCommandType(String commandType) {
  return commandType == 'esc';
}

Future<PrinterStatusCheck> _checkEscPosPrinterStatus({
  required String mac,
  required String effectiveCommandType,
}) async {
  if (!_isEscCommandType(effectiveCommandType)) {
    return const PrinterStatusCheck.skipped();
  }

  final status = await PrinterStatusService.checkEscPosStatus(mac);
  await Future<void>.delayed(const Duration(milliseconds: 120));
  return status;
}

String _printAcceptedMessage(PrinterStatusCheck status) {
  if (status.hasBlockingIssue) {
    return 'تم إرسال أمر الطباعة، لكن الطابعة تبلغ عن مشكلة: ${status.issueSummary}';
  }

  if (status.checked && status.supported) {
    final warning = status.warningSummary;
    if (warning.isNotEmpty) {
      return 'تم إرسال أمر الطباعة، ولا توجد أخطاء مانعة. تنبيه: $warning';
    }
    return 'تم إرسال أمر الطباعة، والطابعة لا تبلغ عن أخطاء';
  }

  return 'تم إرسال أمر الطباعة للطابعة. لا يمكن تأكيد خروج الورقة تلقائيًا من هذه الطابعة';
}

String _normalizeCommandType(String commandType) {
  final normalized = commandType.trim().toLowerCase();
  if (normalized == 'auto' ||
      normalized == 'tspl' ||
      normalized == 'esc' ||
      normalized == 'cpcl') {
    return normalized;
  }
  return 'auto';
}

String _normalizePrintColor(String printColor) {
  final normalized = printColor.trim().toLowerCase();
  if (normalized == 'red' || normalized == 'black_red') {
    return normalized;
  }
  return 'black';
}

int _normalizePrintRotation(int rotationDegrees) {
  final normalized = rotationDegrees % 360;
  final positiveRotation = normalized < 0 ? normalized + 360 : normalized;
  if (positiveRotation == 90 ||
      positiveRotation == 180 ||
      positiveRotation == 270) {
    return positiveRotation;
  }
  return 0;
}

img.Image _applyPrintRotation(img.Image source, int rotationDegrees) {
  final normalizedRotation = _normalizePrintRotation(rotationDegrees);
  if (normalizedRotation == 0) {
    return source;
  }
  return img.copyRotate(source, angle: normalizedRotation);
}

List<int> _buildPrintColorBytes(String printColor) {
  // ESC r n : Select color (common two-color ESC/POS printers)
  // n=0 black, n=1 red
  return <int>[0x1B, 0x72, printColor == 'red' ? 1 : 0];
}

int _resolveRasterTargetWidth(
  double paperWidthMm, {
  String printerProfile = 'auto',
}) {
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

  if (paperWidthMm >= 108) {
    // Common printable width for 112mm class printers (about 104mm @ 8 dots/mm).
    return 832;
  }
  if (paperWidthMm >= 72) {
    return 576;
  }
  if (paperWidthMm >= 60) {
    return 512;
  }
  return 384;
}

List<String> _splitTextIntoChunks(String text, {int maxCharsPerChunk = 180}) {
  final normalized = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), ' ');

  final paragraphs = normalized.split('\n');
  final chunks = <String>[];
  var current = StringBuffer();

  void flushCurrent() {
    final value = current.toString().trimRight();
    if (value.isNotEmpty) {
      chunks.add(value);
    }
    current = StringBuffer();
  }

  for (final paragraph in paragraphs) {
    final trimmedParagraph = paragraph.trim();
    if (trimmedParagraph.isEmpty) {
      if (current.isNotEmpty) {
        if (current.length + 1 > maxCharsPerChunk) {
          flushCurrent();
        } else {
          current.writeln();
        }
      }
      continue;
    }

    final words = trimmedParagraph.split(RegExp(r'\s+'));
    for (final word in words) {
      if (word.isEmpty) {
        continue;
      }

      if (word.length > maxCharsPerChunk) {
        if (current.isNotEmpty) {
          flushCurrent();
        }
        for (var i = 0; i < word.length; i += maxCharsPerChunk) {
          final end = math.min(i + maxCharsPerChunk, word.length);
          chunks.add(word.substring(i, end));
        }
        continue;
      }

      final prefixLen = current.isEmpty ? 0 : 1;
      if (current.length + prefixLen + word.length > maxCharsPerChunk) {
        flushCurrent();
      }

      if (current.isNotEmpty) {
        current.write(' ');
      }
      current.write(word);
    }

    if (current.isNotEmpty) {
      if (current.length + 1 > maxCharsPerChunk) {
        flushCurrent();
      } else {
        current.write('\n');
      }
    }
  }

  if (current.isNotEmpty) {
    flushCurrent();
  }

  if (chunks.isEmpty) {
    return <String>[normalized];
  }
  return chunks;
}

List<int> _buildEscBeepBytes({required int count, required Generator generator}) {
  if (count <= 0) {
    return const <int>[];
  }

  final bytes = <int>[];
  var remaining = count;
  while (remaining > 0) {
    final chunk = remaining > 9 ? 9 : remaining;
    bytes.addAll(
      generator.beep(
        n: chunk,
        duration: PosBeepDuration.beep200ms,
      ),
    );
    remaining -= chunk;
  }
  return bytes;
}

List<int> _buildBeepBytes({
  required int count,
  required String beepType,
  required Generator generator,
}) {
  if (count <= 0) {
    return const <int>[];
  }

  final bellBytes = List<int>.filled(count, 0x07);
  final escBeepBytes = _buildEscBeepBytes(count: count, generator: generator);

  if (beepType == '0x07') {
    return bellBytes;
  }
  return escBeepBytes;
}

Future<void> _playBeepWithFallback({
  required int count,
  required String beepType,
  required Generator generator,
}) async {
  if (count <= 0) {
    return;
  }

  final primary = _buildBeepBytes(
    count: count,
    beepType: beepType,
    generator: generator,
  );
  final fallback = _buildBeepBytes(
    count: count,
    beepType: beepType == '0x07' ? '0x1B, 0x42' : '0x07',
    generator: generator,
  );

  if (primary.isNotEmpty) {
    await PrintBluetoothThermal.writeBytes(primary);
  }
  await Future<void>.delayed(const Duration(milliseconds: 80));
  if (fallback.isNotEmpty) {
    await PrintBluetoothThermal.writeBytes(fallback);
  }
}

Future<ui.Image> _decodeUiImage(Uint8List bytes) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromList(bytes, completer.complete);
  return completer.future;
}

class _DualColorLayers {
  const _DualColorLayers({
    required this.blackLayer,
    required this.redLayer,
    required this.hasBlackPixels,
    required this.hasRedPixels,
  });

  final img.Image blackLayer;
  final img.Image redLayer;
  final bool hasBlackPixels;
  final bool hasRedPixels;
}

bool _isRedCandidate(img.Pixel pixel) {
  final r = pixel.r.toInt();
  final g = pixel.g.toInt();
  final b = pixel.b.toInt();
  return r >= 110 && r > g + 20 && r > b + 20;
}

_DualColorLayers _splitDualColorLayers(img.Image source) {
  final blackLayer = img.Image(
    width: source.width,
    height: source.height,
    numChannels: 4,
  );
  final redLayer = img.Image(
    width: source.width,
    height: source.height,
    numChannels: 4,
  );
  img.fill(blackLayer, color: img.ColorRgba8(255, 255, 255, 255));
  img.fill(redLayer, color: img.ColorRgba8(255, 255, 255, 255));

  var hasBlackPixels = false;
  var hasRedPixels = false;

  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final pixel = source.getPixel(x, y);
      if (pixel.a.toInt() <= 8) {
        continue;
      }

      if (_isRedCandidate(pixel)) {
        hasRedPixels = true;
        redLayer.setPixelRgba(x, y, 0, 0, 0, 255);
        continue;
      }

      final luminance =
          ((pixel.r.toInt() * 299) +
              (pixel.g.toInt() * 587) +
              (pixel.b.toInt() * 114)) ~/
          1000;
      if (luminance < 168) {
        hasBlackPixels = true;
        blackLayer.setPixelRgba(x, y, 0, 0, 0, 255);
      }
    }
  }

  return _DualColorLayers(
    blackLayer: blackLayer,
    redLayer: redLayer,
    hasBlackPixels: hasBlackPixels,
    hasRedPixels: hasRedPixels,
  );
}

void _appendAsciiLine(List<int> output, String line) {
  output.addAll(latin1.encode('$line\r\n'));
}

void _appendAsciiRaw(List<int> output, String value) {
  output.addAll(latin1.encode(value));
}

int _resolveHorizontalOffset({
  required int paperWidthDots,
  required int contentWidthDots,
  required String alignment,
}) {
  final safeOffset = math.max(0, paperWidthDots - contentWidthDots);
  switch (alignment) {
    case 'right':
      return safeOffset;
    case 'left':
      return 0;
    default:
      return safeOffset ~/ 2;
  }
}

Uint8List _toMonochromeBitmapData(img.Image source) {
  final widthBytes = (source.width + 7) ~/ 8;
  final data = Uint8List(widthBytes * source.height);
  var offset = 0;

  for (var y = 0; y < source.height; y++) {
    for (var xByte = 0; xByte < widthBytes; xByte++) {
      var value = 0;
      for (var bit = 0; bit < 8; bit++) {
        final x = (xByte * 8) + bit;
        if (x >= source.width) {
          continue;
        }

        final pixel = source.getPixel(x, y);
        final alpha = pixel.a.toInt();
        if (alpha <= 8) {
          continue;
        }

        final luminance =
            ((pixel.r.toInt() * 299) +
                (pixel.g.toInt() * 587) +
                (pixel.b.toInt() * 114)) ~/
            1000;
        if (luminance < 160) {
          value |= (0x80 >> bit);
        }
      }
      data[offset++] = value;
    }
  }

  return data;
}

List<int> _buildTsplBitmapJob({
  required img.Image image,
  required double paperWidthMm,
  required int paperWidthDots,
  required String alignment,
}) {
  final output = <int>[];
  final widthBytes = (image.width + 7) ~/ 8;
  final xOffset = _resolveHorizontalOffset(
    paperWidthDots: paperWidthDots,
    contentWidthDots: image.width,
    alignment: alignment,
  );
  final sizeWidthMm = math.max(20, math.min(220, paperWidthMm.round()));
  final heightMm = math.max(10, (image.height / 8).ceil() + 4);
  final bitmapData = _toMonochromeBitmapData(image);

  _appendAsciiLine(output, 'SIZE $sizeWidthMm mm,$heightMm mm');
  _appendAsciiLine(output, 'GAP 0 mm,0 mm');
  _appendAsciiLine(output, 'DIRECTION 1');
  _appendAsciiLine(output, 'REFERENCE 0,0');
  _appendAsciiLine(output, 'CLS');
  _appendAsciiRaw(
    output,
    'BITMAP $xOffset,0,$widthBytes,${image.height},0,',
  );
  output.addAll(bitmapData);
  _appendAsciiLine(output, '');
  _appendAsciiLine(output, 'PRINT 1,1');

  return output;
}

List<int> _buildCpclBitmapJob({
  required img.Image image,
  required int paperWidthDots,
  required String alignment,
}) {
  final output = <int>[];
  final widthBytes = (image.width + 7) ~/ 8;
  final xOffset = _resolveHorizontalOffset(
    paperWidthDots: paperWidthDots,
    contentWidthDots: image.width,
    alignment: alignment,
  );
  final pageHeightDots = math.max(120, image.height + 40);
  final bitmapData = _toMonochromeBitmapData(image);

  _appendAsciiLine(output, '! 0 200 200 $pageHeightDots 1');
  _appendAsciiRaw(
    output,
    'EG $widthBytes ${image.height} $xOffset 0 ',
  );
  output.addAll(bitmapData);
  _appendAsciiLine(output, '');
  _appendAsciiLine(output, 'FORM');
  _appendAsciiLine(output, 'PRINT');

  return output;
}

List<int> _buildRawBitmapJob({
  required String commandType,
  required img.Image image,
  required double paperWidthMm,
  required int paperWidthDots,
  required String alignment,
}) {
  if (commandType == 'tspl') {
    return _buildTsplBitmapJob(
      image: image,
      paperWidthMm: paperWidthMm,
      paperWidthDots: paperWidthDots,
      alignment: alignment,
    );
  }
  if (commandType == 'cpcl') {
    return _buildCpclBitmapJob(
      image: image,
      paperWidthDots: paperWidthDots,
      alignment: alignment,
    );
  }
  throw Exception('نوع الكوماند غير مدعوم: $commandType');
}

Iterable<img.Image> _splitImageIntoStrips(
  img.Image image, {
  int maxStripHeight = 256,
}) sync* {
  for (var y = 0; y < image.height; y += maxStripHeight) {
    final stripHeight = math.min(maxStripHeight, image.height - y);
    yield img.copyCrop(
      image,
      x: 0,
      y: y,
      width: image.width,
      height: stripHeight,
    );
  }
}

Future<bool> _printRawBitmapInStrips({
  required String commandType,
  required img.Image image,
  required double paperWidthMm,
  required int paperWidthDots,
  required String alignment,
}) async {
  for (final strip in _splitImageIntoStrips(image, maxStripHeight: 240)) {
    final bytes = _buildRawBitmapJob(
      commandType: commandType,
      image: strip,
      paperWidthMm: paperWidthMm,
      paperWidthDots: paperWidthDots,
      alignment: alignment,
    );
    final sent = await PrintBluetoothThermal.writeBytes(bytes);
    if (!sent) {
      return false;
    }
    await Future<void>.delayed(const Duration(milliseconds: 70));
  }
  return true;
}

Future<img.Image> _prepareImageForCommand(
  ui.Image flutterImage,
  double paperWidthMm, {
  bool forceFitToPaperWidth = false,
  String printerProfile = 'auto',
  int printRotationDegrees = 0,
}) async {
  final byteData = await flutterImage.toByteData(format: ui.ImageByteFormat.png);
  if (byteData == null) {
    throw Exception('تعذر تحويل الصورة');
  }

  final pngBytes = byteData.buffer.asUint8List();
  final decodedImage = img.decodeImage(pngBytes);
  if (decodedImage == null) {
    throw Exception('تعذر فك ترميز الصورة');
  }

  final rotatedImage = _applyPrintRotation(decodedImage, printRotationDegrees);
  final rasterTargetWidth = _resolveRasterTargetWidth(
    paperWidthMm,
    printerProfile: printerProfile,
  );
  final mustResizeToPaperWidth =
      forceFitToPaperWidth || rotatedImage.width > rasterTargetWidth;

  return mustResizeToPaperWidth
      ? img.copyResize(
          rotatedImage,
          width: rasterTargetWidth,
          interpolation: img.Interpolation.average,
        )
      : rotatedImage;
}

Future<List<int>> _convertPreparedImageToEscPosBytes(
  img.Image preparedImage,
  double paperWidthMm, {
  PosAlign align = PosAlign.center,
}) async {
  final paperSize = _resolvePaperSize(paperWidthMm);
  final profile = await CapabilityProfile.load();
  final generator = Generator(paperSize, profile);

  final bytes = <int>[];
  const maxStripHeight = 256;

  for (var y = 0; y < preparedImage.height; y += maxStripHeight) {
    final stripHeight = math.min(maxStripHeight, preparedImage.height - y);
    final strip = img.copyCrop(
      preparedImage,
      x: 0,
      y: y,
      width: preparedImage.width,
      height: stripHeight,
    );

    bytes.addAll(
      generator.imageRaster(
        strip,
        align: align,
        imageFn: PosImageFn.bitImageRaster,
      ),
    );
  }

  bytes.addAll(generator.feed(1));
  return bytes;
}

Future<bool> _printImageByCommandType({
  required String commandType,
  required ui.Image image,
  required double paperWidthMm,
  required String fitMode,
  required String contentAlignment,
  required String printerProfile,
  required String printColor,
  required int printRotationDegrees,
  required Generator generator,
}) async {
  final preparedImage = await _prepareImageForCommand(
    image,
    paperWidthMm,
    forceFitToPaperWidth: _isFitToWidthMode(fitMode),
    printerProfile: printerProfile,
    printRotationDegrees: printRotationDegrees,
  );
  if (_isEscCommandType(commandType)) {
    final align = _resolvePrintAlignment(contentAlignment);

    if (printColor == 'black_red') {
      final layers = _splitDualColorLayers(preparedImage);

      if (layers.hasBlackPixels) {
        final blackBytes = await _convertPreparedImageToEscPosBytes(
          layers.blackLayer,
          paperWidthMm,
          align: align,
        );
        final blackJob = <int>[
          ...generator.reset(),
          ..._buildPrintColorBytes('black'),
          ...blackBytes,
        ];
        final sentBlack = await PrintBluetoothThermal.writeBytes(blackJob);
        if (!sentBlack) {
          return false;
        }
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }

      if (layers.hasRedPixels) {
        final redBytes = await _convertPreparedImageToEscPosBytes(
          layers.redLayer,
          paperWidthMm,
          align: align,
        );
        final redJob = <int>[
          ...generator.reset(),
          ..._buildPrintColorBytes('red'),
          ...redBytes,
        ];
        final sentRed = await PrintBluetoothThermal.writeBytes(redJob);
        if (!sentRed) {
          return false;
        }
      }

      return true;
    }

    final imageBytes = await _convertPreparedImageToEscPosBytes(
      preparedImage,
      paperWidthMm,
      align: align,
    );
    final chunkJob = <int>[
      ...generator.reset(),
      ..._buildPrintColorBytes(printColor),
      ...imageBytes,
    ];
    return PrintBluetoothThermal.writeBytes(chunkJob);
  }

  final paperWidthDots = _resolveRasterTargetWidth(
    paperWidthMm,
    printerProfile: printerProfile,
  );

  if (printColor == 'black_red') {
    final layers = _splitDualColorLayers(preparedImage);
    if (layers.hasBlackPixels) {
      final sentBlack = await _printRawBitmapInStrips(
        commandType: commandType,
        image: layers.blackLayer,
        paperWidthMm: paperWidthMm,
        paperWidthDots: paperWidthDots,
        alignment: contentAlignment,
      );
      if (!sentBlack) {
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    if (layers.hasRedPixels) {
      final sentRed = await _printRawBitmapInStrips(
        commandType: commandType,
        image: layers.redLayer,
        paperWidthMm: paperWidthMm,
        paperWidthDots: paperWidthDots,
        alignment: contentAlignment,
      );
      if (!sentRed) {
        return false;
      }
    }
    return true;
  }

  return _printRawBitmapInStrips(
    commandType: commandType,
    image: preparedImage,
    paperWidthMm: paperWidthMm,
    paperWidthDots: paperWidthDots,
    alignment: contentAlignment,
  );
}

Future<void> printBluetoothReceipt({
  required BuildContext context,
  required String text,
  required double paperWidth,
  required String mac,
  int beepBefore = 0,
  int beepAfter = 0,
  String beepType = '0x07',
  bool autoCut = false,
  int feedLines = 0,
  bool textBorder = false,
  String fitMode = 'fit_width',
  String contentAlignment = 'center',
  String printerProfile = 'auto',
  String commandType = 'auto',
  String printColor = 'black',
  int printRotationDegrees = 0,
  int textFontSize = 26,
  String textFontFamily = 'NotoKufiArabicBold',
}) async {
  try {
    final normalizedCommandType = _normalizeCommandType(commandType);
    final effectiveCommandType =
        _resolveEffectiveCommandType(normalizedCommandType);
    final normalizedPrintColor = _normalizePrintColor(printColor);

    if (!_supportsCommandType(normalizedCommandType)) {
      _showMessage(
        context,
        'نوع الكوماند غير مدعوم. الأنواع المتاحة: Auto / ESC / TSPL / CPCL',
      );
      return;
    }
    final paperSize = _resolvePaperSize(paperWidth);
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);
    final textChunks = _splitTextIntoChunks(text);

    await PrintBluetoothThermal.disconnect;
    await requestBluetoothPermissions();

    final prePrintStatus = await _checkEscPosPrinterStatus(
      mac: mac,
      effectiveCommandType: effectiveCommandType,
    );
    if (prePrintStatus.hasBlockingIssue) {
      if (!context.mounted) return;
      _showMessage(
        context,
        'لا يمكن بدء الطباعة: ${prePrintStatus.issueSummary}',
      );
      return;
    }

    final connected = await PrintBluetoothThermal.connect(
      macPrinterAddress: mac,
    );
    if (!connected) {
      if (!context.mounted) return;
      _showMessage(context, 'فشل الاتصال بالطابعة عبر البلوتوث');
      return;
    }

    await _playBeepWithFallback(
      count: beepBefore,
      beepType: beepType,
      generator: generator,
    );

    for (var i = 0; i < textChunks.length; i++) {
      final image = await generateSimpleTextImage(
        textChunks[i],
        paperWidth,
        addBorder: textBorder,
        printerProfile: printerProfile,
        printColor: normalizedPrintColor,
        fontSize: textFontSize.toDouble(),
        fontFamily: textFontFamily,
      );
      final sentChunk = await _printImageByCommandType(
        commandType: effectiveCommandType,
        image: image,
        paperWidthMm: paperWidth,
        fitMode: fitMode,
        contentAlignment: contentAlignment,
        printerProfile: printerProfile,
        printColor: normalizedPrintColor,
        printRotationDegrees: printRotationDegrees,
        generator: generator,
      );
      if (!sentChunk) {
        await PrintBluetoothThermal.disconnect;
        if (!context.mounted) return;
        _showMessage(
          context,
          'فشل إرسال جزء من النص للطابعة. تأكد من وجود ورق وإغلاق الغطاء جيدًا.',
        );
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 160));
    }

    if (feedLines > 0) {
      final safeFeedLines = feedLines.clamp(0, 255).toInt();
      if (_isEscCommandType(effectiveCommandType)) {
        await PrintBluetoothThermal.writeBytes(generator.feed(safeFeedLines));
      } else {
        await PrintBluetoothThermal.writeBytes(
          List<int>.filled(safeFeedLines, 0x0A),
        );
      }
    }

    if (autoCut && _isEscCommandType(effectiveCommandType)) {
      await Future<void>.delayed(const Duration(milliseconds: 220));
      await PrintBluetoothThermal.writeBytes(<int>[...generator.cut()]);
    }

    await _playBeepWithFallback(
      count: beepAfter,
      beepType: beepType,
      generator: generator,
    );

    if (_isEscCommandType(effectiveCommandType)) {
      // Reset to black for next jobs by default.
      await PrintBluetoothThermal.writeBytes(_buildPrintColorBytes('black'));
    }

    await PrintBluetoothThermal.disconnect;
    final afterPrintStatus = await _checkEscPosPrinterStatus(
      mac: mac,
      effectiveCommandType: effectiveCommandType,
    );
    if (!context.mounted) return;
    _showMessage(context, _printAcceptedMessage(afterPrintStatus));
  } catch (e) {
    await PrintBluetoothThermal.disconnect;
    if (context.mounted) {
      _showMessage(context, 'حدث خطأ أثناء الطباعة: $e');
    }
  }
}

Future<void> printBluetoothPdfReceipt({
  required BuildContext context,
  required String pdfPath,
  required double paperWidth,
  required String mac,
  int beepBefore = 0,
  int beepAfter = 0,
  String beepType = '0x07',
  bool autoCut = false,
  int feedLines = 0,
  String fitMode = 'fit_width',
  String contentAlignment = 'center',
  String printerProfile = 'auto',
  String commandType = 'auto',
  String printColor = 'black',
  int printRotationDegrees = 0,
}) async {
  PdfDocument? document;

  try {
    final normalizedCommandType = _normalizeCommandType(commandType);
    final effectiveCommandType =
        _resolveEffectiveCommandType(normalizedCommandType);
    final normalizedPrintColor = _normalizePrintColor(printColor);

    if (!_supportsCommandType(normalizedCommandType)) {
      _showMessage(
        context,
        'نوع الكوماند غير مدعوم. الأنواع المتاحة: Auto / ESC / TSPL / CPCL',
      );
      return;
    }
    final paperSize = _resolvePaperSize(paperWidth);
    final rasterTargetWidth = _resolveRasterTargetWidth(
      paperWidth,
      printerProfile: printerProfile,
    );
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);

    document = await PdfDocument.openFile(pdfPath);

    await PrintBluetoothThermal.disconnect;
    await requestBluetoothPermissions();

    final prePrintStatus = await _checkEscPosPrinterStatus(
      mac: mac,
      effectiveCommandType: effectiveCommandType,
    );
    if (prePrintStatus.hasBlockingIssue) {
      if (!context.mounted) return;
      _showMessage(
        context,
        'لا يمكن بدء الطباعة: ${prePrintStatus.issueSummary}',
      );
      return;
    }

    final connected = await PrintBluetoothThermal.connect(
      macPrinterAddress: mac,
    );

    if (!connected) {
      if (!context.mounted) return;
      _showMessage(context, 'فشل الاتصال بالطابعة عبر البلوتوث');
      return;
    }

    await _playBeepWithFallback(
      count: beepBefore,
      beepType: beepType,
      generator: generator,
    );

    for (var pageNumber = 1; pageNumber <= document.pagesCount; pageNumber++) {
      final page = await document.getPage(pageNumber);
      try {
        final renderWidth = _isFitToWidthMode(fitMode)
            ? (rasterTargetWidth * 4).toDouble()
            : page.width.toDouble().clamp(300.0, 2400.0);
        final safePageWidth = page.width <= 0 ? 1.0 : page.width.toDouble();
        final safePageHeight = page.height.toDouble();
        final dynamicHeight =
            ((renderWidth * safePageHeight) / safePageWidth).clamp(300.0, 5000.0);

        final pageImage = await page.render(
          width: renderWidth,
          height: dynamicHeight,
          format: PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );

        if (pageImage == null) {
          continue;
        }

        final uiImage = await _decodeUiImage(pageImage.bytes);
        final sentPage = await _printImageByCommandType(
          commandType: effectiveCommandType,
          image: uiImage,
          paperWidthMm: paperWidth,
          fitMode: fitMode,
          contentAlignment: contentAlignment,
          printerProfile: printerProfile,
          printColor: normalizedPrintColor,
          printRotationDegrees: printRotationDegrees,
          generator: generator,
        );
        if (!sentPage) {
          await PrintBluetoothThermal.disconnect;
          if (!context.mounted) return;
          _showMessage(
            context,
            'فشل إرسال الصفحة $pageNumber للطابعة. تأكد من وجود ورق وإغلاق الغطاء جيدًا.',
          );
          return;
        }

        await Future<void>.delayed(const Duration(milliseconds: 120));
      } finally {
        await page.close();
      }
    }

    if (feedLines > 0) {
      final safeFeedLines = feedLines.clamp(0, 255).toInt();
      if (_isEscCommandType(effectiveCommandType)) {
        await PrintBluetoothThermal.writeBytes(generator.feed(safeFeedLines));
      } else {
        await PrintBluetoothThermal.writeBytes(
          List<int>.filled(safeFeedLines, 0x0A),
        );
      }
    }

    if (autoCut && _isEscCommandType(effectiveCommandType)) {
      await Future<void>.delayed(const Duration(milliseconds: 220));
      await PrintBluetoothThermal.writeBytes(<int>[...generator.cut()]);
    }

    await _playBeepWithFallback(
      count: beepAfter,
      beepType: beepType,
      generator: generator,
    );

    if (_isEscCommandType(effectiveCommandType)) {
      // Reset to black for next jobs by default.
      await PrintBluetoothThermal.writeBytes(_buildPrintColorBytes('black'));
    }

    await PrintBluetoothThermal.disconnect;
    final afterPrintStatus = await _checkEscPosPrinterStatus(
      mac: mac,
      effectiveCommandType: effectiveCommandType,
    );
    if (!context.mounted) return;
    _showMessage(context, _printAcceptedMessage(afterPrintStatus));
  } catch (e) {
    await PrintBluetoothThermal.disconnect;
    if (context.mounted) {
      _showMessage(context, 'حدث خطأ أثناء طباعة PDF: $e');
    }
  } finally {
    await document?.close();
  }
}

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
