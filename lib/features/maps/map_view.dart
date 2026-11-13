import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/maps/google_map_view.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// What a map shows. Screens describe the map with this; the widget that
/// draws it is chosen by [mapViewBuilderProvider] (Google Maps in real
/// builds, a sketch in tests, the gallery and builds without a key).

enum MapMarkerKind { home, school, selectedSchool }

/// A pin: the parent's own home or a school. Other parents are never pins.
@immutable
class MapMarker {
  const MapMarker({required this.id, required this.at, required this.kind, required this.label, this.onTap});

  final String id;
  final GeoPin at;
  final MapMarkerKind kind;

  /// Screen-reader label and tooltip.
  final String label;
  final VoidCallback? onTap;
}

/// Another parent: a soft blurred disc around the server's rounded and
/// offset point, never a pin.
@immutable
class MapArea {
  const MapArea({required this.id, required this.center, required this.label, this.onTap});

  final String id;
  final GeoPin center;
  final String label;
  final VoidCallback? onTap;
}

/// Moves the map and remembers where it is.
class MapCameraController extends ChangeNotifier {
  MapCameraController({required this._center, this._zoom = AppMapTokens.cityZoom});

  GeoPin _center;
  double _zoom;

  GeoPin get center => _center;
  double get zoom => _zoom;

  /// Moves the map (short animation, none with reduce motion).
  void moveTo(GeoPin center, {double? zoom}) {
    _center = center;
    _zoom = zoom ?? _zoom;
    notifyListeners();
  }

  /// The map reports where the parent moved it (no rebuild).
  void reportCamera(GeoPin center, double zoom) {
    _center = center;
    _zoom = zoom;
  }
}

@immutable
class MapViewConfig {
  const MapViewConfig({
    required this.camera,
    required this.semanticLabel,
    this.markers = const <MapMarker>[],
    this.areas = const <MapArea>[],
    this.radiusKm,
    this.radiusCenter,
    this.onCameraIdle,
  });

  final MapCameraController camera;
  final String semanticLabel;
  final List<MapMarker> markers;
  final List<MapArea> areas;

  /// A faint ring of this radius around [radiusCenter] (on the nearby map:
  /// the parent's rounded home, where the server measures from).
  final double? radiusKm;
  final GeoPin? radiusCenter;

  /// Where the map stopped after the parent moved it.
  final ValueChanged<GeoPin>? onCameraIdle;
}

typedef MapViewBuilder = Widget Function(BuildContext context, MapViewConfig config);

Widget googleMapViewBuilder(BuildContext context, MapViewConfig config) => GoogleMapView(config: config);

Widget sketchMapViewBuilder(BuildContext context, MapViewConfig config) => SketchMapView(config: config);

Widget previewMapViewBuilder(BuildContext context, MapViewConfig config) =>
    SketchMapView(config: config, previewLabel: context.l10n.mapPreviewLabel);

Widget unavailableMapViewBuilder(BuildContext context, MapViewConfig config) => const MapUnavailableView();

/// Google Maps when this build has a key; otherwise a sketch preview in
/// dev (so the screens still work on the emulators) and a calm "map
/// unavailable" note in staging and prod. Tests override it with a sketch.
final Provider<MapViewBuilder> mapViewBuilderProvider = Provider<MapViewBuilder>((Ref ref) {
  final FlavorConfig config = ref.watch(flavorConfigProvider);
  if (config.mapsEnabled) {
    return googleMapViewBuilder;
  }
  return config.showDevTools ? previewMapViewBuilder : unavailableMapViewBuilder;
});

/// Draws a map with the builder of [mapViewBuilderProvider].
class AppMapView extends ConsumerWidget {
  const AppMapView({required this.config, super.key});

  final MapViewConfig config;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Semantics(
      container: true,
      label: config.semanticLabel,
      child: ClipRect(child: ref.watch(mapViewBuilderProvider)(context, config)),
    );
  }
}

/// Shown instead of the map in builds without a Maps key.
class MapUnavailableView extends StatelessWidget {
  const MapUnavailableView({super.key});

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return ColoredBox(
      color: context.colors.surface,
      child: Center(
        child: SingleChildScrollView(
          child: EmptyStateView(icon: Icons.map_outlined, title: l10n.mapUnavailableTitle, body: l10n.mapUnavailableBody),
        ),
      ),
    );
  }
}

/// A drawn map with the same markers, discs and panning as the real one.
/// Used in widget tests, screenshots, the gallery and dev builds without a
/// Maps key. Keys: `map.marker.<id>` and `map.area.<id>`.
class SketchMapView extends StatefulWidget {
  const SketchMapView({required this.config, super.key, this.previewLabel});

  final MapViewConfig config;

  /// Shown in a corner when this stands in for a real map.
  final String? previewLabel;

  @override
  State<SketchMapView> createState() => _SketchMapViewState();
}

class _SketchMapViewState extends State<SketchMapView> {
  @override
  void initState() {
    super.initState();
    widget.config.camera.addListener(_onMove);
  }

  @override
  void didUpdateWidget(SketchMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config.camera != widget.config.camera) {
      oldWidget.config.camera.removeListener(_onMove);
      widget.config.camera.addListener(_onMove);
    }
  }

  @override
  void dispose() {
    widget.config.camera.removeListener(_onMove);
    super.dispose();
  }

  void _onMove() => setState(() {});

  static const double _metersPerDegree = 111320;

  double get _metersPerPixel {
    final MapCameraController c = widget.config.camera;
    return 156543.03392 * math.cos(c.center.lat * math.pi / 180) / math.pow(2, c.zoom);
  }

  Offset _project(GeoPin p, Size size) {
    final GeoPin c = widget.config.camera.center;
    final double mpp = _metersPerPixel;
    final double dx = (p.lng - c.lng) * _metersPerDegree * math.cos(c.lat * math.pi / 180) / mpp;
    final double dy = -(p.lat - c.lat) * _metersPerDegree / mpp;
    return Offset(size.width / 2 + dx, size.height / 2 + dy);
  }

  void _pan(Offset delta) {
    final MapCameraController c = widget.config.camera;
    final double mpp = _metersPerPixel;
    final GeoPin next = GeoPin(
      c.center.lat + delta.dy * mpp / _metersPerDegree,
      c.center.lng - delta.dx * mpp / (_metersPerDegree * math.cos(c.center.lat * math.pi / 180)),
    );
    c.reportCamera(next, c.zoom);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    final MapViewConfig config = widget.config;
    final String? preview = widget.previewLabel;
    // A map is not mirrored in Arabic: north is up and east is right.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size size = constraints.biggest;
          final double mpp = _metersPerPixel;
          final double? ringKm = config.radiusKm;
          final GeoPin? ringCenter = config.radiusCenter;
          return GestureDetector(
            key: const Key('map.surface'),
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (DragUpdateDetails d) => _pan(d.delta),
            onPanEnd: (DragEndDetails _) => config.onCameraIdle?.call(config.camera.center),
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: CustomPaint(
                    painter: _SketchPainter(
                      land: colors.surface,
                      road: context.appColors.surfaceRaised,
                      edge: colors.outlineVariant,
                      water: colors.primaryContainer,
                      offset: _project(Geo.cairo, size),
                    ),
                  ),
                ),
                if (ringKm != null && ringCenter != null)
                  _disc(
                    center: _project(ringCenter, size),
                    radius: ringKm * 1000 / mpp,
                    color: colors.primary.withValues(alpha: AppMapTokens.radiusRingOpacity),
                    border: colors.primary,
                  ),
                for (final MapArea a in config.areas) _area(a, _project(a.center, size), mpp, colors),
                for (final MapMarker m in config.markers) _marker(m, _project(m.at, size), colors),
                if (preview != null)
                  PositionedDirectional(
                    top: AppSpacing.s8,
                    start: AppSpacing.s8,
                    child: AppStatusBadge(label: preview, icon: Icons.draw_outlined),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _disc({required Offset center, required double radius, required Color color, Color? border}) {
    final Color? b = border;
    return Positioned(
      left: center.dx - radius,
      top: center.dy - radius,
      width: radius * 2,
      height: radius * 2,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: b == null ? null : Border.all(color: b.withValues(alpha: AppMapTokens.blurInnerOpacity)),
          ),
        ),
      ),
    );
  }

  Widget _area(MapArea a, Offset at, double mpp, ColorScheme colors) {
    final double outer = math.max(AppSpacing.minTouchTarget / 2, AppMapTokens.blurOuterRadiusM / mpp);
    final double inner = math.max(AppSpacing.s16, AppMapTokens.blurInnerRadiusM / mpp);
    return Positioned(
      left: at.dx - outer,
      top: at.dy - outer,
      width: outer * 2,
      height: outer * 2,
      child: Semantics(
        button: true,
        label: a.label,
        child: GestureDetector(
          key: Key('map.area.${a.id}'),
          onTap: a.onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.primary.withValues(alpha: AppMapTokens.blurOuterOpacity),
            ),
            child: Center(
              child: SizedBox.square(
                dimension: inner * 2,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.primary.withValues(alpha: AppMapTokens.blurInnerOpacity),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _marker(MapMarker m, Offset at, ColorScheme colors) {
    const double size = AppSpacing.minTouchTarget;
    final (IconData icon, Color color) = switch (m.kind) {
      MapMarkerKind.home => (Icons.home_rounded, colors.primary),
      MapMarkerKind.school => (Icons.school_rounded, colors.onSurfaceVariant),
      MapMarkerKind.selectedSchool => (Icons.school_rounded, colors.primary),
    };
    return Positioned(
      left: at.dx - size / 2,
      top: at.dy - size / 2,
      width: size,
      height: size,
      child: Tooltip(
        message: m.label,
        child: Semantics(
          button: m.onTap != null,
          label: m.label,
          child: GestureDetector(
            key: Key('map.marker.${m.id}'),
            onTap: m.onTap,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: context.appColors.surfaceRaised,
                border: Border.all(color: color, width: AppBorders.focus),
              ),
              child: Icon(icon, color: color, size: AppIconSize.md),
            ),
          ),
        ),
      ),
    );
  }
}

class _SketchPainter extends CustomPainter {
  const _SketchPainter({required this.land, required this.road, required this.edge, required this.water, required this.offset});

  final Color land;
  final Color road;
  final Color edge;
  final Color water;

  /// Moves the drawing with the map.
  final Offset offset;

  static const double _block = AppSpacing.s64 * 2;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = land);
    final double ox = offset.dx % _block;
    final double oy = offset.dy % _block;
    // A river along one side, then a calm grid of streets.
    final Path river = Path()
      ..moveTo(ox - _block, -AppSpacing.s8)
      ..quadraticBezierTo(ox + size.width * 0.2, size.height * 0.5, ox - _block / 2, size.height + AppSpacing.s8)
      ..lineTo(ox - _block * 1.5, size.height + AppSpacing.s8)
      ..quadraticBezierTo(ox + size.width * 0.05, size.height * 0.5, ox - _block * 1.5, -AppSpacing.s8)
      ..close();
    canvas.drawPath(river, Paint()..color = water);
    final Paint street = Paint()
      ..color = road
      ..strokeWidth = AppSpacing.s8;
    final Paint streetEdge = Paint()
      ..color = edge
      ..strokeWidth = AppSpacing.s8 + AppBorders.hairline * 2;
    for (double x = ox; x < size.width; x += _block) {
      canvas
        ..drawLine(Offset(x, 0), Offset(x, size.height), streetEdge)
        ..drawLine(Offset(x, 0), Offset(x, size.height), street);
    }
    for (double y = oy; y < size.height; y += _block) {
      canvas
        ..drawLine(Offset(0, y), Offset(size.width, y), streetEdge)
        ..drawLine(Offset(0, y), Offset(size.width, y), street);
    }
  }

  @override
  bool shouldRepaint(_SketchPainter oldDelegate) =>
      oldDelegate.offset != offset || oldDelegate.land != land || oldDelegate.road != road || oldDelegate.water != water;
}
