import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shrinks a capture on the phone before upload: JPEG, longest side about
/// 1600 (documents stay readable) or 1080 (selfies), EXIF (and so any
/// location) removed. A 12 MP photo of 3 to 5 MB becomes about 200 to
/// 500 KB, well under the 3 MB limit in storage.rules.
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
      // Web needs an extra script for this plugin (Stage 2). The camera
      // already captures at a moderate resolution, so send it as it is.
      return bytes;
    }
  }
}

final Provider<ImageCompressor> imageCompressorProvider = Provider<ImageCompressor>(
  (Ref ref) => const NativeImageCompressor(),
);
