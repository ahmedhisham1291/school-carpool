import 'dart:async';

import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/maps/map_style.dart';
import 'package:school_carpool/features/maps/map_view.dart';

/// The real map (google_maps_flutter: Google Maps SDK on iPhone and
/// Android, Maps JavaScript on the web). Styled from the theme's tokens,
/// no Google buttons, no tilt or rotation. Other parents are drawn as
/// two soft discs (never pins).
class GoogleMapView extends StatefulWidget {
  const GoogleMapView({required this.config, super.key});

  final MapViewConfig config;

  @override
  State<GoogleMapView> createState() => _GoogleMapViewState();
}

class _GoogleMapViewState extends State<GoogleMapView> {
  gm.GoogleMapController? _controller;

  @override
  void initState() {
    super.initState();
    widget.config.camera.addListener(_onMoveRequest);
  }

  @override
  void didUpdateWidget(GoogleMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config.camera != widget.config.camera) {
      oldWidget.config.camera.removeListener(_onMoveRequest);
      widget.config.camera.addListener(_onMoveRequest);
    }
  }

  @override
  void dispose() {
    widget.config.camera.removeListener(_onMoveRequest);
    _controller?.dispose();
    super.dispose();
  }

  static gm.LatLng _latLng(GeoPin p) => gm.LatLng(p.lat, p.lng);

  void _onMoveRequest() {
    final gm.GoogleMapController? controller = _controller;
    if (controller == null) {
      return;
    }
    final MapCameraController camera = widget.config.camera;
    final gm.CameraUpdate update = gm.CameraUpdate.newLatLngZoom(_latLng(camera.center), camera.zoom);
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    unawaited(reduceMotion ? controller.moveCamera(update) : controller.animateCamera(update));
  }

  gm.BitmapDescriptor _hue(Color color) => gm.BitmapDescriptor.defaultMarkerWithHue(HSVColor.fromColor(color).hue);

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    final MapViewConfig config = widget.config;
    final double? ringKm = config.radiusKm;
    final GeoPin? ringCenter = config.radiusCenter;

    final Set<gm.Marker> markers = <gm.Marker>{
      for (final MapMarker m in config.markers)
        gm.Marker(
          markerId: gm.MarkerId(m.id),
          position: _latLng(m.at),
          icon: _hue(switch (m.kind) {
            MapMarkerKind.home => colors.primary,
            MapMarkerKind.school => context.appColors.warning,
            MapMarkerKind.selectedSchool => context.appColors.success,
            MapMarkerKind.car => colors.primary,
          }),
          infoWindow: gm.InfoWindow(title: m.label),
          onTap: m.onTap,
        ),
    };

    final Set<gm.Circle> circles = <gm.Circle>{
      if (ringKm != null && ringCenter != null)
        gm.Circle(
          circleId: const gm.CircleId('radius'),
          center: _latLng(ringCenter),
          radius: ringKm * 1000,
          fillColor: colors.primary.withValues(alpha: AppMapTokens.radiusRingOpacity),
          strokeColor: colors.primary.withValues(alpha: AppMapTokens.blurInnerOpacity),
          strokeWidth: AppBorders.hairline.toInt(),
        ),
      for (final MapArea a in config.areas) ...<gm.Circle>{
        gm.Circle(
          circleId: gm.CircleId('${a.id}.outer'),
          center: _latLng(a.center),
          radius: AppMapTokens.blurOuterRadiusM,
          fillColor: colors.primary.withValues(alpha: AppMapTokens.blurOuterOpacity),
          strokeColor: Colors.transparent,
          strokeWidth: 0,
          consumeTapEvents: true,
          onTap: a.onTap,
        ),
        gm.Circle(
          circleId: gm.CircleId('${a.id}.inner'),
          center: _latLng(a.center),
          radius: AppMapTokens.blurInnerRadiusM,
          fillColor: colors.primary.withValues(alpha: AppMapTokens.blurInnerOpacity),
          strokeColor: Colors.transparent,
          strokeWidth: 0,
          consumeTapEvents: true,
          onTap: a.onTap,
        ),
      },
    };

    final MapCameraController camera = config.camera;
    return gm.GoogleMap(
      initialCameraPosition: gm.CameraPosition(target: _latLng(camera.center), zoom: camera.zoom),
      style: mapStyleJson(colors, context.appColors),
      markers: markers,
      circles: circles,
      onMapCreated: (gm.GoogleMapController controller) => _controller = controller,
      onCameraMove: (gm.CameraPosition p) => camera.reportCamera(GeoPin(p.target.latitude, p.target.longitude), p.zoom),
      onCameraIdle: () => config.onCameraIdle?.call(camera.center),
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      mapToolbarEnabled: false,
      compassEnabled: false,
      rotateGesturesEnabled: false,
      tiltGesturesEnabled: false,
      buildingsEnabled: false,
    );
  }
}
