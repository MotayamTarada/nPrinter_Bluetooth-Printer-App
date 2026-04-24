import 'dart:async';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/bluetooth_devices_scan_page.dart';
import '../services/bluetooth_printer_service.dart';
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
  static const String _commandTypeKey = 'printer.commandType';
  static const String _printTextKey = 'printer.printText';
  static const List<String> _allowedPaperWidths = <String>['58', '80', '112'];
  static const List<String> _allowedBeepTypes = <String>[
    '0x07',
    '0x1B, 0x42',
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
  String commandType = 'auto';
  bool isAdditionalSettingsExpanded = false;
  String? selectedPdfPath;
  String? selectedPdfName;

  final macController = TextEditingController();
  final textController = TextEditingController(text: 'nPrinter');
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
    unawaited(_loadSavedSettings());
  }

  @override
  void dispose() {
    macController.removeListener(_onTextInputsChanged);
    textController.removeListener(_onTextInputsChanged);
    macController.dispose();
    textController.dispose();
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

  String _validatedPaperWidth(String value) {
    final normalized = value.trim().toLowerCase();
    return _allowedPaperWidths.contains(normalized) ? normalized : '58';
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

  String _validatedPrintColor(String value) {
    return _allowedPrintColors.contains(value) ? value : 'black';
  }

  String _validatedCommandType(String value) {
    final normalized = value.trim().toLowerCase();
    return _allowedCommandTypes.contains(normalized) ? normalized : 'auto';
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

  Future<void> _loadSavedSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;

    final loadedPaperWidth = _validatedPaperWidth(
      prefs.getString(_paperWidthKey) ?? paperWidth,
    );
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
    final loadedContentAlignment = _validatedAlignment(
      prefs.getString(_contentAlignmentKey) ?? contentAlignment,
    );
    final loadedPrintColor = _validatedPrintColor(
      prefs.getString(_printColorKey) ?? printColor,
    );
    final loadedCommandType = _validatedCommandType(
      prefs.getString(_commandTypeKey) ?? commandType,
    );
    final loadedPrintText = prefs.getString(_printTextKey) ?? textController.text;

    if (!mounted) {
      return;
    }

    _isRestoringPreferences = true;
    macController.text = loadedMac;
    textController.text = loadedPrintText;
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
      commandType = loadedCommandType;
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
      prefs.setString(_commandTypeKey, commandType),
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

    final cleaned = trimmed.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '').toUpperCase();
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
                          icon: const Icon(Icons.bluetooth_searching_rounded),
                          label: Text(
                            supportsScan ? 'بحث' : 'غير مدعوم',
                          ),
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
                                          _normalizeMacAddress(selectedMac),
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
                          tooltip:
                              supportsScan ? 'مسح باركود' : 'غير مدعوم على Windows',
                          icon: const Icon(Icons.qr_code_scanner_rounded),
                          onPressed: supportsScan
                              ? () async {
                                  final scannedCode = await scanBarcodeInDialog(
                                    context,
                                  );
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
                        color: const Color(0xffE6F3FF).withValues(alpha: 0.58),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                            icon: const Icon(Icons.picture_as_pdf_outlined),
                            label: Text(
                              selectedPdfPath == null ? 'اختيار' : 'تغيير',
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
                        decoration: const InputDecoration(
                          labelText: 'نص الطباعة',
                          hintText: 'اكتب النص هنا...',
                          alignLabelWithHint: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 16,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(10)),
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
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        icon: const Icon(Icons.print, size: 22),
                        label: const Text('طباعة'),
                        onPressed: () async {
                          final normalizedMac = _normalizeMacAddress(
                            macController.text,
                          );
                        if (normalizedMac.isEmpty) {
                          _showMessage(context, 'يرجى إدخال عنوان MAC للطابعة');
                          return;
                        }
                        if (macController.text.trim() != normalizedMac) {
                          _updateSettings(
                            () => macController.text = normalizedMac,
                          );
                        }

                        if (selectedPdfPath != null) {
                          await printBluetoothPdfReceipt(
                            context: context,
                            pdfPath: selectedPdfPath!,
                            paperWidth: double.parse(paperWidth),
                            mac: normalizedMac,
                            beepBefore: beepBefore,
                            beepAfter: beepAfter,
                            beepType: beepType,
                            autoCut: cutPaper,
                            feedLines: feedLines,
                            fitMode: fitMode,
                            contentAlignment: contentAlignment,
                            commandType: commandType,
                            printColor: printColor,
                          );
                          return;
                        }

                        if (textController.text.trim().isEmpty) {
                          _showMessage(
                            context,
                            'يرجى إدخال نص الطباعة أو اختيار ملف PDF',
                          );
                          return;
                        }

                          await printBluetoothReceipt(
                            context: context,
                            text: textController.text,
                            paperWidth: double.parse(paperWidth),
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
                            printColor: printColor,
                          );
                        },
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
            label: 'عرض الورق',
            field: DropdownButtonFormField<String>(
              initialValue: paperWidth,
              isDense: true,
              isExpanded: true,
              decoration: _dropdownFieldDecoration(),
              items: _allowedPaperWidths
                  .map((e) => DropdownMenuItem(value: e, child: Text('$e mm')))
                  .toList(),
              onChanged: (value) => _updateSettings(() => paperWidth = value!),
            ),
          ),
          const SizedBox(height: 8),
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
              onChanged: (value) => _updateSettings(() => commandType = value!),
            ),
          ),
          const SizedBox(height: 8),
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
              onChanged: (value) => _updateSettings(() => printColor = value!),
            ),
          ),
          const SizedBox(height: 8),
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
                        value == 'fit_width' ? 'ملاءمة العرض' : 'الحجم الأصلي',
                       ),
                    ),
                  )
                  .toList(),
              onChanged: (value) => _updateSettings(() => fitMode = value!),
            ),
          ),
          const SizedBox(height: 8),
          _settingFieldRow(
            label: 'محاذاة الطباعة',
            field: DropdownButtonFormField<String>(
              initialValue: contentAlignment,
              isDense: true,
              isExpanded: true,
              decoration: _dropdownFieldDecoration(),
              items: _allowedAlignments
                  .map(
                    (value) => DropdownMenuItem(
                      value: value,
                      child: Text(
                        value == 'center'
                            ? 'توسيط'
                            : value == 'right'
                                ? 'يمين'
                                : 'يسار',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) =>
                  _updateSettings(() => contentAlignment = value!),
            ),
          ),
          const SizedBox(height: 8),
          _settingFieldRow(
            label: 'نوع الصفارة',
            field: DropdownButtonFormField<String>(
              initialValue: beepType,
              isDense: true,
              isExpanded: true,
              decoration: _dropdownFieldDecoration(),
              items: _allowedBeepTypes
                  .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                  .toList(),
              onChanged: (value) => _updateSettings(() => beepType = value!),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.black12),
              color: Colors.white.withValues(alpha: 0.38),
            ),
            child: Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
              ),
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

  Widget _counterRow(String label, int value, void Function(int) onChanged) {
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
                  onPressed: () => onChanged((value - 1).clamp(0, 999)),
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
                  onPressed: () => onChanged((value + 1).clamp(0, 999)),
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


