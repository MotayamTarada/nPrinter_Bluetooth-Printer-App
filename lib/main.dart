import 'dart:async';

import 'package:flutter/material.dart';

import 'screens/bluetooth_printer_home_page.dart';
import 'screens/ios_bluetooth_permission_page.dart';
import 'screens/nprinter_loading_page.dart';
import 'services/ios_bluetooth_permission_gate_service.dart';
import 'services/pdf_intent_service.dart';

void main() {
  runApp(const NPrinterBluetoothOnlyApp());
}

class NPrinterBluetoothOnlyApp extends StatelessWidget {
  const NPrinterBluetoothOnlyApp({super.key});
  static const double _globalBottomDeadZoneHeight = 56;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'nPrinter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffAAB2CB)),
        useMaterial3: true,
        fontFamily: 'Tajawal',
      ),
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        final data = mediaQuery;
        final deadZone = _globalBottomDeadZoneHeight;
        final updatedData = data.copyWith(
          padding: data.padding.copyWith(
            bottom: data.padding.bottom + deadZone,
          ),
          viewPadding: data.viewPadding.copyWith(
            bottom: data.viewPadding.bottom + deadZone,
          ),
          systemGestureInsets: data.systemGestureInsets.copyWith(
            bottom: data.systemGestureInsets.bottom + deadZone,
          ),
        );

        return MediaQuery(
          data: updatedData,
          child: Stack(
            children: [
              ?child,
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: deadZone,
                child: const AbsorbPointer(
                  absorbing: true,
                  child: ColoredBox(color: Colors.transparent),
                ),
              ),
            ],
          ),
        );
      },
      home: const _AppEntryPoint(),
    );
  }
}

class _AppEntryPoint extends StatefulWidget {
  const _AppEntryPoint();

  @override
  State<_AppEntryPoint> createState() => _AppEntryPointState();
}

class _AppEntryPointState extends State<_AppEntryPoint> {
  Timer? _timer;
  bool _showLoading = true;
  bool _iosGateCompleted = false;

  @override
  void initState() {
    super.initState();
    _requestPermissionsAndShowApp();
  }

  Future<void> _requestPermissionsAndShowApp() async {
    final openedFromExternalPdf =
        await PdfIntentService.hasPendingPdf() ||
        await PdfIntentService.wasOpenedWithPdfIntent();
    if (openedFromExternalPdf) {
      if (!mounted) {
        return;
      }
      setState(() => _showLoading = false);
      return;
    }

    _timer = Timer(const Duration(seconds: 3), () {
      if (!mounted) {
        return;
      }
      setState(() => _showLoading = false);
    });
  }

  void _completeIosGate() {
    if (!mounted) {
      return;
    }
    setState(() => _iosGateCompleted = true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_showLoading) {
      return const NPrinterLoadingPage();
    }
    if (IosBluetoothPermissionGateService.isIosGateRequired &&
        !_iosGateCompleted) {
      return IosBluetoothPermissionPage(onContinue: _completeIosGate);
    }
    return const BluetoothPrinterHomePage();
  }
}
