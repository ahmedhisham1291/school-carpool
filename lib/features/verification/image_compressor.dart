import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shrinks a capture on the phone before upload: JPEG, the shorter side
/// scaled down to about 1600 (documents stay readable) or 1080 (selfies),
/// EXIF (and so any location) removed. The camera already captures at 1080p
/// (documents) or 720p (selfies), so results stay well under the 3 MB limit
/// in storage.rules. On the phone a failure is a capture error (the parent
/// retakes); only the web sends the original.
abstract interface class ImageCompressor {
  Future<Uint8List> compress(Uint8List bytes, {required bool document});
}

class NativeImageCompressor implements ImageCompressor {
  const NativeImageCompressor();

  @override
  Future<Uint8List> compress(Uint8List bytes, {required bool document}) async {
    final int side = document ? 1600 : 1080;
    try {
      return await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: side,
        minHeight: side,
        quality: document ? 85 : 80,
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
