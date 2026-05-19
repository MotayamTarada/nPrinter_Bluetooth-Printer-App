import 'dart:async';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/bluetooth_devices_scan_page.dart';
import '../services/bluetooth_printer_service.dart';
import '../services/esc_pos_colored_text_service.dart';
import '../services/pdf_intent_service.dart';
import '../widgets/barcode_scanner_dialog.dart';

class BluetoothPrinterHomePage extends StatefulWidget {
  const BluetoothPrinterHomePage({super.key});

  @override
  State<BluetoothPrinterHomePage> createState() =>
      _BluetoothPrinterHomePageState();
}

class _BluetoothPrinterHomePageState extends State<BluetoothPrinterHomePage> {
  static const String _paperWidthKey = 'printer.paperWidth';
  static const String _macAddressKey = 'printer.macAddress';
  static const String _beepBeforeKey = 'printer.beepBefore';
  static const String _beepAfterKey = 'printer.beepAfter';
  static const String _feedLinesKey = 'printer.feedLines';
  static const String _beepTypeKey = 'printer.beepType';
  static const String _cutPaperKey = 'printer.cutPaper';
  static const String _textBorderKey = 'printer.textBorder';
  static const String _fitModeKey = 'printer.fitMode';
  static const String _contentAlignmentKey = 'printer.contentAlignment';
  static const String _printColorKey = 'printer.printColor';
  static const String _textEncodingKey = 'printer.textEncoding';
  static const String _printRotationKey = 'printer.printRotation';
  static const String _commandTypeKey = 'printer.commandType';
  static const String _printTextKey = 'printer.printText';
  static const String _customPaperWidthKey = 'printer.customPaperWidth';
  static const String _defaultPrintText = 'nPrinter';
  static const String _messagePrintSuccess = 'تمت الطباعة بنجاح';
  static const String _messageTextRequired = 'الرجاء إدخال نص للطباعة';
  static const String _messageRedFallback =
      'تعذر طباعة الأحمر. سيتم الطباعة بالأسود.';
  static const String _messageBlackRedFallback =
      'تعذر طباعة الأسود والأحمر. سيتم الطباعة بالأسود.';
  static const String _messagePdfRedFallback =
      'تعذر طباعة PDF بالأحمر. سيتم الطباعة بالأسود.';
  static const String _messagePdfColorFallback =
      'تعذر طباعة PDF بالألوان. سيتم الطباعة بالأسود.';
  static const String _textFontSizeKey = 'printer.textFontSize';
  static const String _textFontFamilyKey = 'printer.textFontFamily';
  static const String _customPaperWidthValue = 'custom';
  static const String _defaultCustomPaperWidth = '112';
  static const List<String> _allowedPaperWidths = <String>[
    '58',
    '80',
    '112',
    _customPaperWidthValue,
  ];
  static const List<String> _allowedBeepTypes = <String>[
    '0x07',
    '0x1B, 0x42',
    '- لا يوجد',
  ];
  static const List<String> _allowedTextFontFamilies = <String>[
    'NotoKufiArabicBold',
    'Tajawal',
    'Cairo',
    'Almarai',
    'Changa',
    'Amiri',
    'ReemKufi',
  ];
  static const List<String> _allowedFitModes = <String>[
    'fit_width',
    'original',
  ];
  static const List<String> _allowedAlignments = <String>[
    'center',
    'right',
    'left',
  ];
  static const List<String> _allowedPrintColors = <String>[
    'black',
    'red',
    'black_red',
  ];
  static const List<String> _allowedTextEncodings = <String>[
    'windows1256',
    'cp864',
  ];
  static const List<String> _allowedPrintRotations = <String>[
    '0',
    '90',
    '180',
    '270',
  ];
  static const List<String> _allowedCommandTypes = <String>[
    'auto',
    'esc',
    'tspl',
    'cpcl',
  ];

  String paperWidth = '58';
  int beepBefore = 0;
  int beepAfter = 0;
  int feedLines = 0;
  String beepType = '0x07';
  bool cutPaper = false;
  bool textBorder = false;
  String fitMode = 'fit_width';
  String contentAlignment = 'center';
  String printColor = 'black';
  String textEncoding = 'windows1256';
  String printRotation = '0';
  String commandType = 'auto';
  int textFontSize = 26;
  String textFontFamily = 'NotoKufiArabicBold';
  bool isAdditionalSettingsExpanded = false;
  String? selectedPdfPath;
  String? selectedPdfName;
  bool _isPrinting = false;

  final macController = TextEditingController();
  final textController = TextEditingController(text: _defaultPrintText);
  final customPaperWidthController = TextEditingController(
    text: _defaultCustomPaperWidth,
  );
  final customPaperWidthFocusNode = FocusNode();
  final textFocusNode = FocusNode();
  SharedPreferences? _prefs;
  bool _isRestoringPreferences = false;

  bool get _isBluetoothScanSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    macController.addListener(_onTextInputsChanged);
    textController.addListener(_onTextInputsChanged);
    customPaperWidthController.addListener(_onTextInputsChanged);
    PdfIntentService.setListener(_handleIncomingPdfIntent);
    unawaited(_loadSavedSettings());
    unawaited(_loadInitialPdfIntent());
  }

  @override
  void dispose() {
    PdfIntentService.setListener(null);
    macController.removeListener(_onTextInputsChanged);
    textController.removeListener(_onTextInputsChanged);
    customPaperWidthController.removeListener(_onTextInputsChanged);
    macController.dispose();
    textController.dispose();
    customPaperWidthController.dispose();
    customPaperWidthFocusNode.dispose();
    textFocusNode.dispose();
    super.dispose();
  }

  void _onTextInputsChanged() {
    if (_isRestoringPreferences) {
      return;
    }
    unawaited(_saveSettingsToLocal());
  }

  void _updateSettings(VoidCallback updater) {
    setState(updater);
    unawaited(_saveSettingsToLocal());
  }

  Future<void> _loadInitialPdfIntent() async {
    final pdf = await PdfIntentService.consumeInitialPdf();
    if (!mounted || pdf == null) {
      return;
    }

    _selectPdfFromIntent(pdf);
  }

  void _handleIncomingPdfIntent(IncomingPdfIntent pdf) {
    if (!mounted) {
      return;
    }

    _selectPdfFromIntent(pdf);
  }

  void _selectPdfFromIntent(IncomingPdfIntent pdf) {
    textFocusNode.unfocus();
    setState(() {
      selectedPdfPath = pdf.path;
      selectedPdfName = pdf.name;
    });
  }

  String _validatedPaperWidth(String value) {
    final normalized = value.trim().toLowerCase();
    return _allowedPaperWidths.contains(normalized) ? normalized : '58';
  }

  String _validatedCustomPaperWidth(String value) {
    final normalized = value.trim().replaceAll(',', '.');
    final parsed = double.tryParse(normalized);
    if (parsed == null || parsed <= 0) {
      return _defaultCustomPaperWidth;
    }
    return normalized;
  }

  String _validatedBeepType(String value) {
    return _allowedBeepTypes.contains(value) ? value : '0x07';
  }

  String _validatedFitMode(String value) {
    final normalized = value.trim().toLowerCase();
    return _allowedFitModes.contains(normalized) ? normalized : 'fit_width';
  }

  String _validatedAlignment(String value) {
    final normalized = value.trim().toLowerCase();
    return _allowedAlignments.contains(normalized) ? normalized : 'center';
  }

  bool _isSidewaysPrintRotationValue(String value) {
    return value == '90' || value == '270';
  }

  bool get _isSidewaysPrintRotation {
    return _isSidewaysPrintRotationValue(printRotation);
  }

  String _alignmentLabel(String value) {
    if (_isSidewaysPrintRotation) {
      return value == 'center'
          ? 'توسيط'
          : value == 'right'
          ? 'أعلى'
          : 'أسفل';
    }

    return value == 'center'
        ? 'توسيط'
        : value == 'right'
        ? 'يمين'
        : 'يسار';
  }

  double? _parsedPaperWidth() {
    final value = paperWidth == _customPaperWidthValue
        ? customPaperWidthController.text
        : paperWidth;
    final normalized = value.trim().replaceAll(',', '.');
    final parsed = double.tryParse(normalized);
    if (parsed == null || parsed <= 0) {
      return null;
    }
    return parsed;
  }

  String _validatedPrintColor(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == '1' || normalized == '49' || normalized == 'n=1') {
      return 'red';
    }
    return _allowedPrintColors.contains(normalized) ? normalized : 'black';
  }

  String _validatedTextEncoding(String value) {
    final normalized = value.trim().toLowerCase().replaceAll('-', '');
    return _allowedTextEncodings.contains(normalized)
        ? normalized
        : 'windows1256';
  }

  String _validatedPrintRotation(String value) {
    final normalized = value.trim();
    return _allowedPrintRotations.contains(normalized) ? normalized : '0';
  }

  String _validatedCommandType(String value) {
    final normalized = value.trim().toLowerCase();
    return _allowedCommandTypes.contains(normalized) ? normalized : 'auto';
  }

  int _validatedTextFontSize(int value) {
    return value.clamp(12, 72).toInt();
  }

  String _validatedTextFontFamily(String value) {
    return _allowedTextFontFamilies.contains(value)
        ? value
        : 'NotoKufiArabicBold';
  }

  String _textFontFamilyLabel(String value) {
    switch (value) {
      case 'Tajawal':
        return 'تجوال';
      case 'Cairo':
        return 'كايرو (Cairo)';
      case 'Almarai':
        return 'المراعي (Almarai)';
      case 'Changa':
        return 'شانجا (Changa)';
      case 'Amiri':
        return 'أميري (Amiri)';
      case 'ReemKufi':
        return 'ريم كوفي (ReemKufi)';
      default:
        return 'كوفي عريض';
    }
  }

  String _printColorLabel(String value) {
    switch (value) {
      case 'red':
        return 'أحمر';
      case 'black_red':
        return 'أسود + أحمر';
      default:
        return 'أسود';
    }
  }

  String _textEncodingLabel(String value) {
    return value == 'cp864' ? 'CP864' : 'Windows-1256';
  }

  String _commandTypeLabel(String value) {
    switch (value) {
      case 'esc':
        return 'ESC';
      case 'tspl':
        return 'TSPL';
      case 'cpcl':
        return 'CPCL';
      default:
        return 'Auto';
    }
  }

  String _printRotationLabel(String value) {
    return '$value درجة';
  }

  Future<void> _loadSavedSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;

    final savedPaperWidth = prefs.getString(_paperWidthKey) ?? paperWidth;
    var loadedPaperWidth = _validatedPaperWidth(savedPaperWidth);
    var loadedCustomPaperWidth = _validatedCustomPaperWidth(
      prefs.getString(_customPaperWidthKey) ?? customPaperWidthController.text,
    );
    if (!_allowedPaperWidths.contains(savedPaperWidth.trim().toLowerCase())) {
      final migratedPaperWidth = _validatedCustomPaperWidth(savedPaperWidth);
      if (migratedPaperWidth != _defaultCustomPaperWidth ||
          savedPaperWidth.trim().replaceAll(',', '.') ==
              _defaultCustomPaperWidth) {
        loadedPaperWidth = _customPaperWidthValue;
        loadedCustomPaperWidth = migratedPaperWidth;
      }
    }
    final loadedMac = prefs.getString(_macAddressKey) ?? '';
    final loadedBeepBefore = (prefs.getInt(_beepBeforeKey) ?? beepBefore).clamp(
      0,
      999,
    );
    final loadedBeepAfter = (prefs.getInt(_beepAfterKey) ?? beepAfter).clamp(
      0,
      999,
    );
    final loadedFeedLines = (prefs.getInt(_feedLinesKey) ?? feedLines).clamp(
      0,
      999,
    );
    final loadedBeepType = _validatedBeepType(
      prefs.getString(_beepTypeKey) ?? beepType,
    );
    final loadedCutPaper = prefs.getBool(_cutPaperKey) ?? cutPaper;
    final loadedTextBorder = prefs.getBool(_textBorderKey) ?? textBorder;
    final loadedFitMode = _validatedFitMode(
      prefs.getString(_fitModeKey) ?? fitMode,
    );
    final loadedPrintColor = _validatedPrintColor(
      prefs.getString(_printColorKey) ?? printColor,
    );
    final loadedTextEncoding = _validatedTextEncoding(
      prefs.getString(_textEncodingKey) ?? textEncoding,
    );
    final loadedPrintRotation = _validatedPrintRotation(
      prefs.getString(_printRotationKey) ?? printRotation,
    );
    final loadedContentAlignment = _validatedAlignment(
      prefs.getString(_contentAlignmentKey) ?? contentAlignment,
    );
    final loadedCommandType = _validatedCommandType(
      prefs.getString(_commandTypeKey) ?? commandType,
    );
    final loadedTextFontSize = _validatedTextFontSize(
      prefs.getInt(_textFontSizeKey) ?? textFontSize,
    );
    final loadedTextFontFamily = _validatedTextFontFamily(
      prefs.getString(_textFontFamilyKey) ?? textFontFamily,
    );
    final loadedPrintText = prefs.containsKey(_printTextKey)
        ? (prefs.getString(_printTextKey) ?? '')
        : _defaultPrintText;

    if (!mounted) {
      return;
    }

    _isRestoringPreferences = true;
    macController.text = loadedMac;
    textController.text = loadedPrintText;
    customPaperWidthController.text = loadedCustomPaperWidth;
    setState(() {
      paperWidth = loadedPaperWidth;
      beepBefore = loadedBeepBefore;
      beepAfter = loadedBeepAfter;
      feedLines = loadedFeedLines;
      beepType = loadedBeepType;
      cutPaper = loadedCutPaper;
      textBorder = loadedTextBorder;
      fitMode = loadedFitMode;
      contentAlignment = loadedContentAlignment;
      printColor = loadedPrintColor;
      textEncoding = loadedTextEncoding;
      printRotation = loadedPrintRotation;
      commandType = loadedCommandType;
      textFontSize = loadedTextFontSize;
      textFontFamily = loadedTextFontFamily;
    });
    _isRestoringPreferences = false;
  }

  Future<void> _saveSettingsToLocal() async {
    if (_isRestoringPreferences) {
      return;
    }

    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;

    await Future.wait<void>([
      prefs.setString(_paperWidthKey, paperWidth),
      prefs.setString(
        _customPaperWidthKey,
        customPaperWidthController.text.trim(),
      ),
      prefs.setString(_macAddressKey, macController.text.trim()),
      prefs.setInt(_beepBeforeKey, beepBefore),
      prefs.setInt(_beepAfterKey, beepAfter),
      prefs.setInt(_feedLinesKey, feedLines),
      prefs.setString(_beepTypeKey, beepType),
      prefs.setBool(_cutPaperKey, cutPaper),
      prefs.setBool(_textBorderKey, textBorder),
      prefs.setString(_fitModeKey, fitMode),
      prefs.setString(_contentAlignmentKey, contentAlignment),
      prefs.setString(_printColorKey, printColor),
      prefs.setString(_textEncodingKey, textEncoding),
      prefs.setString(_printRotationKey, printRotation),
      prefs.setString(_commandTypeKey, commandType),
      prefs.setInt(_textFontSizeKey, textFontSize),
      prefs.setString(_textFontFamilyKey, textFontFamily),
      prefs.setString(_printTextKey, textController.text),
    ]);
  }

  String _compactMacToAddress(String compact) {
    final buffer = StringBuffer();
    for (var i = 0; i < compact.length; i += 2) {
      if (i > 0) {
        buffer.write(':');
      }
      buffer.write(compact.substring(i, i + 2));
    }
    return buffer.toString();
  }

  String _normalizeMacAddress(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      final macLike = RegExp(
        r'^([0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}$',
      ).hasMatch(trimmed);
      if (!macLike) {
        // Keep BLE remoteId/UUID format on iOS; do not rewrite '-' to ':'.
        return trimmed.toUpperCase();
      }
    }

    final separatedMatch = RegExp(
      r'([0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}',
    ).firstMatch(trimmed);
    if (separatedMatch != null) {
      return separatedMatch.group(0)!.replaceAll('-', ':').toUpperCase();
    }

    final compactMatch = RegExp(
      r'(?<![0-9A-Fa-f])[0-9A-Fa-f]{12}(?![0-9A-Fa-f])',
    ).firstMatch(trimmed);
    if (compactMatch != null) {
      return _compactMacToAddress(compactMatch.group(0)!.toUpperCase());
    }

    final cleaned = trimmed
        .replaceAll(RegExp(r'[^0-9A-Fa-f]'), '')
        .toUpperCase();
    if (cleaned.length == 12) {
      return _compactMacToAddress(cleaned);
    }

    return trimmed.replaceAll('-', ':').toUpperCase();
  }

  Future<void> _pickPdfFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );

    final file = result?.files.single;
    if (file == null || file.path == null || file.path!.trim().isEmpty) {
      return;
    }

    textFocusNode.unfocus();
    setState(() {
      selectedPdfPath = file.path!;
      selectedPdfName = file.name;
    });
  }

  EscPosTextEncoding get _selectedEscPosTextEncoding {
    return textEncoding == 'cp864'
        ? EscPosTextEncoding.cp864
        : EscPosTextEncoding.windows1256;
  }

  String _stripRedTags(String text) {
    return text.replaceAll(RegExp(r'\[/?red\]', caseSensitive: false), '');
  }

  Future<void> _printBlackTextAsImage({
    required String text,
    required String normalizedMac,
    required double selectedPaperWidth,
  }) async {
    await printTextAsRasterImage(
      context: context,
      text: text,
      paperWidth: selectedPaperWidth,
      mac: normalizedMac,
      beepBefore: beepBefore,
      beepAfter: beepAfter,
      beepType: beepType,
      autoCut: cutPaper,
      feedLines: feedLines,
      textBorder: textBorder,
      fitMode: fitMode,
      contentAlignment: contentAlignment,
      commandType: commandType,
      printRotationDegrees: int.parse(printRotation),
      textFontSize: textFontSize,
      textFontFamily: textFontFamily,
    );
  }

  Future<void> _printBlackPdf({
    required String normalizedMac,
    required double selectedPaperWidth,
  }) async {
    await printBluetoothPdfReceipt(
      context: context,
      pdfPath: selectedPdfPath!,
      paperWidth: selectedPaperWidth,
      mac: normalizedMac,
      beepBefore: beepBefore,
      beepAfter: beepAfter,
      beepType: beepType,
      autoCut: cutPaper,
      feedLines: feedLines,
      fitMode: fitMode,
      contentAlignment: contentAlignment,
      commandType: commandType,
      printColor: 'black',
      printRotationDegrees: int.parse(printRotation),
    );
  }

  Future<void> _handlePdfPrintByMode({
    required PrintColorMode mode,
    required String normalizedMac,
    required double selectedPaperWidth,
  }) async {
    if (mode == PrintColorMode.black) {
      await _printBlackPdf(
        normalizedMac: normalizedMac,
        selectedPaperWidth: selectedPaperWidth,
      );
      return;
    }

    final colorResult = await printPdfWithColorResult(
      context: context,
      pdfPath: selectedPdfPath!,
      paperWidth: selectedPaperWidth,
      mac: normalizedMac,
      beepBefore: beepBefore,
      beepAfter: beepAfter,
      beepType: beepType,
      autoCut: cutPaper,
      feedLines: feedLines,
      fitMode: fitMode,
      contentAlignment: contentAlignment,
      commandType: commandType,
      printColor: mode == PrintColorMode.red ? 'red' : 'black_red',
      printRotationDegrees: int.parse(printRotation),
    );
    if (!mounted) return;
    if (colorResult.success) {
      _showMessage(context, _messagePrintSuccess);
      return;
    }

    if (colorResult.hasPrintedPages) {
      _showMessage(
        context,
        'تعذر إكمال طباعة PDF الملونة. تم إيقاف التحويل التلقائي للأسود لتجنب إعادة الطباعة.',
      );
      return;
    }

    _showMessage(
      context,
      mode == PrintColorMode.red
          ? _messagePdfRedFallback
          : _messagePdfColorFallback,
    );
    await _printBlackPdf(
      normalizedMac: normalizedMac,
      selectedPaperWidth: selectedPaperWidth,
    );
  }

  Future<void> _handleTextPrintByMode({
    required PrintColorMode mode,
    required String text,
    required String normalizedMac,
    required double selectedPaperWidth,
  }) async {
    switch (mode) {
      case PrintColorMode.black:
        await _printBlackTextAsImage(
          text: text,
          normalizedMac: normalizedMac,
          selectedPaperWidth: selectedPaperWidth,
        );
        return;
      case PrintColorMode.red:
        final redPrinted = await printRedTextWithFallbackCommands(
          text: text,
          mac: normalizedMac,
          paperWidth: selectedPaperWidth,
          textEncoding: _selectedEscPosTextEncoding,
          beepBefore: beepBefore,
          beepAfter: beepAfter,
          beepType: beepType,
          feedLines: feedLines,
          autoCut: cutPaper,
          textBorder: textBorder,
          fitMode: fitMode,
          contentAlignment: contentAlignment,
          printerProfile: 'auto',
          printRotationDegrees: int.parse(printRotation),
          textFontSize: textFontSize,
          textFontFamily: textFontFamily,
        );
        if (!mounted) return;
        if (redPrinted) {
          _showMessage(context, _messagePrintSuccess);
          return;
        }
        _showMessage(context, _messageBlackRedFallback);
        await _printBlackTextAsImage(
          text: text,
          normalizedMac: normalizedMac,
          selectedPaperWidth: selectedPaperWidth,
        );
        return;
      case PrintColorMode.blackAndRed:
        final cleanFallbackText = _stripRedTags(text);
        final mixedPrinted = await printMixedTextWithFallbackCommands(
          parts: parseColoredTextParts(text),
          mac: normalizedMac,
          paperWidth: selectedPaperWidth,
          textEncoding: _selectedEscPosTextEncoding,
          beepBefore: beepBefore,
          beepAfter: beepAfter,
          beepType: beepType,
          feedLines: feedLines,
          autoCut: cutPaper,
          textBorder: textBorder,
          fitMode: fitMode,
          contentAlignment: contentAlignment,
          printerProfile: 'auto',
          printRotationDegrees: int.parse(printRotation),
          textFontSize: textFontSize,
          textFontFamily: textFontFamily,
        );
        if (!mounted) return;
        if (mixedPrinted) {
          _showMessage(context, _messagePrintSuccess);
          return;
        }
        _showMessage(context, _messageRedFallback);
        await _printBlackTextAsImage(
          text: cleanFallbackText,
          normalizedMac: normalizedMac,
          selectedPaperWidth: selectedPaperWidth,
        );
        return;
    }
  }

  Future<void> _handlePrintPressed() async {
    if (_isPrinting) {
      _showMessage(context, 'الطباعة قيد التنفيذ');
      return;
    }
    setState(() => _isPrinting = true);
    try {
      final normalizedMac = _normalizeMacAddress(macController.text);
      if (normalizedMac.isEmpty) {
        _showMessage(context, 'تعذر الاتصال بالطابعة');
        return;
      }
      if (macController.text.trim() != normalizedMac) {
        _updateSettings(() => macController.text = normalizedMac);
      }

      final selectedPaperWidth = _parsedPaperWidth();
      if (selectedPaperWidth == null) {
        _showMessage(context, 'تعذر الاتصال بالطابعة');
        return;
      }

      final mode = printColorModeFromValue(printColor);

      if (selectedPdfPath != null) {
        await _handlePdfPrintByMode(
          mode: mode,
          normalizedMac: normalizedMac,
          selectedPaperWidth: selectedPaperWidth,
        );
        return;
      }

      final text = textController.text.trim();
      if (text.isEmpty) {
        _showMessage(context, _messageTextRequired);
        return;
      }

      await _handleTextPrintByMode(
        mode: mode,
        text: text,
        normalizedMac: normalizedMac,
        selectedPaperWidth: selectedPaperWidth,
      );
    } finally {
      if (mounted) {
        setState(() => _isPrinting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final width = mediaQuery.size.width;
    final supportsScan = _isBluetoothScanSupported;
    final bottomSafeSpacing = mediaQuery.viewPadding.bottom + 56;

    return Scaffold(
      appBar: AppBar(
        title: Image.asset('assets/images/logo2.png', height: 45),
        centerTitle: true,
        backgroundColor: const Color(0xffB0DCFE),
      ),
      body: SafeArea(
        bottom: true,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomSafeSpacing),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      width: width * 0.95,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        gradient: LinearGradient(
                          begin: Alignment.topRight,
                          end: Alignment.bottomLeft,
                          colors: [
                            const Color(0xffEAF5FF).withValues(alpha: 0.72),
                            const Color(0xffD7EAFF).withValues(alpha: 0.52),
                          ],
                        ),
                        border: Border.all(
                          color: const Color(0xff9EC7EE).withValues(alpha: 0.7),
                        ),
                      ),
                      child: Column(
                        children: [
                          const SizedBox(height: 2),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              OutlinedButton.icon(
                                style: const ButtonStyle(
                                  padding: WidgetStatePropertyAll(
                                    EdgeInsets.symmetric(horizontal: 8),
                                  ),
                                ),
                                icon: const Icon(
                                  Icons.bluetooth_searching_rounded,
                                ),
                                label: Text(supportsScan ? 'بحث' : 'غير مدعوم'),
                                onPressed: supportsScan
                                    ? () async {
                                        final selectedMac =
                                            await Navigator.push<String>(
                                              context,
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    const BluetoothDevicesScanPage(),
                                              ),
                                            );

                                        if (selectedMac != null) {
                                          _updateSettings(
                                            () => macController.text =
                                                _normalizeMacAddress(
                                                  selectedMac,
                                                ),
                                          );
                                        }
                                      }
                                    : null,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextFormField(
                                  controller: macController,
                                  textDirection: TextDirection.ltr,
                                  decoration: const InputDecoration(
                                    labelText: 'MAC Address',
                                    hintText: '11:22:33:44:55:66',
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.all(
                                        Radius.circular(10),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              IconButton(
                                tooltip: supportsScan
                                    ? 'مسح باركود'
                                    : 'غير مدعوم على Windows',
                                icon: const Icon(Icons.qr_code_scanner_rounded),
                                onPressed: supportsScan
                                    ? () async {
                                        final scannedCode =
                                            await scanBarcodeInDialog(context);
                                        if (scannedCode == null) {
                                          return;
                                        }
                                        _updateSettings(
                                          () => macController.text =
                                              _normalizeMacAddress(scannedCode),
                                        );
                                      }
                                    : null,
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          if (!supportsScan) const SizedBox(height: 6),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.black26),
                              color: const Color(
                                0xffE6F3FF,
                              ).withValues(alpha: 0.58),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'ملف PDF',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        selectedPdfName ?? 'لم يتم اختيار ملف',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: selectedPdfName == null
                                              ? Colors.black54
                                              : Colors.black87,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                FilledButton.tonalIcon(
                                  onPressed: _pickPdfFile,
                                  icon: const Icon(
                                    Icons.picture_as_pdf_outlined,
                                  ),
                                  label: Text(
                                    selectedPdfPath == null
                                        ? 'اختيار'
                                        : 'تغيير',
                                  ),
                                ),
                                if (selectedPdfPath != null) ...[
                                  const SizedBox(width: 6),
                                  IconButton(
                                    tooltip: 'إزالة الملف',
                                    onPressed: () {
                                      setState(() {
                                        selectedPdfPath = null;
                                        selectedPdfName = null;
                                      });
                                    },
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (selectedPdfPath == null) ...[
                            const SizedBox(height: 10),
                            TextFormField(
                              controller: textController,
                              focusNode: textFocusNode,
                              style: TextStyle(
                                fontFamily: textFontFamily,
                                fontSize: textFontSize.toDouble(),
                              ),
                              decoration: const InputDecoration(
                                labelText: 'نص الطباعة',
                                hintText: 'اكتب النص هنا...',
                                alignLabelWithHint: true,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 16,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.all(
                                    Radius.circular(10),
                                  ),
                                ),
                              ),
                              keyboardType: TextInputType.multiline,
                              textInputAction: TextInputAction.newline,
                              minLines: 8,
                              maxLines: null,
                              onTapOutside: (_) => textFocusNode.unfocus(),
                            ),
                          ],
                          const SizedBox(height: 12),
                          _settingsSection(),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            height: 56,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                              ),
                              icon: const Icon(Icons.print, size: 22),
                              label: const Text('طباعة'),
                              onPressed: _isPrinting ? null : _handlePrintPressed,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _settingsSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black12),
        color: const Color(0xffE8F4FF).withValues(alpha: 0.55),
      ),
      child: Column(
        children: [
          _settingFieldRow(
            label: _isSidewaysPrintRotation ? 'ارتفاع الورقة' : 'عرض الورق',
            field: _paperSizeField(),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.black12),
              color: Colors.white.withValues(alpha: 0.38),
            ),
            child: Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                title: const Text(
                  'إعدادات إضافية',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                initiallyExpanded: isAdditionalSettingsExpanded,
                onExpansionChanged: (value) {
                  setState(() => isAdditionalSettingsExpanded = value);
                },
                children: [
                  if (selectedPdfPath == null) ...[
                    _settingFieldRow(
                      label: 'نوع الخط',
                      field: _textFontFamilyField(),
                    ),
                    _settingFieldRow(
                      label: 'حجم الخط',
                      field: _textFontSizeField(),
                    ),
                  ],
                  _settingFieldRow(
                    label: 'نوع الكوماند',
                    field: DropdownButtonFormField<String>(
                      initialValue: commandType,
                      isDense: true,
                      isExpanded: true,
                      decoration: _dropdownFieldDecoration(),
                      items: _allowedCommandTypes
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(_commandTypeLabel(value)),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          _updateSettings(() => commandType = value!),
                    ),
                  ),
                  _settingFieldRow(
                    label: 'لون الطباعة',
                    field: DropdownButtonFormField<String>(
                      initialValue: printColor,
                      isDense: true,
                      isExpanded: true,
                      decoration: _dropdownFieldDecoration(),
                      items: _allowedPrintColors
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(_printColorLabel(value)),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          _updateSettings(() => printColor = value!),
                    ),
                  ),
                  _settingFieldRow(
                    label: 'ترميز العربي',
                    field: DropdownButtonFormField<String>(
                      initialValue: textEncoding,
                      isDense: true,
                      isExpanded: true,
                      decoration: _dropdownFieldDecoration(),
                      items: _allowedTextEncodings
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(_textEncodingLabel(value)),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          _updateSettings(() => textEncoding = value!),
                    ),
                  ),
                  _settingFieldRow(
                    label: 'ملاءمة المقاس',
                    field: DropdownButtonFormField<String>(
                      initialValue: fitMode,
                      isDense: true,
                      isExpanded: true,
                      decoration: _dropdownFieldDecoration(),
                      items: _allowedFitModes
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(
                                value == 'fit_width'
                                    ? 'ملاءمة العرض'
                                    : 'الحجم الأصلي',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          _updateSettings(() => fitMode = value!),
                    ),
                  ),
                  _settingFieldRow(
                    label: 'محاذاة الطباعة',
                    field: DropdownButtonFormField<String>(
                      key: ValueKey<String>(
                        'alignment-$printRotation-$contentAlignment',
                      ),
                      initialValue: contentAlignment,
                      isDense: true,
                      isExpanded: true,
                      decoration: _dropdownFieldDecoration(),
                      items: _allowedAlignments
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(_alignmentLabel(value)),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          _updateSettings(() => contentAlignment = value!),
                    ),
                  ),
                  _settingFieldRow(
                    label: 'درجة الدوران',
                    field: DropdownButtonFormField<String>(
                      initialValue: printRotation,
                      isDense: true,
                      isExpanded: true,
                      decoration: _dropdownFieldDecoration(),
                      items: _allowedPrintRotations
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(_printRotationLabel(value)),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          _updateSettings(() => printRotation = value!),
                    ),
                  ),
                  _settingFieldRow(
                    label: 'نوع الصفارة',
                    field: DropdownButtonFormField<String>(
                      initialValue: beepType,
                      isDense: true,
                      isExpanded: true,
                      decoration: _dropdownFieldDecoration(),
                      items: _allowedBeepTypes
                          .map(
                            (e) => DropdownMenuItem(value: e, child: Text(e)),
                          )
                          .toList(),
                      onChanged: (value) =>
                          _updateSettings(() => beepType = value!),
                    ),
                  ),
                  _checkboxSettingRow(
                    label: 'قص الورق تلقائيًا',
                    value: cutPaper,
                    onChanged: (value) =>
                        _updateSettings(() => cutPaper = value),
                  ),
                  _checkboxSettingRow(
                    label: 'رسم إطار حول نص الطباعة',
                    value: textBorder,
                    onChanged: (value) =>
                        _updateSettings(() => textBorder = value),
                  ),
                  _counterRow(
                    'عدد الصفارات قبل الطباعة',
                    beepBefore,
                    (v) => _updateSettings(() => beepBefore = v),
                  ),
                  _counterRow(
                    'عدد الصفارات بعد الطباعة',
                    beepAfter,
                    (v) => _updateSettings(() => beepAfter = v),
                  ),
                  _counterRow(
                    'عدد أسطر التغذية',
                    feedLines,
                    (v) => _updateSettings(() => feedLines = v),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _paperSizeField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey<String>('paper-dropdown-$printRotation-$paperWidth'),
          initialValue: paperWidth,
          isDense: true,
          isExpanded: true,
          decoration: _dropdownFieldDecoration(),
          items: _allowedPaperWidths
              .map(
                (value) => DropdownMenuItem(
                  value: value,
                  child: Text(_paperWidthLabel(value)),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value == null) {
              return;
            }
            _updateSettings(() {
              if (value == _customPaperWidthValue &&
                  customPaperWidthController.text.trim().isEmpty) {
                customPaperWidthController.text = _defaultCustomPaperWidth;
              }
              paperWidth = value;
            });
            if (value == _customPaperWidthValue) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) {
                  return;
                }
                customPaperWidthFocusNode.requestFocus();
              });
            } else {
              customPaperWidthFocusNode.unfocus();
            }
          },
        ),
        if (paperWidth == _customPaperWidthValue) ...[
          const SizedBox(height: 8),
          TextFormField(
            controller: customPaperWidthController,
            focusNode: customPaperWidthFocusNode,
            textDirection: TextDirection.ltr,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
            decoration: _dropdownFieldDecoration().copyWith(
              labelText: 'عرض مخصص mm',
              hintText: 'مثال 100',
            ),
          ),
        ],
      ],
    );
  }

  String _paperWidthLabel(String value) {
    return value == _customPaperWidthValue ? 'مخصص' : '$value mm';
  }

  Widget _textFontFamilyField() {
    return DropdownButtonFormField<String>(
      initialValue: textFontFamily,
      isDense: true,
      isExpanded: true,
      decoration: _dropdownFieldDecoration(),
      items: _allowedTextFontFamilies
          .map(
            (value) => DropdownMenuItem(
              value: value,
              child: Text(_textFontFamilyLabel(value)),
            ),
          )
          .toList(),
      onChanged: (value) => _updateSettings(() => textFontFamily = value!),
    );
  }

  Widget _textFontSizeField() {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        height: 42,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.black26),
          color: Colors.white.withValues(alpha: 0.72),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          textDirection: TextDirection.ltr,
          children: [
            _stepperButton(
              icon: Icons.remove_rounded,
              onPressed: () => _updateSettings(
                () => textFontSize = _validatedTextFontSize(textFontSize - 1),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                '$textFontSize',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _stepperButton(
              icon: Icons.add_rounded,
              onPressed: () => _updateSettings(
                () => textFontSize = _validatedTextFontSize(textFontSize + 1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _settingFieldRow({required String label, required Widget field}) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black12),
        color: Colors.white.withValues(alpha: 0.38),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(flex: 3, child: field),
        ],
      ),
    );
  }

  InputDecoration _dropdownFieldDecoration() {
    return InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.72),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.black26),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.black26),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xff5A8FC2), width: 1.2),
      ),
    );
  }

  Widget _checkboxSettingRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black12),
        color: Colors.white.withValues(alpha: 0.38),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(width: 8),
          Checkbox(
            value: value,
            side: const BorderSide(color: Colors.black45, width: 1.2),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (v) => onChanged(v ?? false),
          ),
        ],
      ),
    );
  }

  Widget _counterRow(
    String label,
    int value,
    void Function(int) onChanged, {
    int minValue = 0,
    int maxValue = 999,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black12),
        color: Colors.white.withValues(alpha: 0.38),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.black26),
              color: Colors.white.withValues(alpha: 0.6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              textDirection: TextDirection.ltr,
              children: [
                _stepperButton(
                  icon: Icons.remove_rounded,
                  onPressed: () =>
                      onChanged((value - 1).clamp(minValue, maxValue).toInt()),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    '$value',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _stepperButton(
                  icon: Icons.add_rounded,
                  onPressed: () =>
                      onChanged((value + 1).clamp(minValue, maxValue).toInt()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepperButton({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      splashRadius: 18,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
    );
  }

  void _showMessage(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}
