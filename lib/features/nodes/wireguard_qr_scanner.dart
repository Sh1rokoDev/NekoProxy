import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/header_fade.dart';

class WireGuardQrScanner extends StatefulWidget {
  const WireGuardQrScanner({super.key});

  @override
  State<WireGuardQrScanner> createState() => _WireGuardQrScannerState();
}

class _WireGuardQrScannerState extends State<WireGuardQrScanner> {
  bool _finished = false;

  @override
  Widget build(BuildContext context) => HeaderScaffold(
    title: const Text('扫描 WireGuard 二维码'),
    scrollsBehindHeader: false,
    body: (_) => MobileScanner(
      onDetect: (capture) {
        if (_finished || ModalRoute.of(context)?.isCurrent != true) return;
        for (final barcode in capture.barcodes) {
          if (barcode.format != BarcodeFormat.qrCode) continue;
          if (barcode.rawValue case final value? when value.trim().isNotEmpty) {
            _finished = true;
            Navigator.pop(context, value);
            return;
          }
        }
      },
      errorBuilder: (context, error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            error.errorCode == MobileScannerErrorCode.permissionDenied
                ? '未获得相机权限。可返回并从二维码图片导入。'
                : '无法启动相机。可返回并从二维码图片导入。',
          ),
        ),
      ),
    ),
  );
}
