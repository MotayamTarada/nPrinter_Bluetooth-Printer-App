import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

Future<String?> scanBarcodeInDialog(
  BuildContext context, {
  TextEditingController? controller,
  List<BarcodeFormat>? formats,
}) async {
  final isSupported = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  if (!isSupported) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('قارئ الباركود يعمل على Android و iOS فقط'),
      ),
    );
    return null;
  }

  final result = await showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _BarcodeScannerDialog(formats: formats),
  );

  if (result != null && result.trim().isNotEmpty && controller != null) {
    controller.text = result.trim();
  }
  return result;
}

class _BarcodeScannerDialog extends StatefulWidget {
  const _BarcodeScannerDialog({this.formats});

  final List<BarcodeFormat>? formats;

  @override
  State<_BarcodeScannerDialog> createState() => _BarcodeScannerDialogState();
}

class _BarcodeScannerDialogState extends State<_BarcodeScannerDialog> {
  late final MobileScannerController _controller;
  bool _handled = false;
  bool _torchOn = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      facing: CameraFacing.back,
      torchEnabled: false,
      formats: widget.formats ?? BarcodeFormat.values,
      returnImage: false,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final code = capture.barcodes.firstOrNull?.rawValue?.trim();
    if (code == null || code.isEmpty) return;
    _handled = true;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    const radius = 16.0;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: AspectRatio(
          aspectRatio: 3 / 4,
          child: Stack(
            children: [
              MobileScanner(controller: _controller, onDetect: _onDetect),
              Positioned(
                top: 8,
                right: 8,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Torch',
                      onPressed: () async {
                        await _controller.toggleTorch();
                        setState(() => _torchOn = !_torchOn);
                      },
                      icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
                      color: Colors.white,
                    ),
                    IconButton(
                      tooltip: 'Switch camera',
                      onPressed: _controller.switchCamera,
                      icon: const Icon(Icons.cameraswitch),
                      color: Colors.white,
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                      color: Colors.white,
                    ),
                  ],
                ),
              ),
              IgnorePointer(
                child: Center(
                  child: Container(
                    width: 260,
                    height: 160,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white70, width: 2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
