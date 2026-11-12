import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart' show Encoder, ErrorCorrectionLevel;

import 'package:nekoproxy/services/qr_service.dart';

void main() {
  test('decodes a QR image into subscription text', () async {
    const text = 'https://example.com/api/v1/client/subscribe?token=abc123';
    final qr = Encoder.encode(text, ErrorCorrectionLevel.m);
    final matrix = qr.matrix!;
    const scale = 6;
    const quiet = 4;
    final side = (matrix.width + quiet * 2) * scale;
    final image = img.Image(width: side, height: side);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var y = 0; y < matrix.height; y++) {
      for (var x = 0; x < matrix.width; x++) {
        if (matrix.get(x, y) == 0) continue;
        final left = (x + quiet) * scale;
        final top = (y + quiet) * scale;
        for (var py = top; py < top + scale; py++) {
          for (var px = left; px < left + scale; px++) {
            image.setPixelRgb(px, py, 0, 0, 0);
          }
        }
      }
    }
    final png = Uint8List.fromList(img.encodePng(image));
    expect(await decodeQrFromImageBytes(png), text);
  });

  test('rejects a non-image payload', () async {
    await expectLater(
      decodeQrFromImageBytes(Uint8List.fromList([1, 2, 3, 4])),
      throwsA(isA<FormatException>()),
    );
  });
}
