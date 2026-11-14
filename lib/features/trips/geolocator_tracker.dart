import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, HttpClientRequest, HttpClientResponse, HttpException, SocketException;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:school_carpool/features/trips/location_tracker.dart';
import 'package:school_carpool/settings/settings_store.dart';

/// One location fix, independent of the plugin's own type (tests build it
/// without the plugin).
@immutable
class GeoFix {
  const GeoFix({required this.lat, required this.lng, required this.at, this.accuracy, this.speed, this.heading});

  final double lat;
  final double lng;

  /// UTC.
  final DateTime at;

  /// Metres.
  final double? accuracy;

  /// Metres per second; negative when unknown.
  final double? speed;
  final double? heading;

  /// The body shape the tripLocation function parses (functions/src/trips/model.ts parseUpload).
  Map<String, Object?> toUpload() => <String, Object?>{
    'coords': <String, Object?>{'latitude': lat, 'longitude': lng, 'accuracy': ?accuracy, 'speed': ?speed, 'heading': ?heading},
    'timestamp': at.toUtc().toIso8601String(),
  };

  static GeoFix? fromUpload(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Object? coords = raw['coords'];
    final Object? ts = raw['timestamp'];
    if (coords is! Map || ts is! String) {
      return null;
    }
    final Object? lat = coords['latitude'];
    final Object? lng = coords['longitude'];
    final DateTime? at = DateTime.tryParse(ts)?.toUtc();
    if (lat is! num || lng is! num || at == null) {
      return null;
    }
    double? n(Object? v) => v is num ? v.toDouble() : null;
    return GeoFix(lat: lat.toDouble(), lng: lng.toDouble(), at: at, accuracy: n(coords['accuracy']), speed: n(coords['speed']), heading: n(coords['heading']));
  }
}

/// The few geolocator calls the tracker and the driving gate use, behind
/// one interface so unit tests use a fake platform.
abstract interface class GeoSource {
  Future<bool> serviceEnabled();
  Future<LocationPermission> checkPermission();

  /// Shows the system prompt. On iPhone only "While Using the App" is asked.
  Future<LocationPermission> requestPermission();
  Future<LocationAccuracyStatus> accuracy();
  Stream<GeoFix> positions(LocationSettings settings);
  Future<GeoFix> current(LocationSettings settings);
  Stream<ServiceStatus> serviceStatus();
  Future<bool> openAppSettings();
  Future<bool> openLocationSettings();
}

class GeolocatorSource implements GeoSource {
  const GeolocatorSource();

  static GeoFix _fix(Position p) => GeoFix(
    lat: p.latitude,
    lng: p.longitude,
    at: p.timestamp.toUtc(),
    accuracy: p.accuracy,
    speed: p.speed,
    heading: p.heading,
  );

  @override
  Future<bool> serviceEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

  @override
  Future<LocationPermission> requestPermission() => Geolocator.requestPermission();

  @override
  Future<LocationAccuracyStatus> accuracy() => Geolocator.getLocationAccuracy();

  @override
  Stream<GeoFix> positions(LocationSettings settings) => Geolocator.getPositionStream(locationSettings: settings).map(_fix);

  @override
  Future<GeoFix> current(LocationSettings settings) async => _fix(await Geolocator.getCurrentPosition(locationSettings: settings));

  @override
  Stream<ServiceStatus> serviceStatus() => Geolocator.getServiceStatusStream();

  @override
  Future<bool> openAppSettings() => Geolocator.openAppSettings();

  @override
  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();
}

/// Posts one batch of points; returns the HTTP status. Throws
/// [PointPostOffline] when the phone cannot reach the server.
abstract interface class PointPoster {
  Future<int> post(String url, String token, String body);
}

class PointPostOffline implements Exception {
  const PointPostOffline();
}

class HttpPointPoster implements PointPoster {
  const HttpPointPoster();

  @override
  Future<int> post(String url, String token, String body) async {
    final HttpClient client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final HttpClientRequest request = await client.postUrl(Uri.parse(url));
      request.headers
        ..set('Content-Type', 'application/json')
        ..set('Authorization', 'Bearer $token');
      request.add(utf8.encode(body));
      final HttpClientResponse response = await request.close().timeout(const Duration(seconds: 15));
      await response.drain<void>();
      return response.statusCode;
    } on SocketException {
      throw const PointPostOffline();
    } on TimeoutException {
      throw const PointPostOffline();
    } on HttpException {
      throw const PointPostOffline();
    } finally {
      client.close();
    }
  }
}

/// [LocationTracker] on the phone with the free geolocator plugin (owner
/// decision, docs/DECISIONS.md "Location tracking on iPhone", 14 Nov 2026).
///
/// - iPhone: "While Using the App" with Precise Location, background
///   location mode on and the blue indicator shown, so tracking goes on
///   with the phone locked or another app open. iOS stops it when the
///   driver swipes the app away; the server then pushes "Run still on"
///   after 2 minutes and tells the parents.
/// - Points go into an on-phone buffer (at most [maxBuffered] points, none
///   older than a day, kept across restarts) and are posted in batches of
///   [batchSize] to the tripLocation function with the run's token (same
///   body the paid plugin's uploader sent). A weak connection only delays
///   them. 401 or 410 (the run is over) stops tracking at once.
/// - A car waiting at a gate sends nothing with a distance filter, so a
///   heartbeat fix is taken when no point came for [heartbeatEvery].
///
/// Never logs a coordinate (PRIVACY).
class GeolocatorTracker implements LocationTracker {
  GeolocatorTracker({
    required this._store,
    this._source = const GeolocatorSource(),
    this._poster = const HttpPointPoster(),
    this._now = _utcNow,
    this.platform,
    this.timers = true,
  }) {
    _restore();
  }

  static DateTime _utcNow() => DateTime.now().toUtc();

  static const String storeKey = 'liveRun.v1';
  static const int batchSize = 50;
  static const int maxBuffered = 2000;
  static const Duration heartbeatEvery = Duration(seconds: 60);
  static const Duration flushEvery = Duration(seconds: 15);
  static const Duration keepAtMost = Duration(days: 1);

  final SettingsStore _store;
  final GeoSource _source;
  final PointPoster _poster;
  final DateTime Function() _now;

  /// For tests; defaults to the running platform.
  final TargetPlatform? platform;

  /// Off in unit tests (they call [heartbeat] and [flush] directly).
  final bool timers;

  final StreamController<TrackerStatus> _status = StreamController<TrackerStatus>.broadcast();
  TrackerSession? _session;
  bool _running = false;
  final List<GeoFix> _buffer = <GeoFix>[];
  StreamSubscription<GeoFix>? _positions;
  StreamSubscription<ServiceStatus>? _service;
  Timer? _heartbeat;
  Timer? _flushTimer;
  DateTime? _lastFix;
  Future<void>? _flushing;
  int _unsaved = 0;

  /// Points waiting to be sent (tests and the run screen).
  int get pending => _buffer.length;

  /// The settings the owner chose (DECISIONS.md): best accuracy, automotive
  /// navigation, about 15 m between points, no automatic pausing,
  /// background updates with the blue indicator.
  /// [background] and [autoPause] are parameters (not literals) so every
  /// chosen value stays written out here.
  static LocationSettings settingsFor(TargetPlatform platform, {Duration? timeLimit, bool background = true, bool autoPause = false}) {
    return switch (platform) {
      TargetPlatform.iOS || TargetPlatform.macOS => AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: 15,
        pauseLocationUpdatesAutomatically: autoPause,
        allowBackgroundLocationUpdates: background,
        showBackgroundLocationIndicator: background,
        timeLimit: timeLimit,
      ),
      // Android (Stage 3): background tracking there needs a foreground
      // service notification; added with the Android prompt.
      TargetPlatform.android => AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 15,
        intervalDuration: const Duration(seconds: 5),
        timeLimit: timeLimit,
      ),
      _ => LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 15, timeLimit: timeLimit),
    };
  }

  TargetPlatform get _platform => platform ?? defaultTargetPlatform;

  static TrackerPermission mapPermission(LocationPermission p) => switch (p) {
    LocationPermission.always => TrackerPermission.always,
    LocationPermission.whileInUse => TrackerPermission.whileInUse,
    LocationPermission.deniedForever => TrackerPermission.denied,
    // iOS answers "denied" before the parent was ever asked.
    LocationPermission.denied || LocationPermission.unableToDetermine => TrackerPermission.notAsked,
  };

  void _restore() {
    final String? raw = _store.read(storeKey);
    if (raw == null) {
      return;
    }
    try {
      final Object? data = jsonDecode(raw);
      if (data is! Map) {
        return;
      }
      final Object? trip = data['trip'];
      final Object? url = data['url'];
      final Object? token = data['token'];
      if (trip is String && url is String && token is String) {
        _session = TrackerSession(tripId: trip, uploadUrl: url, token: token);
      }
      final Object? points = data['points'];
      if (points is List) {
        final DateTime oldest = _now().subtract(keepAtMost);
        _buffer.addAll(points.map(GeoFix.fromUpload).whereType<GeoFix>().where((GeoFix f) => f.at.isAfter(oldest)));
      }
    } on FormatException {
      unawaited(_store.write(storeKey, null));
    }
  }

  Future<void> _persist() {
    _unsaved = 0;
    final TrackerSession? s = _session;
    if (s == null) {
      return _store.write(storeKey, null);
    }
    return _store.write(
      storeKey,
      jsonEncode(<String, Object?>{
        'trip': s.tripId,
        'url': s.uploadUrl,
        'token': s.token,
        'points': _buffer.map((GeoFix f) => f.toUpload()).toList(),
      }),
    );
  }

  @override
  Future<TrackerPermission> permission() async {
    if (!await _source.serviceEnabled()) {
      return TrackerPermission.serviceOff;
    }
    return mapPermission(await _source.checkPermission());
  }

  @override
  Future<void> openSettings() async {
    await _source.openAppSettings();
  }

  @override
  Future<void> start(TrackerSession session) async {
    final TrackerPermission p = await permission();
    if (p != TrackerPermission.whileInUse && p != TrackerPermission.always) {
      throw StateError('location permission missing');
    }
    final TrackerSession? before = _session;
    if (before != null && before.tripId != session.tripId) {
      // Another run's points: that run is over.
      _buffer.clear();
    }
    _session = session;
    await _persist();
    if (!_running) {
      _running = true;
      _positions = _source.positions(settingsFor(_platform)).listen(_onFix, onError: _onStreamError);
      _service = _source.serviceStatus().listen((ServiceStatus s) {
        if (s == ServiceStatus.disabled) {
          _status.add(TrackerStatus(tracking: true, tripId: _session?.tripId, lastFixAt: _lastFix, permission: TrackerPermission.serviceOff));
        }
      }, onError: (Object _) {});
      if (timers) {
        _heartbeat = Timer.periodic(heartbeatEvery, (_) => unawaited(heartbeat()));
        _flushTimer = Timer.periodic(flushEvery, (_) => unawaited(flush()));
      }
    }
    _status.add(TrackerStatus(tracking: true, tripId: session.tripId, permission: p));
    unawaited(flush());
  }

  void _onStreamError(Object error) {
    // Permission taken away or Location Services switched off mid-run: the
    // run screen shows the steps; the server tells the parents.
    final TrackerPermission p = error is LocationServiceDisabledException ? TrackerPermission.serviceOff : TrackerPermission.denied;
    _status.add(TrackerStatus(tracking: _running, tripId: _session?.tripId, lastFixAt: _lastFix, permission: p));
  }

  void _onFix(GeoFix fix) {
    if (!_running) {
      return;
    }
    _lastFix = fix.at;
    _buffer.add(fix);
    if (_buffer.length > maxBuffered) {
      _buffer.removeRange(0, _buffer.length - maxBuffered);
    }
    // Saved at once while the buffer is small, then every 10th point (a
    // long offline stretch would otherwise rewrite it on every fix).
    _unsaved++;
    if (_buffer.length <= batchSize || _unsaved >= 10) {
      unawaited(_persist());
    }
    _status.add(TrackerStatus(tracking: true, tripId: _session?.tripId, lastFixAt: fix.at));
    unawaited(flush());
  }

  /// A car standing still sends nothing with a distance filter: take one
  /// fix when none came for most of a minute.
  @visibleForTesting
  Future<void> heartbeat() async {
    if (!_running) {
      return;
    }
    final DateTime? last = _lastFix;
    if (last != null && _now().difference(last) < heartbeatEvery - const Duration(seconds: 10)) {
      return;
    }
    try {
      _onFix(await _source.current(settingsFor(_platform, timeLimit: const Duration(seconds: 20))));
    } on Object catch (error) {
      if (error is LocationServiceDisabledException || error is PermissionDeniedException) {
        _onStreamError(error);
      }
    }
  }

  /// Sends what waits, batch by batch. One flush at a time.
  Future<void> flush() => _flushing ??= _flush().whenComplete(() => _flushing = null);

  Future<void> _flush() async {
    while (_buffer.isNotEmpty) {
      final TrackerSession? s = _session;
      if (s == null) {
        return;
      }
      final List<GeoFix> batch = _buffer.take(batchSize).toList();
      final String body = jsonEncode(<String, Object?>{'location': batch.map((GeoFix f) => f.toUpload()).toList()});
      final int status;
      try {
        status = await _poster.post(s.uploadUrl, s.token, body);
      } on PointPostOffline {
        return;
      }
      if (status == 401 || status == 410) {
        // The run is over (last drop-off, timeout, signed out): stop now.
        await stop();
        return;
      }
      if (status >= 500 || status == 429) {
        return;
      }
      // 200 (kept) or 400 (bad points, never resent).
      _buffer.removeRange(0, math.min(batch.length, _buffer.length));
      await _persist();
    }
  }

  @override
  Future<void> stop({bool keepUnsent = false}) async {
    if (keepUnsent && _session != null) {
      try {
        await flush();
      } on Object {
        // Offline: what is left is dropped below; the server already
        // treats the run as ended.
      }
    }
    _running = false;
    await _positions?.cancel();
    await _service?.cancel();
    _positions = null;
    _service = null;
    _heartbeat?.cancel();
    _flushTimer?.cancel();
    _heartbeat = null;
    _flushTimer = null;
    _session = null;
    _lastFix = null;
    _buffer.clear();
    await _persist();
    _status.add(TrackerStatus.idle);
  }

  @override
  Future<String?> activeTrip() async => _session?.tripId;

  @override
  Stream<TrackerStatus> get status => _status.stream;

  Future<void> dispose() async {
    await _positions?.cancel();
    await _service?.cancel();
    _heartbeat?.cancel();
    _flushTimer?.cancel();
    await _status.close();
  }
}
