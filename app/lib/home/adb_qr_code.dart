import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// 用纯 Dart 的 `qr` 库生成矩阵，再画成二维码。
class AdbQrCodeView extends StatelessWidget {
  const AdbQrCodeView({super.key, required this.data, this.size = 220});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final code = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    final image = QrImage(code);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _QrCodePainter(image),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _QrCodePainter extends CustomPainter {
  _QrCodePainter(this.image);

  final QrImage image;

  static const int _quietZone = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final modules = image.moduleCount + _quietZone * 2;
    final cell = size.shortestSide / modules;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final dark = Paint()..color = const Color(0xFF000000);
    for (var row = 0; row < image.moduleCount; row++) {
      for (var col = 0; col < image.moduleCount; col++) {
        if (!image.isDark(row, col)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            (col + _quietZone) * cell,
            (row + _quietZone) * cell,
            cell,
            cell,
          ),
          dark,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrCodePainter oldDelegate) =>
      oldDelegate.image != image;
}
