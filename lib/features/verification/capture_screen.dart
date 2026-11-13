import 'dart:async';
import 'dart:io' show File;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/verification/image_compressor.dart';
import 'package:school_carpool/features/verification/screen_security.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/settings/app_settings.dart';

/// What to capture.
@immutable
class CaptureRequest {
  const CaptureRequest(this.kind, {this.challenge = LivenessChallenge.left});

  final CaptureKind kind;

  /// Head-turn direction for the second selfie.
  final LivenessChallenge challenge;

  bool get isSelfie => kind == CaptureKind.selfie;
}

/// Compressed JPEG bytes, kept in memory only.
@immutable
class CaptureResult {
  const CaptureResult(this.image, {this.turnImage});

  final Uint8List image;

  /// Selfie only: the photo taken after the head-turn prompt.
  final Uint8List? turnImage;
}

/// Opens the camera and returns the capture, or null when cancelled.
/// Tests replace it with a fake that returns fixed bytes.
typedef CaptureLauncher = Future<CaptureResult?> Function(BuildContext context, CaptureRequest request);

final Provider<CaptureLauncher> captureLauncherProvider = Provider<CaptureLauncher>(
  (Ref ref) =>
      (BuildContext context, CaptureRequest request) => Navigator.of(context).push<CaptureResult>(
        MaterialPageRoute<CaptureResult>(
          fullscreenDialog: true,
          builder: (BuildContext context) => CaptureScreen(request: request),
        ),
      ),
);

enum _Phase { starting, denied, failed, aiming, turning, processing, review }

/// Camera screen for documents and the live selfie (spec section 3, steps
/// 3 to 6). Camera only: there is no gallery picker anywhere in the app.
/// The camera writes each photo to the app's temporary folder; it is read,
/// compressed and deleted at once, and never reaches the photo library.
/// Screenshots are blocked while it is open ([SecureScreen]).
///
/// Selfie with a liveness prompt: the parent looks straight and taps the
/// button, then the app asks them to turn their head left or right (picked
/// at random) and takes a second photo after a short count. The reviewer
/// checks the second photo matches the direction; the automated liveness
/// check comes with the Valify SDK (F18).
///
/// States: starting (spinner), camera denied (how to allow it in
/// Settings), failed (retry), aiming, turning (count), processing, review
/// (retake or use). No network is needed here.
class CaptureScreen extends ConsumerStatefulWidget {
  const CaptureScreen({required this.request, super.key});

  final CaptureRequest request;

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends ConsumerState<CaptureScreen> with WidgetsBindingObserver {
  static const int _turnSeconds = 3;

  CameraController? _controller;
  _Phase _phase = _Phase.starting;
  Uint8List? _image;
  Uint8List? _turnImage;
  int _countdown = _turnSeconds;
  Timer? _timer;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    unawaited(_controller?.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? controller = _controller;
    if (state == AppLifecycleState.inactive && controller != null) {
      _controller = null;
      _timer?.cancel();
      unawaited(controller.dispose());
      if (_phase == _Phase.aiming || _phase == _Phase.turning) {
        setState(() => _phase = _Phase.starting);
      }
    } else if (state == AppLifecycleState.resumed && controller == null && _phase != _Phase.review) {
      unawaited(_start());
    }
  }

  Future<void> _start() async {
    // The permission prompt makes the app inactive and then resumed; do not
    // start a second camera while the first one is still starting.
    if (_starting) {
      return;
    }
    _starting = true;
    setState(() => _phase = _Phase.starting);
    try {
      final List<CameraDescription> cameras = await availableCameras();
      final CameraLensDirection wanted = widget.request.isSelfie
          ? CameraLensDirection.front
          : CameraLensDirection.back;
      if (cameras.isEmpty) {
        throw CameraException('NoCamera', null);
      }
      final CameraDescription camera = cameras.firstWhere(
        (CameraDescription c) => c.lensDirection == wanted,
        orElse: () => cameras.first,
      );
      final CameraController controller = CameraController(
        camera,
        widget.request.isSelfie ? ResolutionPreset.high : ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _phase = _image == null ? _Phase.aiming : _Phase.review;
      });
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }
      final bool denied = error.code.startsWith('CameraAccess');
      setState(() => _phase = denied ? _Phase.denied : _Phase.failed);
    } finally {
      _starting = false;
    }
  }

  /// Takes a photo, compresses it and deletes the camera's temporary file.
  Future<Uint8List?> _shoot() async {
    final CameraController? controller = _controller;
    if (controller == null || !controller.value.isInitialized || controller.value.isTakingPicture) {
      return null;
    }
    final ImageCompressor compressor = ref.read(imageCompressorProvider);
    try {
      final XFile file = await controller.takePicture();
      final Uint8List raw = await file.readAsBytes();
      if (!kIsWeb) {
        try {
          await File(file.path).delete();
        } on Object catch (error) {
          debugPrint('capture: temporary file not deleted ($error)');
        }
      }
      return await compressor.compress(raw, document: !widget.request.isSelfie);
    } on Object {
      // Camera or compression failure: show the camera error with a retry.
      if (mounted) {
        setState(() => _phase = _Phase.failed);
      }
      return null;
    }
  }

  Future<void> _onShutter() async {
    setState(() => _phase = _Phase.processing);
    final Uint8List? image = await _shoot();
    if (!mounted || image == null) {
      return;
    }
    if (!widget.request.isSelfie) {
      setState(() {
        _image = image;
        _phase = _Phase.review;
      });
      return;
    }
    setState(() {
      _image = image;
      _phase = _Phase.turning;
      _countdown = _turnSeconds;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_countdown > 1) {
        setState(() => _countdown -= 1);
        return;
      }
      timer.cancel();
      unawaited(_takeTurnPhoto());
    });
  }

  Future<void> _takeTurnPhoto() async {
    setState(() => _phase = _Phase.processing);
    final Uint8List? turn = await _shoot();
    if (!mounted || turn == null) {
      return;
    }
    setState(() {
      _turnImage = turn;
      _phase = _Phase.review;
    });
  }

  void _retake() {
    setState(() {
      _image = null;
      _turnImage = null;
      _phase = _controller == null ? _Phase.starting : _Phase.aiming;
    });
    if (_controller == null) {
      unawaited(_start());
    }
  }

  void _use() {
    final Uint8List? image = _image;
    if (image == null) {
      return;
    }
    Navigator.of(context).pop(CaptureResult(image, turnImage: _turnImage));
  }

  String _title(AppLocalizations l10n) => switch (widget.request.kind) {
    CaptureKind.idFront => l10n.captureIdFrontTitle,
    CaptureKind.idBack => l10n.captureIdBackTitle,
    CaptureKind.selfie => l10n.captureSelfieTitle,
    CaptureKind.schoolId => l10n.captureSchoolIdTitle,
    CaptureKind.license => l10n.captureLicenseTitle,
    CaptureKind.carLicense => l10n.captureCarLicenseTitle,
  };

  String _hint(AppLocalizations l10n) {
    if (_phase == _Phase.turning) {
      return widget.request.challenge == LivenessChallenge.left
          ? l10n.captureTurnLeft(_countdown)
          : l10n.captureTurnRight(_countdown);
    }
    return switch (widget.request.kind) {
      CaptureKind.selfie => l10n.captureSelfieHint,
      CaptureKind.idBack => l10n.captureIdBackHint,
      _ => l10n.captureDocumentHint,
    };
  }

  @override
  Widget build(BuildContext context) {
    final FlavorConfig config = ref.watch(flavorConfigProvider);
    final DesignDirection direction = config.showDevTools ? ref.watch(designDirectionProvider) : DesignDirection.a;
    // The camera view is always dark, whatever the phone's theme.
    return SecureScreen(
      child: Theme(
        data: AppTheme.dark(direction, reduceMotion: AppMotion.reduceMotion(context)),
        child: Builder(builder: _buildScreen),
      ),
    );
  }

  Widget _buildScreen(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final CameraController? controller = _controller;
    final Uint8List? image = _image;

    final Widget body = switch (_phase) {
      _Phase.starting => _Spinner(label: l10n.captureStarting),
      _Phase.processing when image == null => _Spinner(label: l10n.capturePreparing),
      _Phase.denied => AppStateView(
        icon: Icons.no_photography_outlined,
        title: l10n.captureDeniedTitle,
        body: l10n.captureErrorDenied,
        tone: AppStateTone.warning,
        actionLabel: l10n.actionRetry,
        onAction: () => unawaited(_start()),
      ),
      _Phase.failed => ErrorStateView(body: l10n.captureErrorCamera, onRetry: () => unawaited(_start())),
      _Phase.review => _Review(image: image!, turnImage: _turnImage, onRetake: _retake, onUse: _use),
      _ => _Viewfinder(
        controller: controller,
        selfie: widget.request.isSelfie,
        hint: _hint(l10n),
        busy: _phase != _Phase.aiming,
        onShutter: () => unawaited(_onShutter()),
      ),
    };

    return Scaffold(
      backgroundColor: context.colors.surface,
      appBar: AppBar(
        title: Semantics(header: true, child: Text(_title(l10n))),
        leading: IconButton(
          key: const Key('capture.close'),
          tooltip: l10n.actionCancel,
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(top: false, child: body),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(label: label, child: const CircularProgressIndicator()),
  );
}

class _Viewfinder extends StatelessWidget {
  const _Viewfinder({
    required this.controller,
    required this.selfie,
    required this.hint,
    required this.busy,
    required this.onShutter,
  });

  final CameraController? controller;
  final bool selfie;
  final String hint;
  final bool busy;
  final VoidCallback onShutter;

  @override
  Widget build(BuildContext context) {
    final CameraController? camera = controller;
    return Column(
      children: <Widget>[
        Padding(
          padding: AppSpacing.screenPadding,
          child: Semantics(
            liveRegion: true,
            child: Text(hint, style: context.text.titleMedium, textAlign: TextAlign.center),
          ),
        ),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (camera != null && camera.value.isInitialized)
                ClipRect(child: Center(child: CameraPreview(camera))),
              IgnorePointer(child: CustomPaint(painter: _FramePainter(selfie: selfie, color: context.colors.primary))),
            ],
          ),
        ),
        Padding(
          padding: AppSpacing.screenPadding,
          child: Semantics(
            button: true,
            label: context.l10n.captureShutter,
            child: SizedBox.square(
              dimension: AppSpacing.driverTouchTarget + AppSpacing.s16,
              child: IconButton.filled(
                key: const Key('capture.shutter'),
                iconSize: AppSpacing.s40,
                onPressed: busy ? null : onShutter,
                icon: const Icon(Icons.camera_alt_rounded),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Card frame for documents (ID-1 ratio 85.6 by 54 mm) or an oval for the face.
class _FramePainter extends CustomPainter {
  _FramePainter({required this.selfie, required this.color});

  final bool selfie;
  final Color color;

  static const double _cardRatio = 85.6 / 54;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = AppSpacing.s4;
    final Offset center = size.center(Offset.zero);
    if (selfie) {
      final double width = size.width * 0.62;
      canvas.drawOval(Rect.fromCenter(center: center, width: width, height: width * 1.3), paint);
      return;
    }
    final double width = size.width - AppSpacing.s48;
    final Rect rect = Rect.fromCenter(center: center, width: width, height: width / _cardRatio);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(AppRadii.md)), paint);
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) => oldDelegate.selfie != selfie || oldDelegate.color != color;
}

class _Review extends StatelessWidget {
  const _Review({required this.image, required this.turnImage, required this.onRetake, required this.onUse});

  final Uint8List image;
  final Uint8List? turnImage;
  final VoidCallback onRetake;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final Uint8List? second = turnImage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: Padding(
            padding: AppSpacing.screenPadding,
            child: Row(
              children: <Widget>[
                Expanded(child: _Shot(bytes: image, label: l10n.captureReviewLabel)),
                if (second != null) ...<Widget>[
                  const SizedBox(width: AppSpacing.s8),
                  Expanded(child: _Shot(bytes: second, label: l10n.captureReviewTurnLabel)),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: AppSpacing.screenPadding,
          child: Text(l10n.captureReviewHint, style: context.text.bodyLarge, textAlign: TextAlign.center),
        ),
        Padding(
          padding: AppSpacing.screenPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AppButton(key: const Key('capture.use'), label: l10n.captureUse, expand: true, onPressed: onUse),
              const SizedBox(height: AppSpacing.s8),
              AppButton(
                key: const Key('capture.retake'),
                label: l10n.captureRetake,
                variant: AppButtonVariant.secondary,
                expand: true,
                onPressed: onRetake,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Shot extends StatelessWidget {
  const _Shot({required this.bytes, required this.label});

  final Uint8List bytes;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: label,
    child: ClipRRect(
      borderRadius: AppRadii.card,
      child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
    ),
  );
}
