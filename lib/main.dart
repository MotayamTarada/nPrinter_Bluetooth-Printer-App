import 'dart:async';

import 'package:flutter/material.dart';

import 'screens/bluetooth_printer_home_page.dart';
import 'screens/nprinter_loading_page.dart';

void main() {
  runApp(const NPrinterBluetoothOnlyApp());
}

class NPrinterBluetoothOnlyApp extends StatelessWidget {
  const NPrinterBluetoothOnlyApp({super.key});

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

  @override
  void initState() {
    super.initState();
    _requestPermissionsAndShowApp();
  }

  Future<void> _requestPermissionsAndShowApp() async {
    _timer = Timer(const Duration(seconds: 3), () {
      if (!mounted) {
        return;
      }
      setState(() => _showLoading = false);
    });
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
    return const BluetoothPrinterHomePage();
  }
}
