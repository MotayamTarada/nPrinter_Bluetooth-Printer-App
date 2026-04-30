import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:pdfx/pdfx.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bluetooth_permission_service.dart';
import 'esc_pos_colored_text_service.dart';
import 'generate_image_service.dart';
import 'printer_status_service.dart';

Future<bool> requestBluetoothPermissions() async {
  return BluetoothPermissionService.ensureBluetoothPermission();
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

bool _isColorMode(String printColor) {
  final normalized = _normalizePrintColor(printColor);
  return normalized == 'red' || normalized == 'black_red';
}

enum PrinterModelProfile { gainschaB380 }

class PrinterColorProfile {
  const PrinterColorProfile({
    required this.name,
    required this.redCommands,
    required this.supportsRasterColorAttempt,
  });

  final String name;
  final List<List<int>> redCommands;
  final bool supportsRasterColorAttempt;
}

const String _dualColorPassAuto = 'auto';
const String _dualColorPassBlack = 'black';
const String _dualColorPassRed = 'red';
const String _printerLibraryName = 'print_bluetooth_thermal';
const String _workingWriteMethodName = 'PrintBluetoothThermal.writeBytes';
const String _messagePrintSuccess = 'تمت الطباعة بنجاح';
const String _messageTextRequired = 'الرجاء إدخال نص للطباعة';
const String _messageConnectionFailed = 'تعذر الاتصال بالطابعة';
const String _selectedRedCommandIndexKey = 'printer.selectedRedCommandIndex';

const PrinterColorProfile b380ColorProfile = PrinterColorProfile(
  name: 'Gainscha B380 / nPrinter',
  redCommands: <List<int>>[
    <int>[0x1B, 0x72, 0x01],
    <int>[0x1B, 0x63, 0x30, 0x01],
    <int>[0x1B, 0x72, 0x31],
  ],
  supportsRasterColorAttempt: true,
);

const PrinterModelProfile _activePrinterProfile =
    PrinterModelProfile.gainschaB380;

PrinterColorProfile getActivePrinterColorProfile({
  PrinterModelProfile profile = _activePrinterProfile,
}) {
  switch (profile) {
    case PrinterModelProfile.gainschaB380:
      return b380ColorProfile;
  }
}

List<List<int>> get _activeRedCommands {
  return getActivePrinterColorProfile().redCommands;
}

enum PrinterColorSupport {
  blackOnly,
  gainschaB380OfficialSdk,
  escPosBestEffort,
}

abstract class ColorPrintEngine {
  Future<bool> printMonochromeImageBlack(img.Image image);

  Future<bool> printMonochromeImageRed(img.Image image);

  Future<bool> printMonochromeLayersBlackRed({
    required img.Image blackLayer,
    required img.Image redLayer,
  });
}

typedef BlackPrintCallback = Future<bool> Function(img.Image image);
typedef RedPrintWithCommandCallback =
    Future<bool> Function(img.Image image, List<int> redCommand);

class BlackOnlyEngine implements ColorPrintEngine {
  BlackOnlyEngine({required BlackPrintCallback printBlack})
    : _printBlack = printBlack;

  final BlackPrintCallback _printBlack;

  @override
  Future<bool> printMonochromeImageBlack(img.Image image) {
    return _printBlack(image);
  }

  @override
  Future<bool> printMonochromeImageRed(img.Image image) async {
    return false;
  }

  @override
  Future<bool> printMonochromeLayersBlackRed({
    required img.Image blackLayer,
    required img.Image redLayer,
  }) async {
    if (!_hasInkPixels(blackLayer)) {
      return false;
    }
    return _printBlack(blackLayer);
  }
}

class EscPosBestEffortEngine implements ColorPrintEngine {
  EscPosBestEffortEngine({
    required BlackPrintCallback printBlack,
    required RedPrintWithCommandCallback printRedWithCommand,
    required List<List<int>> redCommands,
    required Future<void> Function(int index) onRedCommandSelected,
  }) : _printBlack = printBlack,
       _printRedWithCommand = printRedWithCommand,
       _redCommands = redCommands,
       _onRedCommandSelected = onRedCommandSelected;

  final BlackPrintCallback _printBlack;
  final RedPrintWithCommandCallback _printRedWithCommand;
  final List<List<int>> _redCommands;
  final Future<void> Function(int index) _onRedCommandSelected;

  @override
  Future<bool> printMonochromeImageBlack(img.Image image) {
    return _printBlack(image);
  }

  @override
  Future<bool> printMonochromeImageRed(img.Image image) async {
    if (!_hasInkPixels(image)) {
      return false;
    }
    for (final index in await _redCommandTryOrder()) {
      final ok = await _printRedWithCommand(image, _redCommands[index]);
      if (ok) {
        await _onRedCommandSelected(index);
        return true;
      }
    }
    return false;
  }

  @override
  Future<bool> printMonochromeLayersBlackRed({
    required img.Image blackLayer,
    required img.Image redLayer,
  }) async {
    final hasBlack = _hasInkPixels(blackLayer);
    final hasRed = _hasInkPixels(redLayer);
    if (!hasBlack && !hasRed) {
      return false;
    }

    if (hasBlack) {
      final blackOk = await _printBlack(blackLayer);
      if (!blackOk) {
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }

    if (!hasRed) {
      return true;
    }

    for (final index in await _redCommandTryOrder()) {
      final redOk = await _printRedWithCommand(redLayer, _redCommands[index]);
      if (!redOk) {
        continue;
      }
      await _onRedCommandSelected(index);
      return true;
    }

    return false;
  }
}

class GainschaB380OfficialEngine implements ColorPrintEngine {
  GainschaB380OfficialEngine({
    required this.mac,
    required this.fallbackEscPosEngine,
  });

  final String mac;
  final EscPosBestEffortEngine fallbackEscPosEngine;

  @override
  Future<bool> printMonochromeImageBlack(img.Image image) {
    return fallbackEscPosEngine.printMonochromeImageBlack(image);
  }

  @override
  Future<bool> printMonochromeImageRed(img.Image image) async {
    final officialOk = await _tryPrintViaOfficialSdk(
      mac: mac,
      image: image,
      printRed: true,
    );
    if (officialOk) {
      return true;
    }
    return fallbackEscPosEngine.printMonochromeImageRed(image);
  }

  @override
  Future<bool> printMonochromeLayersBlackRed({
    required img.Image blackLayer,
    required img.Image redLayer,
  }) async {
    if (!_hasInkPixels(blackLayer) && !_hasInkPixels(redLayer)) {
      return false;
    }

    if (_hasInkPixels(blackLayer)) {
      final blackOk = await fallbackEscPosEngine.printMonochromeImageBlack(
        blackLayer,
      );
      if (!blackOk) {
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }

    if (!_hasInkPixels(redLayer)) {
      return true;
    }

    final officialOk = await _tryPrintViaOfficialSdk(
      mac: mac,
      image: redLayer,
      printRed: true,
    );
    if (officialOk) {
      return true;
    }
    return fallbackEscPosEngine.printMonochromeImageRed(redLayer);
  }
}

const MethodChannel _gainschaB380ColorChannel = MethodChannel(
  'com.example.nprinter_bluetooth_only/gainscha_b380_color',
);

// Official SDK is not bundled in this repository yet.
// Until a native SDK package is linked, we keep best-effort color attempts.
const PrinterColorSupport _configuredColorSupport =
    PrinterColorSupport.escPosBestEffort;

Future<bool> _tryPrintViaOfficialSdk({
  required String mac,
  required img.Image image,
  required bool printRed,
}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return false;
  }

  try {
    final bytes = Uint8List.fromList(img.encodePng(image));
    final result =
        await _gainschaB380ColorChannel.invokeMethod<bool>(
          'printMonochromeLayer',
          <String, dynamic>{
            'mac': mac,
            'imagePngBytes': bytes,
            'printRed': printRed,
          },
        ) ??
        false;
    return result;
  } catch (_) {
    return false;
  }
}

List<int> getBlackCommand() {
  return const <int>[0x1B, 0x72, 0x00];
}

Future<int> _getSelectedRedCommandIndex() async {
  final prefs = await SharedPreferences.getInstance();
  final savedIndex = prefs.getInt(_selectedRedCommandIndexKey) ?? 0;
  if (savedIndex < 0 || savedIndex >= _activeRedCommands.length) {
    return 0;
  }
  return savedIndex;
}

Future<void> saveSelectedRedCommandIndex(int index) async {
  if (index < 0 || index >= _activeRedCommands.length) {
    return;
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_selectedRedCommandIndexKey, index);
}

Future<List<int>> getRedCommand() async {
  final index = await _getSelectedRedCommandIndex();
  return _activeRedCommands[index];
}

Future<List<int>> _redCommandTryOrder() async {
  final selectedIndex = await _getSelectedRedCommandIndex();
  final order = <int>[
    selectedIndex,
    for (var i = 0; i < _activeRedCommands.length; i++)
      if (i != selectedIndex) i,
  ];
  return order;
}

enum RawRedCommand { commandA, commandB, commandC }

extension RawRedCommandDetails on RawRedCommand {
  String get label {
    switch (this) {
      case RawRedCommand.commandA:
        return 'Red Command A';
      case RawRedCommand.commandB:
        return 'Red Command B';
      case RawRedCommand.commandC:
        return 'Red Command C';
    }
  }

  List<int> get bytes {
    switch (this) {
      case RawRedCommand.commandA:
        return const <int>[0x1B, 0x72, 0x01];
      case RawRedCommand.commandB:
        return const <int>[0x1B, 0x63, 0x30, 0x01];
      case RawRedCommand.commandC:
        return const <int>[0x1B, 0x72, 0x31];
    }
  }
}

void _debugPrinterLog(String message) {
  debugPrint('[nPrinter][printer] $message');
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
  return _messagePrintSuccess;
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
  if (normalized == 'black_red') {
    return 'black_red';
  }
  if (normalized == 'red' ||
      normalized == '1' ||
      normalized == '49' ||
      normalized == 'n=1') {
    return 'red';
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

List<int> _buildPrintColorBytes(String printColor, {List<int>? redCommand}) {
  final normalized = _normalizePrintColor(printColor);
  if (normalized == 'red') {
    return <int>[0x1D, 0x42, 0x00, ...(redCommand ?? _activeRedCommands.first)];
  }

  // ESC r n : two-color selection.
  // Standard ESC/POS mapping:
  //   n=0 -> black
  //   n=1 -> red
  // Also force reverse mode OFF before setting color to avoid white-on-color
  // artifacts if the printer state was changed by previous jobs/tools.
  return <int>[
    0x1D, 0x42, 0x00, // GS B 0: reverse off
    ...getBlackCommand(),
  ];
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

List<int> _buildEscBeepBytes({
  required int count,
  required Generator generator,
}) {
  if (count <= 0) {
    return const <int>[];
  }

  final bytes = <int>[];
  var remaining = count;
  while (remaining > 0) {
    final chunk = remaining > 9 ? 9 : remaining;
    bytes.addAll(generator.beep(n: chunk, duration: PosBeepDuration.beep200ms));
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

Future<bool> _writeUsingBlackPdfMethod(
  List<int> data, {
  required String methodName,
  String? printerAddress,
  bool useChunks = false,
  int chunkSize = 32,
  int delayMs = 150,
  RawRedCommand? redCommand,
}) async {
  final address = printerAddress ?? 'unknown';
  final connectionStatus = await PrintBluetoothThermal.connectionStatus;
  final firstBytes = data.take(30).toList(growable: false);
  _debugPrinterLog(
    'method=$methodName address=$address library=$_printerLibraryName '
    'dataLength=${data.length} writeMethod=$_workingWriteMethodName '
    'connectionStatus=$connectionStatus sendFormat=List<int> '
    'first30=$firstBytes selectedRedCommand=${redCommand?.label ?? 'none'} '
    'chunkMode=$useChunks stage=write_start',
  );

  if (data.isEmpty) {
    _debugPrinterLog(
      'method=$methodName address=$address success=true stage=write_empty',
    );
    return true;
  }

  if (!useChunks) {
    try {
      final payload = data.toList(growable: false);
      final success = await PrintBluetoothThermal.writeBytes(payload);
      _debugPrinterLog(
        'method=$methodName address=$address writeMethod=$_workingWriteMethodName '
        'sendFormat=${payload.runtimeType} success=$success stage=write_complete',
      );
      return success;
    } catch (e, stackTrace) {
      _debugPrinterLog(
        'method=$methodName address=$address writeMethod=$_workingWriteMethodName '
        'success=false stage=write_exception error=$e',
      );
      debugPrint(stackTrace.toString());
      rethrow;
    }
  }

  var chunkIndex = 0;
  for (int i = 0; i < data.length; i += chunkSize) {
    final end = (i + chunkSize > data.length) ? data.length : i + chunkSize;
    final chunk = data.sublist(i, end).toList(growable: false);
    _debugPrinterLog(
      'method=$methodName address=$address writeMethod=$_workingWriteMethodName '
      'chunkIndex=$chunkIndex chunkLength=${chunk.length} '
      'sendFormat=${chunk.runtimeType} first30=${chunk.take(30).toList(growable: false)} '
      'stage=chunk_write_start',
    );
    try {
      final success = await PrintBluetoothThermal.writeBytes(chunk);
      _debugPrinterLog(
        'method=$methodName address=$address writeMethod=$_workingWriteMethodName '
        'chunkIndex=$chunkIndex success=$success stage=chunk_write_complete',
      );
      if (!success) {
        return false;
      }
    } catch (e, stackTrace) {
      _debugPrinterLog(
        'method=$methodName address=$address writeMethod=$_workingWriteMethodName '
        'chunkIndex=$chunkIndex success=false stage=chunk_write_exception error=$e',
      );
      debugPrint(stackTrace.toString());
      rethrow;
    }
    await Future<void>.delayed(Duration(milliseconds: delayMs));
    chunkIndex++;
  }

  return true;
}

Future<bool> sendPrinterBytes(
  List<int> bytes, {
  String methodName = 'sendPrinterBytes',
  String? printerAddress,
  bool useChunks = false,
}) async {
  return _writeUsingBlackPdfMethod(
    bytes,
    methodName: methodName,
    printerAddress: printerAddress,
    useChunks: useChunks,
  );
}

Future<void> sendRawBytes(
  Uint8List data, {
  String methodName = 'sendRawBytes',
  String? printerAddress,
  bool useChunks = false,
  RawRedCommand? redCommand,
}) async {
  final effectiveMethodName = redCommand == null
      ? methodName
      : '$methodName.${redCommand.label}';
  final success = await sendPrinterBytes(
    data,
    methodName: effectiveMethodName,
    printerAddress: printerAddress,
    useChunks: useChunks,
  );
  if (!success) {
    throw Exception(
      'writeBytes returned false. method=$methodName library=$_printerLibraryName writeMethod=$_workingWriteMethodName',
    );
  }
}

Future<void> sendRawBytesExactlyLikeWorkingPdfPath(
  Uint8List data, {
  String methodName = 'sendRawBytesExactlyLikeWorkingPdfPath',
  String? printerAddress,
  bool useChunks = false,
  RawRedCommand? redCommand,
}) async {
  await sendRawBytes(
    data,
    methodName: methodName,
    printerAddress: printerAddress,
    useChunks: useChunks,
    redCommand: redCommand,
  );
}

Future<void> printPlainTextDirect(
  String text,
  PrintColorMode mode, {
  String? printerAddress,
}) async {
  _debugPrinterLog(
    'method=printPlainTextDirect address=${printerAddress ?? 'unknown'} '
    'mode=$mode textLength=${text.length} stage=blocked_raw_text',
  );
  throw UnsupportedError(
    'RAW text printing is disabled. Use printTextAsRasterImage instead.',
  );
}

Future<void> printMixedTextDirect(
  List<PrintPart> parts, {
  String? printerAddress,
}) async {
  _debugPrinterLog(
    'method=printMixedTextDirect address=${printerAddress ?? 'unknown'} '
    'parts=${parts.length} stage=blocked_raw_text',
  );
  throw UnsupportedError('Colored RAW text printing is disabled.');
}

Future<void> printRawColorTest({
  String? printerAddress,
  bool useChunks = false,
  RawRedCommand redCommand = RawRedCommand.commandA,
}) async {
  _debugPrinterLog(
    'method=printRawColorTest address=${printerAddress ?? 'unknown'} '
    'selectedRedCommand=${redCommand.label} useChunks=$useChunks '
    'stage=blocked_color',
  );
  throw UnsupportedError('RAW color test is disabled. Print black only.');
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

int _pixelLuminance(int r, int g, int b) {
  return ((r * 299) + (g * 587) + (b * 114)) ~/ 1000;
}

bool _isRedPixel(int r, int g, int b) {
  return r > 120 && r > g * 1.35 && r > b * 1.35;
}

bool _isBlackPixel(int r, int g, int b) {
  return r < 110 && g < 110 && b < 110;
}

img.Image createMonochromeLayer(img.Image source, {int threshold = 168}) {
  return _toBilevelImage(source, threshold: threshold);
}

img.Image createBlackLayer(img.Image source) {
  final output = img.Image(
    width: source.width,
    height: source.height,
    numChannels: 4,
  );
  img.fill(output, color: img.ColorRgba8(255, 255, 255, 255));

  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final pixel = source.getPixel(x, y);
      if (pixel.a.toInt() <= 8) {
        continue;
      }

      final r = pixel.r.toInt();
      final g = pixel.g.toInt();
      final b = pixel.b.toInt();
      if (_isBlackPixel(r, g, b)) {
        output.setPixelRgba(x, y, 0, 0, 0, 255);
      }
    }
  }

  return output;
}

img.Image createRedLayerAsMonochrome(img.Image source) {
  final output = img.Image(
    width: source.width,
    height: source.height,
    numChannels: 4,
  );
  img.fill(output, color: img.ColorRgba8(255, 255, 255, 255));

  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final pixel = source.getPixel(x, y);
      if (pixel.a.toInt() <= 8) {
        continue;
      }

      final r = pixel.r.toInt();
      final g = pixel.g.toInt();
      final b = pixel.b.toInt();
      if (_isRedPixel(r, g, b)) {
        output.setPixelRgba(x, y, 0, 0, 0, 255);
      }
    }
  }

  return output;
}

bool _hasInkPixels(img.Image source) {
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final pixel = source.getPixel(x, y);
      if (pixel.a.toInt() <= 8) {
        continue;
      }
      final luminance = _pixelLuminance(
        pixel.r.toInt(),
        pixel.g.toInt(),
        pixel.b.toInt(),
      );
      if (luminance < 240) {
        return true;
      }
    }
  }
  return false;
}

_DualColorLayers _splitDualColorLayers(img.Image source) {
  final blackLayer = createBlackLayer(source);
  final redLayer = createRedLayerAsMonochrome(source);
  return _DualColorLayers(
    blackLayer: blackLayer,
    redLayer: redLayer,
    hasBlackPixels: _hasInkPixels(blackLayer),
    hasRedPixels: _hasInkPixels(redLayer),
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

Uint8List _toMonochromeBitmapData(
  img.Image source, {
  bool blackPixelAsZero = false,
}) {
  final widthBytes = (source.width + 7) ~/ 8;
  final data = Uint8List(widthBytes * source.height);
  var offset = 0;

  for (var y = 0; y < source.height; y++) {
    for (var xByte = 0; xByte < widthBytes; xByte++) {
      var value = blackPixelAsZero ? 0xFF : 0x00;
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
          if (blackPixelAsZero) {
            value &= ~(0x80 >> bit);
          } else {
            value |= (0x80 >> bit);
          }
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
  int? density,
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
  // TSPL BITMAP expects black dots as 0-bits and white as 1-bits.
  final bitmapData = _toMonochromeBitmapData(image, blackPixelAsZero: true);
  final safeDensity = density?.clamp(0, 15).toInt();

  _appendAsciiLine(output, 'SIZE $sizeWidthMm mm,$heightMm mm');
  _appendAsciiLine(output, 'GAP 0 mm,0 mm');
  if (safeDensity != null) {
    _appendAsciiLine(output, 'DENSITY $safeDensity');
  }
  _appendAsciiLine(output, 'DIRECTION 1');
  _appendAsciiLine(output, 'REFERENCE 0,0');
  _appendAsciiLine(output, 'CLS');
  _appendAsciiRaw(output, 'BITMAP $xOffset,0,$widthBytes,${image.height},0,');
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
  _appendAsciiRaw(output, 'EG $widthBytes ${image.height} $xOffset 0 ');
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
  int? tsplDensity,
}) {
  if (commandType == 'tspl') {
    return _buildTsplBitmapJob(
      image: image,
      paperWidthMm: paperWidthMm,
      paperWidthDots: paperWidthDots,
      alignment: alignment,
      density: tsplDensity,
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
  int? tsplDensity,
}) async {
  for (final strip in _splitImageIntoStrips(image, maxStripHeight: 240)) {
    final bytes = _buildRawBitmapJob(
      commandType: commandType,
      image: strip,
      paperWidthMm: paperWidthMm,
      paperWidthDots: paperWidthDots,
      alignment: alignment,
      tsplDensity: tsplDensity,
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
  bool preferSharpResize = false,
  String printerProfile = 'auto',
  int printRotationDegrees = 0,
}) async {
  final byteData = await flutterImage.toByteData(
    format: ui.ImageByteFormat.png,
  );
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
  final mustResizeToPaperWidth = forceFitToPaperWidth
      ? rotatedImage.width != rasterTargetWidth
      : rotatedImage.width > rasterTargetWidth;

  return mustResizeToPaperWidth
      ? img.copyResize(
          rotatedImage,
          width: rasterTargetWidth,
          interpolation: preferSharpResize
              ? img.Interpolation.nearest
              : img.Interpolation.average,
        )
      : rotatedImage;
}

img.Image _toBilevelImage(img.Image source, {int threshold = 168}) {
  final output = img.Image(
    width: source.width,
    height: source.height,
    numChannels: 4,
  );
  img.fill(output, color: img.ColorRgba8(255, 255, 255, 255));

  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final pixel = source.getPixel(x, y);
      if (pixel.a.toInt() <= 8) {
        continue;
      }
      final luminance = _pixelLuminance(
        pixel.r.toInt(),
        pixel.g.toInt(),
        pixel.b.toInt(),
      );
      if (luminance < threshold) {
        output.setPixelRgba(x, y, 0, 0, 0, 255);
      }
    }
  }

  return output;
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

bool _containsSubsequence(List<int> source, List<int> sequence) {
  if (sequence.isEmpty) {
    return true;
  }
  if (source.length < sequence.length) {
    return false;
  }
  for (var i = 0; i <= source.length - sequence.length; i++) {
    var matches = true;
    for (var j = 0; j < sequence.length; j++) {
      if (source[i + j] != sequence[j]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      return true;
    }
  }
  return false;
}

Future<bool> printRasterImageWithColor({
  required img.Image image,
  required List<int> colorCommand,
  required double paperWidthMm,
  required Generator generator,
  String contentAlignment = 'center',
  String? debugPrinterAddress,
}) async {
  final align = _resolvePrintAlignment(contentAlignment);
  final rasterBytes = await _convertPreparedImageToEscPosBytes(
    image,
    paperWidthMm,
    align: align,
  );

  final hasResetInRaster =
      _containsSubsequence(rasterBytes, const <int>[0x1B, 0x40]) ||
      _containsSubsequence(rasterBytes, const <int>[0x1B, 0x72, 0x00]);
  if (hasResetInRaster) {
    final setColorOk = await sendPrinterBytes(
      <int>[...colorCommand],
      methodName: 'printRasterImageWithColor.setColor',
      printerAddress: debugPrinterAddress,
    );
    if (!setColorOk) {
      return false;
    }

    final rasterOk = await sendPrinterBytes(
      rasterBytes,
      methodName: 'printRasterImageWithColor.raster',
      printerAddress: debugPrinterAddress,
    );
    if (!rasterOk) {
      return false;
    }

    return sendPrinterBytes(
      <int>[...getBlackCommand(), 0x1B, 0x64, 0x02],
      methodName: 'printRasterImageWithColor.resetToBlack',
      printerAddress: debugPrinterAddress,
    );
  }

  final bytes = <int>[
    ...generator.reset(),
    ...colorCommand,
    ...rasterBytes,
    ...getBlackCommand(),
    0x1B,
    0x64,
    0x02,
  ];

  return sendPrinterBytes(
    bytes,
    methodName: 'printRasterImageWithColor',
    printerAddress: debugPrinterAddress,
  );
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
  String dualColorPass = _dualColorPassAuto,
  bool forceBilevel = false,
  int? tsplDensity,
  String? debugPrinterAddress,
  List<int>? redCommandBytes,
}) async {
  final preparedImage = await _prepareImageForCommand(
    image,
    paperWidthMm,
    forceFitToPaperWidth: _isFitToWidthMode(fitMode),
    preferSharpResize: forceBilevel,
    printerProfile: printerProfile,
    printRotationDegrees: printRotationDegrees,
  );
  final imageForPrint = forceBilevel
      ? _toBilevelImage(preparedImage)
      : preparedImage;
  if (_isEscCommandType(commandType)) {
    if (printColor == 'black_red') {
      final layers = _splitDualColorLayers(preparedImage);
      final shouldPrintBlack =
          dualColorPass == _dualColorPassAuto ||
          dualColorPass == _dualColorPassBlack;
      final shouldPrintRed =
          dualColorPass == _dualColorPassAuto ||
          dualColorPass == _dualColorPassRed;

      if (shouldPrintBlack && layers.hasBlackPixels) {
        final sentBlack = await printRasterImageWithColor(
          image: layers.blackLayer,
          colorCommand: getBlackCommand(),
          paperWidthMm: paperWidthMm,
          generator: generator,
          contentAlignment: contentAlignment,
          debugPrinterAddress: debugPrinterAddress,
        );
        if (!sentBlack) {
          return false;
        }
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }

      if (shouldPrintRed && layers.hasRedPixels) {
        final sentRed = await printRasterImageWithColor(
          image: layers.redLayer,
          colorCommand: redCommandBytes ?? await getRedCommand(),
          paperWidthMm: paperWidthMm,
          generator: generator,
          contentAlignment: contentAlignment,
          debugPrinterAddress: debugPrinterAddress,
        );
        if (!sentRed) {
          return false;
        }
      }

      return true;
    }

    final layerImage = printColor == 'black'
        ? imageForPrint
        : createMonochromeLayer(imageForPrint);
    return printRasterImageWithColor(
      image: layerImage,
      colorCommand: printColor == 'black'
          ? getBlackCommand()
          : (redCommandBytes ?? await getRedCommand()),
      paperWidthMm: paperWidthMm,
      generator: generator,
      contentAlignment: contentAlignment,
      debugPrinterAddress: debugPrinterAddress,
    );
  }

  final paperWidthDots = _resolveRasterTargetWidth(
    paperWidthMm,
    printerProfile: printerProfile,
  );

  if (printColor == 'black_red') {
    final layers = _splitDualColorLayers(preparedImage);
    final shouldPrintBlack =
        dualColorPass == _dualColorPassAuto ||
        dualColorPass == _dualColorPassBlack;
    final shouldPrintRed =
        dualColorPass == _dualColorPassAuto ||
        dualColorPass == _dualColorPassRed;
    if (shouldPrintBlack && layers.hasBlackPixels) {
      final sentBlack = await _printRawBitmapInStrips(
        commandType: commandType,
        image: layers.blackLayer,
        paperWidthMm: paperWidthMm,
        paperWidthDots: paperWidthDots,
        alignment: contentAlignment,
        tsplDensity: tsplDensity,
      );
      if (!sentBlack) {
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    if (shouldPrintRed && layers.hasRedPixels) {
      final sentRed = await _printRawBitmapInStrips(
        commandType: commandType,
        image: layers.redLayer,
        paperWidthMm: paperWidthMm,
        paperWidthDots: paperWidthDots,
        alignment: contentAlignment,
        tsplDensity: tsplDensity,
      );
      if (!sentRed) {
        return false;
      }
    }
    return true;
  }

  return _printRawBitmapInStrips(
    commandType: commandType,
    image: imageForPrint,
    paperWidthMm: paperWidthMm,
    paperWidthDots: paperWidthDots,
    alignment: contentAlignment,
    tsplDensity: tsplDensity,
  );
}

Future<bool> _printEscPosImageInBlack({
  required img.Image image,
  required double paperWidthMm,
  required String contentAlignment,
  required Generator generator,
  String? debugPrinterAddress,
}) async {
  final setBlackOk = await sendPrinterBytes(
    getBlackCommand(),
    methodName: '_printEscPosImageInBlack.setBlack',
    printerAddress: debugPrinterAddress,
  );
  if (!setBlackOk) {
    return false;
  }
  return printRasterImageWithColor(
    image: image,
    colorCommand: getBlackCommand(),
    paperWidthMm: paperWidthMm,
    generator: generator,
    contentAlignment: contentAlignment,
    debugPrinterAddress: debugPrinterAddress,
  );
}

Future<bool> _printEscPosImageInRed({
  required img.Image image,
  required List<int> redCommand,
  required double paperWidthMm,
  required String contentAlignment,
  required Generator generator,
  String? debugPrinterAddress,
}) async {
  final printed = await printRasterImageWithColor(
    image: image,
    colorCommand: redCommand,
    paperWidthMm: paperWidthMm,
    generator: generator,
    contentAlignment: contentAlignment,
    debugPrinterAddress: debugPrinterAddress,
  );
  if (!printed) {
    return false;
  }

  return sendPrinterBytes(
    getBlackCommand(),
    methodName: '_printEscPosImageInRed.resetBlack',
    printerAddress: debugPrinterAddress,
  );
}

Future<bool> _withWorkingEscPosConnection({
  required String mac,
  required double paperWidth,
  required String methodName,
  required Future<bool> Function(Generator generator) runJob,
  int beepBefore = 0,
  int beepAfter = 0,
  String beepType = '0x07',
  int feedLines = 0,
  bool autoCut = false,
}) async {
  try {
    final paperSize = _resolvePaperSize(paperWidth);
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);

    await PrintBluetoothThermal.disconnect;
    final hasBluetoothPermissions = await requestBluetoothPermissions();
    if (!hasBluetoothPermissions) {
      return false;
    }

    final prePrintStatus = await _checkEscPosPrinterStatus(
      mac: mac,
      effectiveCommandType: 'esc',
    );
    if (prePrintStatus.hasBlockingIssue) {
      return false;
    }

    final connected = await PrintBluetoothThermal.connect(
      macPrinterAddress: mac,
    );
    if (!connected) {
      return false;
    }

    await _playBeepWithFallback(
      count: beepBefore,
      beepType: beepType,
      generator: generator,
    );

    final jobOk = await runJob(generator);
    if (!jobOk) {
      await PrintBluetoothThermal.disconnect;
      return false;
    }

    final safeFeedLines = feedLines.clamp(0, 255).toInt();
    if (safeFeedLines > 0) {
      final feedOk = await sendPrinterBytes(
        generator.feed(safeFeedLines),
        methodName: '$methodName.feed',
        printerAddress: mac,
      );
      if (!feedOk) {
        await PrintBluetoothThermal.disconnect;
        return false;
      }
    }

    if (autoCut) {
      await Future<void>.delayed(const Duration(milliseconds: 220));
      final cutOk = await sendPrinterBytes(
        <int>[...generator.cut()],
        methodName: '$methodName.cut',
        printerAddress: mac,
      );
      if (!cutOk) {
        await PrintBluetoothThermal.disconnect;
        return false;
      }
    }

    await _playBeepWithFallback(
      count: beepAfter,
      beepType: beepType,
      generator: generator,
    );
    final resetColorOk = await sendPrinterBytes(
      _buildPrintColorBytes('black'),
      methodName: '$methodName.finishBlack',
      printerAddress: mac,
    );
    if (!resetColorOk) {
      await PrintBluetoothThermal.disconnect;
      return false;
    }
    await PrintBluetoothThermal.disconnect;
    return true;
  } catch (e, stackTrace) {
    _debugPrinterLog(
      'method=$methodName address=$mac success=false stage=exception error=$e',
    );
    debugPrint(stackTrace.toString());
    await PrintBluetoothThermal.disconnect;
    return false;
  }
}

Future<List<img.Image>> _renderPdfToPreparedImages({
  required String pdfPath,
  required double paperWidth,
  required String fitMode,
  required String printerProfile,
  required int printRotationDegrees,
}) async {
  PdfDocument? document;
  final pages = <img.Image>[];

  try {
    final rasterTargetWidth = _resolveRasterTargetWidth(
      paperWidth,
      printerProfile: printerProfile,
    );
    final pdfDocument = await PdfDocument.openFile(pdfPath);
    document = pdfDocument;

    for (
      var pageNumber = 1;
      pageNumber <= pdfDocument.pagesCount;
      pageNumber++
    ) {
      final page = await pdfDocument.getPage(pageNumber);
      try {
        final renderWidth = _isFitToWidthMode(fitMode)
            ? (rasterTargetWidth * 4).toDouble()
            : page.width.toDouble().clamp(300.0, 2400.0);
        final safePageWidth = page.width <= 0 ? 1.0 : page.width.toDouble();
        final safePageHeight = page.height.toDouble();
        final dynamicHeight = ((renderWidth * safePageHeight) / safePageWidth)
            .clamp(300.0, 5000.0);

        final pageImage = await page.render(
          width: renderWidth,
          height: dynamicHeight,
          format: PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );
        if (pageImage == null) {
          continue;
        }

        final decoded = img.decodeImage(pageImage.bytes);
        if (decoded == null) {
          continue;
        }

        final rotated = _applyPrintRotation(decoded, printRotationDegrees);
        final prepared = _isFitToWidthMode(fitMode)
            ? img.copyResize(
                rotated,
                width: rasterTargetWidth,
                interpolation: img.Interpolation.average,
              )
            : (rotated.width > rasterTargetWidth
                  ? img.copyResize(
                      rotated,
                      width: rasterTargetWidth,
                      interpolation: img.Interpolation.average,
                    )
                  : rotated);
        pages.add(prepared);
      } finally {
        await page.close();
      }
    }

    return pages;
  } finally {
    await document?.close();
  }
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
    final normalizedText = text.trim();
    if (normalizedText.isEmpty) {
      _showMessage(context, _messageTextRequired);
      return;
    }
    final normalizedCommandType = _normalizeCommandType(commandType);
    var effectiveCommandType = _resolveEffectiveCommandType(
      normalizedCommandType,
    );
    final normalizedRequestedPrintColor = _normalizePrintColor(printColor);
    const normalizedPrintColor = 'black';
    if (normalizedRequestedPrintColor != 'black') {
      _debugPrinterLog(
        'method=printBluetoothReceipt address=$mac '
        'requestedMode=$normalizedRequestedPrintColor stage=force_black_path',
      );
    }

    if (!_supportsCommandType(normalizedCommandType)) {
      _showMessage(context, _messageConnectionFailed);
      return;
    }

    if (!_isEscCommandType(effectiveCommandType)) {
      effectiveCommandType = 'esc';
    }
    final paperSize = _resolvePaperSize(paperWidth);
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);
    final textChunks = _splitTextIntoChunks(normalizedText);

    await PrintBluetoothThermal.disconnect;
    final hasBluetoothPermissions = await requestBluetoothPermissions();
    if (!hasBluetoothPermissions) {
      if (!context.mounted) return;
      _showMessage(context, _messageConnectionFailed);
      return;
    }

    final prePrintStatus = await _checkEscPosPrinterStatus(
      mac: mac,
      effectiveCommandType: effectiveCommandType,
    );
    if (prePrintStatus.hasBlockingIssue) {
      if (!context.mounted) return;
      _showMessage(context, _messageConnectionFailed);
      return;
    }

    final connected = await PrintBluetoothThermal.connect(
      macPrinterAddress: mac,
    );
    if (!connected) {
      if (!context.mounted) return;
      _showMessage(context, _messageConnectionFailed);
      return;
    }

    await _playBeepWithFallback(
      count: beepBefore,
      beepType: beepType,
      generator: generator,
    );

    Future<bool> printTextChunksForPass(String dualColorPass) async {
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
          dualColorPass: dualColorPass,
          forceBilevel: true,
        );
        if (!sentChunk) {
          return false;
        }
        await Future<void>.delayed(const Duration(milliseconds: 160));
      }
      return true;
    }

    final isDualColorJob = normalizedPrintColor == 'black_red';
    final sentText = isDualColorJob
        ? await printTextChunksForPass(_dualColorPassBlack)
        : await printTextChunksForPass(_dualColorPassAuto);
    if (!sentText) {
      await PrintBluetoothThermal.disconnect;
      if (!context.mounted) return;
      _showMessage(context, _messageConnectionFailed);
      return;
    }
    if (isDualColorJob) {
      await Future<void>.delayed(const Duration(milliseconds: 180));
      final sentRedText = await printTextChunksForPass(_dualColorPassRed);
      if (!sentRedText) {
        await PrintBluetoothThermal.disconnect;
        if (!context.mounted) return;
        _showMessage(context, _messageConnectionFailed);
        return;
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
      _showMessage(context, _messageConnectionFailed);
    }
  }
}

Future<void> printBluetoothColorTest({
  required BuildContext context,
  required String mac,
  EscPosTextEncoding textEncoding = EscPosTextEncoding.windows1256,
  bool useAlternativeRedCommand = false,
}) async {
  _debugPrinterLog(
    'method=printBluetoothColorTest address=$mac textEncoding=$textEncoding '
    'useAlternativeRedCommand=$useAlternativeRedCommand stage=blocked_color',
  );
  _showMessage(context, _messageConnectionFailed);
}

Future<bool> sendRawBytesUsingWorkingConnection(
  List<int> bytes, {
  required String mac,
  required double paperWidth,
  int beepBefore = 0,
  int beepAfter = 0,
  String beepType = '0x07',
  String methodName = 'sendRawBytesUsingWorkingConnection',
}) async {
  return _withWorkingEscPosConnection(
    mac: mac,
    paperWidth: paperWidth,
    methodName: methodName,
    beepBefore: beepBefore,
    beepAfter: beepAfter,
    beepType: beepType,
    runJob: (_) async {
      return sendPrinterBytes(
        bytes,
        methodName: methodName,
        printerAddress: mac,
      );
    },
  );
}

ColorPrintEngine _createColorPrintEngine({
  required String mac,
  required BlackPrintCallback printBlack,
  required RedPrintWithCommandCallback printRedWithCommand,
}) {
  final escPosEngine = EscPosBestEffortEngine(
    printBlack: printBlack,
    printRedWithCommand: printRedWithCommand,
    redCommands: _activeRedCommands,
    onRedCommandSelected: saveSelectedRedCommandIndex,
  );

  switch (_configuredColorSupport) {
    case PrinterColorSupport.blackOnly:
      return BlackOnlyEngine(printBlack: printBlack);
    case PrinterColorSupport.gainschaB380OfficialSdk:
      return GainschaB380OfficialEngine(
        mac: mac,
        fallbackEscPosEngine: escPosEngine,
      );
    case PrinterColorSupport.escPosBestEffort:
      return escPosEngine;
  }
}

Future<bool> printRedTextWithFallbackCommands({
  required String text,
  required String mac,
  required double paperWidth,
  EscPosTextEncoding textEncoding = EscPosTextEncoding.windows1256,
  int beepBefore = 0,
  int beepAfter = 0,
  String beepType = '0x07',
  int feedLines = 0,
  bool autoCut = false,
  bool textBorder = false,
  String fitMode = 'fit_width',
  String contentAlignment = 'center',
  String printerProfile = 'auto',
  int printRotationDegrees = 0,
  int textFontSize = 26,
  String textFontFamily = 'NotoKufiArabicBold',
}) async {
  final normalizedText = text.trim();
  if (normalizedText.isEmpty) {
    return false;
  }

  final textImage = await generateSimpleTextImage(
    normalizedText,
    paperWidth,
    addBorder: textBorder,
    printerProfile: printerProfile,
    printColor: 'black',
    fontSize: textFontSize.toDouble(),
    fontFamily: textFontFamily,
  );
  final preparedTextImage = await _prepareImageForCommand(
    textImage,
    paperWidth,
    forceFitToPaperWidth: _isFitToWidthMode(fitMode),
    preferSharpResize: true,
    printerProfile: printerProfile,
    printRotationDegrees: printRotationDegrees,
  );
  final monochromeLayer = createMonochromeLayer(preparedTextImage);
  if (!_hasInkPixels(monochromeLayer)) {
    return false;
  }

  return _withWorkingEscPosConnection(
    mac: mac,
    paperWidth: paperWidth,
    methodName: 'printRedTextWithFallbackCommands',
    beepBefore: beepBefore,
    beepAfter: beepAfter,
    beepType: beepType,
    feedLines: feedLines,
    autoCut: autoCut,
    runJob: (generator) async {
      final engine = _createColorPrintEngine(
        mac: mac,
        printBlack: (layer) {
          return _printEscPosImageInBlack(
            image: layer,
            paperWidthMm: paperWidth,
            contentAlignment: contentAlignment,
            generator: generator,
            debugPrinterAddress: mac,
          );
        },
        printRedWithCommand: (layer, redCommand) {
          return _printEscPosImageInRed(
            image: layer,
            redCommand: redCommand,
            paperWidthMm: paperWidth,
            contentAlignment: contentAlignment,
            generator: generator,
            debugPrinterAddress: mac,
          );
        },
      );
      return engine.printMonochromeImageRed(monochromeLayer);
    },
  );
}

Future<bool> printMixedTextWithFallbackCommands({
  required List<PrintPart> parts,
  required String mac,
  required double paperWidth,
  EscPosTextEncoding textEncoding = EscPosTextEncoding.windows1256,
  int beepBefore = 0,
  int beepAfter = 0,
  String beepType = '0x07',
  int feedLines = 0,
  bool autoCut = false,
  bool textBorder = false,
  String fitMode = 'fit_width',
  String contentAlignment = 'center',
  String printerProfile = 'auto',
  int printRotationDegrees = 0,
  int textFontSize = 26,
  String textFontFamily = 'NotoKufiArabicBold',
}) async {
  final effectiveParts = parts
      .where((part) => part.text.isNotEmpty)
      .toList(growable: false);
  if (effectiveParts.isEmpty) {
    return false;
  }

  final blackLayerImage = await generateTaggedTextLayerImage(
    effectiveParts,
    paperWidth,
    redLayer: false,
    addBorder: textBorder,
    printerProfile: printerProfile,
    fontSize: textFontSize.toDouble(),
    fontFamily: textFontFamily,
  );
  final redLayerImage = await generateTaggedTextLayerImage(
    effectiveParts,
    paperWidth,
    redLayer: true,
    addBorder: textBorder,
    printerProfile: printerProfile,
    fontSize: textFontSize.toDouble(),
    fontFamily: textFontFamily,
  );

  final preparedBlackLayer = await _prepareImageForCommand(
    blackLayerImage,
    paperWidth,
    forceFitToPaperWidth: _isFitToWidthMode(fitMode),
    preferSharpResize: true,
    printerProfile: printerProfile,
    printRotationDegrees: printRotationDegrees,
  );
  final preparedRedLayer = await _prepareImageForCommand(
    redLayerImage,
    paperWidth,
    forceFitToPaperWidth: _isFitToWidthMode(fitMode),
    preferSharpResize: true,
    printerProfile: printerProfile,
    printRotationDegrees: printRotationDegrees,
  );

  final blackLayer = createMonochromeLayer(preparedBlackLayer);
  final redLayer = createMonochromeLayer(preparedRedLayer);
  final hasBlackPixels = _hasInkPixels(blackLayer);
  final hasRedPixels = _hasInkPixels(redLayer);
  if (!hasBlackPixels && !hasRedPixels) {
    return false;
  }

  return _withWorkingEscPosConnection(
    mac: mac,
    paperWidth: paperWidth,
    methodName: 'printMixedTextWithFallbackCommands',
    beepBefore: beepBefore,
    beepAfter: beepAfter,
    beepType: beepType,
    feedLines: feedLines,
    autoCut: autoCut,
    runJob: (generator) async {
      final engine = _createColorPrintEngine(
        mac: mac,
        printBlack: (layer) {
          return _printEscPosImageInBlack(
            image: layer,
            paperWidthMm: paperWidth,
            contentAlignment: contentAlignment,
            generator: generator,
            debugPrinterAddress: mac,
          );
        },
        printRedWithCommand: (layer, redCommand) {
          return _printEscPosImageInRed(
            image: layer,
            redCommand: redCommand,
            paperWidthMm: paperWidth,
            contentAlignment: contentAlignment,
            generator: generator,
            debugPrinterAddress: mac,
          );
        },
      );
      return engine.printMonochromeLayersBlackRed(
        blackLayer: blackLayer,
        redLayer: redLayer,
      );
    },
  );
}

Future<bool> printPdfWithColorFallbackCommands({
  required BuildContext context,
  required String pdfPath,
  required double paperWidth,
  required String mac,
  required String printColor,
  int beepBefore = 0,
  int beepAfter = 0,
  String beepType = '0x07',
  bool autoCut = false,
  int feedLines = 0,
  String fitMode = 'fit_width',
  String contentAlignment = 'center',
  String printerProfile = 'auto',
  String commandType = 'auto',
  int printRotationDegrees = 0,
}) async {
  if (!context.mounted) return false;
  final normalizedPrintColor = _normalizePrintColor(printColor);
  if (!_isColorMode(normalizedPrintColor)) {
    return false;
  }

  final activeProfile = getActivePrinterColorProfile();
  if (!activeProfile.supportsRasterColorAttempt) {
    return false;
  }

  final normalizedCommandType = _normalizeCommandType(commandType);
  if (!_supportsCommandType(normalizedCommandType)) {
    return false;
  }

  final preparedPages = await _renderPdfToPreparedImages(
    pdfPath: pdfPath,
    paperWidth: paperWidth,
    fitMode: fitMode,
    printerProfile: printerProfile,
    printRotationDegrees: printRotationDegrees,
  );
  if (preparedPages.isEmpty) {
    return false;
  }

  return _withWorkingEscPosConnection(
    mac: mac,
    paperWidth: paperWidth,
    methodName: 'printPdfWithColorFallbackCommands',
    beepBefore: beepBefore,
    beepAfter: beepAfter,
    beepType: beepType,
    feedLines: feedLines,
    autoCut: autoCut,
    runJob: (generator) async {
      final engine = _createColorPrintEngine(
        mac: mac,
        printBlack: (layer) {
          return _printEscPosImageInBlack(
            image: layer,
            paperWidthMm: paperWidth,
            contentAlignment: contentAlignment,
            generator: generator,
            debugPrinterAddress: mac,
          );
        },
        printRedWithCommand: (layer, redCommand) {
          return _printEscPosImageInRed(
            image: layer,
            redCommand: redCommand,
            paperWidthMm: paperWidth,
            contentAlignment: contentAlignment,
            generator: generator,
            debugPrinterAddress: mac,
          );
        },
      );

      for (final pageImage in preparedPages) {
        if (normalizedPrintColor == 'red') {
          final monoLayer = createMonochromeLayer(pageImage);
          if (!_hasInkPixels(monoLayer)) {
            continue;
          }
          final redOk = await engine.printMonochromeImageRed(monoLayer);
          if (!redOk) {
            return false;
          }
          await Future<void>.delayed(const Duration(milliseconds: 60));
          continue;
        }

        final blackLayer = createBlackLayer(pageImage);
        final redLayer = createRedLayerAsMonochrome(pageImage);
        final layersOk = await engine.printMonochromeLayersBlackRed(
          blackLayer: blackLayer,
          redLayer: redLayer,
        );
        if (!layersOk) {
          return false;
        }
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }

      return true;
    },
  );
}

Future<void> printBluetoothPlainTextDirect({
  required BuildContext context,
  required String text,
  required String mac,
  required PrintColorMode mode,
}) async {
  if (mode != PrintColorMode.black) {
    _showMessage(context, _messageConnectionFailed);
    return;
  }

  await printTextAsRasterImage(
    context: context,
    text: text,
    paperWidth: 58,
    mac: mac,
  );
}

Future<void> printBluetoothMixedTextDirect({
  required BuildContext context,
  required List<PrintPart> parts,
  required String mac,
}) async {
  _debugPrinterLog(
    'method=printMixedTextDirect address=$mac parts=${parts.length} '
    'stage=blocked_color_text',
  );
  _showMessage(context, _messageConnectionFailed);
}

Future<void> printBluetoothRawColorTest({
  required BuildContext context,
  required String mac,
  RawRedCommand redCommand = RawRedCommand.commandA,
}) async {
  _debugPrinterLog(
    'method=printRawColorTest address=$mac library=$_printerLibraryName '
    'selectedRedCommand=${redCommand.label} stage=blocked_color',
  );
  _showMessage(context, _messageConnectionFailed);
}

Future<bool> printBluetoothPdfReceipt({
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
  bool showMessages = true,
  List<int>? redCommandBytes,
}) async {
  PdfDocument? document;

  try {
    const normalizedCommandType = 'esc';
    const effectiveCommandType = 'esc';
    final normalizedPrintColor = _normalizePrintColor(printColor);
    if (!context.mounted) return false;
    _debugPrinterLog(
      'method=printBlackPdf address=$mac library=$_printerLibraryName '
      'mode=$normalizedPrintColor selectedWriteMethod=$_workingWriteMethodName '
      'stage=start',
    );

    if (normalizedPrintColor != 'black') {
      _debugPrinterLog(
        'method=printBlackPdf address=$mac mode=$normalizedPrintColor '
        'stage=blocked_non_black_mode',
      );
      if (showMessages && context.mounted) {
        _showMessage(context, _messageConnectionFailed);
      }
      return false;
    }

    if (!_supportsCommandType(normalizedCommandType)) {
      if (showMessages) {
        _showMessage(context, _messageConnectionFailed);
      }
      return false;
    }

    final paperSize = _resolvePaperSize(paperWidth);
    final rasterTargetWidth = _resolveRasterTargetWidth(
      paperWidth,
      printerProfile: printerProfile,
    );
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);

    final pdfDocument = await PdfDocument.openFile(pdfPath);
    document = pdfDocument;

    _debugPrinterLog('method=printBlackPdf address=$mac stage=connect_start');
    await PrintBluetoothThermal.disconnect;
    final hasBluetoothPermissions = await requestBluetoothPermissions();
    if (!hasBluetoothPermissions) {
      if (context.mounted && showMessages) {
        _showMessage(context, _messageConnectionFailed);
      }
      return false;
    }

    final prePrintStatus = await _checkEscPosPrinterStatus(
      mac: mac,
      effectiveCommandType: effectiveCommandType,
    );
    if (prePrintStatus.hasBlockingIssue) {
      if (context.mounted && showMessages) {
        _showMessage(context, _messageConnectionFailed);
      }
      return false;
    }

    final connected = await PrintBluetoothThermal.connect(
      macPrinterAddress: mac,
    );
    _debugPrinterLog(
      'method=printBlackPdf address=$mac success=$connected stage=connect_complete',
    );

    if (!connected) {
      if (context.mounted && showMessages) {
        _showMessage(context, _messageConnectionFailed);
      }
      return false;
    }

    await _playBeepWithFallback(
      count: beepBefore,
      beepType: beepType,
      generator: generator,
    );

    Future<bool> printPdfPagesForPass(String dualColorPass) async {
      for (
        var pageNumber = 1;
        pageNumber <= pdfDocument.pagesCount;
        pageNumber++
      ) {
        final page = await pdfDocument.getPage(pageNumber);
        try {
          final renderWidth = _isFitToWidthMode(fitMode)
              ? (rasterTargetWidth * 4).toDouble()
              : page.width.toDouble().clamp(300.0, 2400.0);
          final safePageWidth = page.width <= 0 ? 1.0 : page.width.toDouble();
          final safePageHeight = page.height.toDouble();
          final dynamicHeight = ((renderWidth * safePageHeight) / safePageWidth)
              .clamp(300.0, 5000.0);

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
            printColor: 'black',
            printRotationDegrees: printRotationDegrees,
            generator: generator,
            dualColorPass: dualColorPass,
            debugPrinterAddress: mac,
            redCommandBytes: redCommandBytes,
          );
          if (!sentPage) {
            return false;
          }

          await Future<void>.delayed(const Duration(milliseconds: 120));
        } finally {
          await page.close();
        }
      }
      return true;
    }

    final sentPdf = await printPdfPagesForPass(_dualColorPassAuto);
    if (!sentPdf) {
      await PrintBluetoothThermal.disconnect;
      if (context.mounted && showMessages) {
        _showMessage(context, _messageConnectionFailed);
      }
      return false;
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
    if (!context.mounted) return false;
    if (showMessages) {
      _showMessage(context, _printAcceptedMessage(afterPrintStatus));
    }
    return true;
  } catch (e, stackTrace) {
    _debugPrinterLog(
      'method=printBlackPdf address=$mac success=false stage=exception error=$e',
    );
    debugPrint(stackTrace.toString());
    await PrintBluetoothThermal.disconnect;
    if (context.mounted && showMessages) {
      _showMessage(context, _messageConnectionFailed);
    }
    return false;
  } finally {
    await document?.close();
  }
}

Future<void> printTextAsRasterImage({
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
  int printRotationDegrees = 0,
  int textFontSize = 26,
  String textFontFamily = 'NotoKufiArabicBold',
}) async {
  try {
    final message = text.trim();
    if (message.isEmpty) {
      _showMessage(context, _messageTextRequired);
      return;
    }
    const normalizedCommandType = 'esc';
    const effectiveCommandType = 'esc';

    _debugPrinterLog(
      'method=printTextAsRasterImage address=$mac library=$_printerLibraryName '
      'selectedWriteMethod=$_workingWriteMethodName textLength=${message.length} '
      'stage=start',
    );

    if (!_supportsCommandType(normalizedCommandType)) {
      _showMessage(context, _messageConnectionFailed);
      return;
    }

    final paperSize = _resolvePaperSize(paperWidth);
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);
    final textChunks = _splitTextIntoChunks(message);

    await PrintBluetoothThermal.disconnect;
    final hasBluetoothPermissions = await requestBluetoothPermissions();
    if (!hasBluetoothPermissions) {
      if (!context.mounted) return;
      _showMessage(context, _messageConnectionFailed);
      return;
    }

    final prePrintStatus = await _checkEscPosPrinterStatus(
      mac: mac,
      effectiveCommandType: effectiveCommandType,
    );
    if (prePrintStatus.hasBlockingIssue) {
      if (!context.mounted) return;
      _showMessage(context, _messageConnectionFailed);
      return;
    }

    _debugPrinterLog(
      'method=printTextAsRasterImage address=$mac stage=connect_start',
    );
    final connected = await PrintBluetoothThermal.connect(
      macPrinterAddress: mac,
    );
    _debugPrinterLog(
      'method=printTextAsRasterImage address=$mac success=$connected '
      'stage=connect_complete',
    );
    if (!connected) {
      if (!context.mounted) return;
      _showMessage(context, _messageConnectionFailed);
      return;
    }

    await _playBeepWithFallback(
      count: beepBefore,
      beepType: beepType,
      generator: generator,
    );

    for (var i = 0; i < textChunks.length; i++) {
      _debugPrinterLog(
        'method=printTextAsRasterImage address=$mac chunkIndex=$i '
        'chunkTextLength=${textChunks[i].length} stage=rasterize_start',
      );
      final image = await generateSimpleTextImage(
        textChunks[i],
        paperWidth,
        addBorder: textBorder,
        printerProfile: printerProfile,
        printColor: 'black',
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
        printColor: 'black',
        printRotationDegrees: printRotationDegrees,
        generator: generator,
        dualColorPass: _dualColorPassAuto,
        forceBilevel: true,
        debugPrinterAddress: mac,
      );
      if (!sentChunk) {
        await PrintBluetoothThermal.disconnect;
        if (!context.mounted) return;
        _showMessage(context, _messageConnectionFailed);
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
      await PrintBluetoothThermal.writeBytes(_buildPrintColorBytes('black'));
    }

    await PrintBluetoothThermal.disconnect;
    final afterPrintStatus = await _checkEscPosPrinterStatus(
      mac: mac,
      effectiveCommandType: effectiveCommandType,
    );
    _debugPrinterLog(
      'method=printTextAsRasterImage address=$mac success=true '
      'statusChecked=${afterPrintStatus.checked} stage=complete',
    );
    if (!context.mounted) return;
    _showMessage(context, _messagePrintSuccess);
  } catch (e, stackTrace) {
    _debugPrinterLog(
      'method=printTextAsRasterImage address=$mac success=false '
      'stage=exception error=$e',
    );
    debugPrint(stackTrace.toString());
    await PrintBluetoothThermal.disconnect;
    if (context.mounted) {
      _showMessage(context, _messageConnectionFailed);
    }
  }
}

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
