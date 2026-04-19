import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class SetupQrPage extends StatefulWidget {
  const SetupQrPage({super.key});

  @override
  State<SetupQrPage> createState() => _SetupQrPageState();
}

class _SetupQrPageState extends State<SetupQrPage> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫码填充')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_handled || capture.barcodes.isEmpty) return;
          final raw = capture.barcodes.first.rawValue;
          if (raw == null || raw.isEmpty) return;
          _handled = true;
          Navigator.of(context).pop(raw);
        },
      ),
    );
  }
}
