import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shrinks a photo on the phone before upload (Prompt 12, owner decision
/// "storage optimization"): the LONG edge at most [ImageSizing.longEdge]
/// (about 1600 px: documents stay readable), re-encoded, EXIF (and so any
/// location) removed.
///
/// - Verification photos (ID, selfie, school ID, licences, driver photo)
///   and live selfie checks stay JPEG at quality about 80: the ID-check
///   provider and the face match take JPEG, and storage.rules accept only
///   image/jpeg for them.
/// - Chat photos are WebP on iPhone and Android (smaller at the same
///   quality); the web keeps JPEG.
///
/// On the phone a failure is a capture error (the parent retakes); only
/// the web sends the original.
abstract interface class ImageCompressor {
  Future<Uint8List> compress(Uint8List bytes, {required bool document, bool webp = false});
}

abstract final class ImageSizing {
  static const int longEdge = 1600;
  static const int quality = 80;

  /// Width and height of a JPEG (first SOF segment) or PNG, or null.
  static (int, int)? size(Uint8List b) {
    // PNG: IHDR right after the signature.
    if (b.length >= 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return (_u32(b, 16), _u32(b, 20));
    }
    if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) {
      return null;
    }
    int i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) {
        return null;
      }
      final int marker = b[i + 1];
      if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01) {
        i += 2;
        continue;
      }
      final int length = (b[i + 2] << 8) | b[i + 3];
      // SOF0..SOF15 except DHT (C4), JPG (C8) and DAC (CC).
      final bool sof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
      if (sof) {
        final int height = (b[i + 5] << 8) | b[i + 6];
        final int width = (b[i + 7] << 8) | b[i + 8];
        return width > 0 && height > 0 ? (width, height) : null;
      }
      if (marker == 0xDA || length < 2) {
        return null;
      }
      i += 2 + length;
    }
    return null;
  }

  static int _u32(Uint8List b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  /// The short-side target for flutter_image_compress (its minWidth and
  /// minHeight), so the long edge ends at most [edge]. Scaling the short
  /// side keeps the result right whichever way the photo is rotated.
  /// Unknown size: [edge] (the plugin then keeps the short side at most
  /// that). Never enlarges.
  static int shortSideTarget((int, int)? size, {int edge = longEdge}) {
    if (size == null) {
      return edge;
    }
    final (int w, int h) = size;
    final int long = math.max(w, h);
    final int short = math.min(w, h);
    if (long <= edge) {
      return short;
    }
    return math.max(1, (short * edge / long).round());
  }

  /// True for WebP data (RIFF....WEBP).
  static bool isWebp(Uint8List b) =>
      b.length >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50;
}

class NativeImageCompressor implements ImageCompressor {
  const NativeImageCompressor();

  @override
  Future<Uint8List> compress(Uint8List bytes, {required bool document, bool webp = false}) async {
    final int side = ImageSizing.shortSideTarget(ImageSizing.size(bytes));
    try {
      return await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: side,
        minHeight: side,
        // Documents get a touch more quality so small print stays sharp.
        quality: document ? 85 : ImageSizing.quality,
        format: webp && !kIsWeb ? CompressFormat.webp : CompressFormat.jpeg,
        // keepExif stays at its default (false): location metadata is dropped.
      );
    } on Object {
      if (!kIsWeb) {
        rethrow;
      }
      // Web needs an extra script for this plugin (Stage 2).
      return bytes;
    }
  }
}

final Provider<ImageCompressor> imageCompressorProvider = Provider<ImageCompressor>(
  (Ref ref) => const NativeImageCompressor(),
);
