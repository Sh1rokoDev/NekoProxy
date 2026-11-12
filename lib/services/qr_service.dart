import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// Decodes a QR code from an image file entirely on-device.
///
/// Camera capture is intentionally not required: users can share a
/// screenshot from their subscription provider, which is then decoded offline.
Future<String?> decodeQrFromImageBytes(Uint8List bytes) {
  return Isolate.run(() => _decode(bytes));
}

String? _decode(Uint8List bytes) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    decoded = null;
  }
  if (decoded == null) {
    throw const FormatException('不是有效的图片文件');
  }
  var source = img.bakeOrientation(decoded);
  const maxSide = 2400;
  if (source.width > maxSide || source.height > maxSide) {
    final scale = maxSide / (source.width > source.height ? source.width : source.height);
    source = img.copyResize(
      source,
      width: (source.width * scale).round(),
      height: (source.height * scale).round(),
      interpolation: img.Interpolation.average,
    );
  }
  final pixels = Int32List(source.width * source.height);
  var index = 0;
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final pixel = source.getPixel(x, y);
      pixels[index++] =
          (pixel.r.toInt() << 16) | (pixel.g.toInt() << 8) | pixel.b.toInt();
    }
  }
  final bitmap = BinaryBitmap(
    HybridBinarizer(RGBLuminanceSource(source.width, source.height, pixels)),
  );
  try {
    return QRCodeReader().decode(bitmap).text;
  } on ReaderException {
    return null;
  }
}
