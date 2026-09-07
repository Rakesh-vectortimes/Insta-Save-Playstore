import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Local JPEG upscale when Instagram / API only returns a tiny thumbnail.
class ImageUpscale {
  ImageUpscale._();

  /// Upscale until the short edge is at least [minEdge] (cubic).
  static Future<List<int>> upscaleJpegIfSmall(
    List<int> bytes, {
    int minEdge = 720,
    int maxEdge = 1440,
  }) {
    return compute(_upscaleIsolate, <dynamic>[bytes, minEdge, maxEdge]);
  }

  static List<int> _upscaleIsolate(List<dynamic> args) {
    final bytes = args[0] as List<int>;
    final minEdge = args[1] as int;
    final maxEdge = args[2] as int;

    final decoded = img.decodeImage(Uint8List.fromList(bytes));
    if (decoded == null) return bytes;

    final edge = decoded.width < decoded.height ? decoded.width : decoded.height;
    if (edge >= minEdge) return bytes;

    var target = edge * 4;
    if (target < minEdge) target = minEdge;
    if (target > maxEdge) target = maxEdge;

    final scale = target / edge;
    final out = img.copyResize(
      decoded,
      width: (decoded.width * scale).round(),
      height: (decoded.height * scale).round(),
      interpolation: img.Interpolation.cubic,
    );
    return img.encodeJpg(out, quality: 92);
  }
}
