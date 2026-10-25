// =============================================================================
// TAXI METER — RWANDA EDITION
// =============================================================================
// A single-file, production-ready Flutter application implementing a live
// taxi meter for drivers operating in Rwanda (default map center: Kigali).
//
// The map is rendered with `flutter_map` — a free, open-source Leaflet-style
// map widget that draws OpenStreetMap tiles. No Google Maps API key, no
// billing account, and no native Android/iOS map SDK setup required.
//
// -----------------------------------------------------------------------------
// REQUIRED SETUP (cannot be done from inside a single .dart file — do this in
// your Flutter project before running the app):
// -----------------------------------------------------------------------------
//
// 1) pubspec.yaml — add these dependencies:
//
//    dependencies:
//      flutter:
//        sdk: flutter
//      flutter_map: ^7.0.2
//      latlong2: ^0.9.1
//      geolocator: ^13.0.1
//
//    flutter:
//      assets:
//        - assets/driver_profile.png   # <-- your driver's profile photo goes here
//
// 2) Map tiles: this app uses the public OpenStreetMap tile server
//    (https://tile.openstreetmap.org) for demos and development. It is
//    rate-limited and its usage policy disallows heavy production traffic
//    (see https://operations.osmfoundation.org/policies/tiles/) — for a
//    real production app, point the `urlTemplate` in _buildTileLayer() below
//    at your own tile provider instead (e.g. MapTiler, Stadia Maps, Mapbox,
//    or a self-hosted tile server). No code changes beyond that URL are
//    needed. OpenStreetMap attribution is shown on-map and must stay visible
//    per its license, wherever the tiles come from.
//
// 3) Location permissions:
//    - Android: android/app/src/main/AndroidManifest.xml, above <application>:
//        <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
//        <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
//        <uses-permission android:name="android.permission.INTERNET"/>  <!-- for map tiles -->
//    - iOS: ios/Runner/Info.plist:
//        <key>NSLocationWhenInUseUsageDescription</key>
//        <string>Taxi Meter needs your location to track the ride and calculate the fare.</string>
//        <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
//        <string>Taxi Meter needs your location to track the ride and calculate the fare.</string>
//
// 4) Asset: place a PNG at assets/driver_profile.png. If it is missing or fails
//    to load, the UI automatically falls back to a generated avatar icon — see
//    _DriverAvatar below.
//
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TaxiMeterApp());
}

/// The app's brand palette — green, yellow and white — used throughout the
/// UI instead of scattering hex codes across widgets. Black/grey tones are
/// still used in a few places purely for text/icon contrast (e.g. on light
/// backgrounds), not as brand colors.
class AppColors {
  AppColors._();

  static const Color green = Color(0xFF1E8E3E);
  static const Color greenDark = Color(0xFF145C28);
  static const Color yellow = Color(0xFFFFC400);
}

// =============================================================================
// APP ROOT
// =============================================================================

class TaxiMeterApp extends StatelessWidget {
  const TaxiMeterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Taxi Meter Rwanda',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.green,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.green,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        fontFamily: 'Roboto',
      ),
      home: const MeterHomePage(),
    );
  }
}

// =============================================================================
// DOMAIN MODELS
// =============================================================================

/// The lifecycle state of a single ride.
enum RideStatus { idle, running, waiting, finished }

/// Driver-configurable fare parameters, all denominated in Rwandan Francs (RWF).
class FareSettings {
  final double baseFare; // RWF, charged once per ride
  final double ratePerKm; // RWF per kilometer traveled
  final double waitingRatePerMinute; // RWF per minute stationary / waiting

  const FareSettings({
    this.baseFare = 1000,
    this.ratePerKm = 350,
    this.waitingRatePerMinute = 50,
  });

  FareSettings copyWith({
    double? baseFare,
    double? ratePerKm,
    double? waitingRatePerMinute,
  }) {
    return FareSettings(
      baseFare: baseFare ?? this.baseFare,
      ratePerKm: ratePerKm ?? this.ratePerKm,
      waitingRatePerMinute: waitingRatePerMinute ?? this.waitingRatePerMinute,
    );
  }
}

/// Immutable snapshot of a finished ride, used to show the end-of-ride summary.
class RideSummary {
  final double distanceMeters;
  final Duration movingDuration;
  final Duration waitingDuration;
  final double fare;

  const RideSummary({
    required this.distanceMeters,
    required this.movingDuration,
    required this.waitingDuration,
    required this.fare,
  });

  Duration get totalDuration => movingDuration + waitingDuration;
}

/// Thrown when the app cannot obtain the location permissions/services it needs.
class LocationUnavailableException implements Exception {
  final LocationFailureReason reason;
  const LocationUnavailableException(this.reason);
}

enum LocationFailureReason { serviceDisabled, permissionDenied, permissionDeniedForever }

// =============================================================================
// FORMATTING HELPERS (pure functions — the "utils" layer)
// =============================================================================

class Formatters {
  Formatters._();

  static String distance(double meters) {
    if (meters < 1000) {
      return '${meters.toStringAsFixed(0)} m';
    }
    return '${(meters / 1000).toStringAsFixed(2)} km';
  }

  static String duration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (hours > 0) {
      return '${two(hours)}:${two(minutes)}:${two(seconds)}';
    }
    return '${two(minutes)}:${two(seconds)}';
  }

  static String speedKmh(double kmh) => '${kmh.toStringAsFixed(0)} km/h';

  /// Formats a RWF amount with thousands separators, e.g. 12345 -> "RWF 12,345".
  static String rwf(double amount) {
    final rounded = amount.round().abs();
    final digits = rounded.toString();
    final buffer = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      final posFromEnd = digits.length - i;
      buffer.write(digits[i]);
      final isGroupBoundary = posFromEnd > 1 && (posFromEnd - 1) % 3 == 0;
      if (isGroupBoundary) buffer.write(',');
    }
    final sign = amount < 0 ? '-' : '';
    return 'RWF $sign${buffer.toString()}';
  }

  static String rwfPerKm(double amount) => '${rwf(amount)} / km';

  static String rwfPerMin(double amount) => '${rwf(amount)} / min';
}

// =============================================================================
// SERVICES LAYER
// =============================================================================

/// Wraps `geolocator` so the rest of the app never talks to the plugin
/// directly. Makes permission handling and the position stream testable.
class LocationService {
  /// Ensures location services are on and permission is granted.
  /// Throws [LocationUnavailableException] describing exactly why it failed,
  /// so the UI can show the right recovery action to the driver.
  Future<void> ensureReady() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw const LocationUnavailableException(LocationFailureReason.serviceDisabled);
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw const LocationUnavailableException(LocationFailureReason.permissionDenied);
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw const LocationUnavailableException(LocationFailureReason.permissionDeniedForever);
    }
  }

  Future<Position> currentPosition() {
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
  }

  Stream<Position> positionStream() {
    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 2, // meters — filters out GPS micro-jitter at the source
    );
    return Geolocator.getPositionStream(locationSettings: settings);
  }

  Future<void> openLocationSettings() => Geolocator.openLocationSettings();

  Future<void> openAppSettings() => Geolocator.openAppSettings();

  double distanceBetween(double lat1, double lon1, double lat2, double lon2) {
    return Geolocator.distanceBetween(lat1, lon1, lat2, lon2);
  }
}

/// Pure fare calculation, kept separate from the controller so it can be
/// unit-tested and re-used (e.g. for a fare estimator screen) independently.
class FareCalculator {
  FareCalculator._();

  static double calculate({
    required FareSettings settings,
    required double distanceMeters,
    required Duration waitingDuration,
  }) {
    final distanceKm = distanceMeters / 1000.0;
    final distanceCost = distanceKm * settings.ratePerKm;
    final waitingMinutes = waitingDuration.inSeconds / 60.0;
    final waitingCost = waitingMinutes * settings.waitingRatePerMinute;
    return settings.baseFare + distanceCost + waitingCost;
  }
}

// =============================================================================
// STATE / CONTROLLER LAYER
// =============================================================================

/// The single source of truth for an in-progress ride. Exposed to the UI via
/// [ChangeNotifier] + [AnimatedBuilder] / [ListenableBuilder] — no external
/// state-management package required.
class MeterController extends ChangeNotifier {
  MeterController({LocationService? locationService})
      : locationService = locationService ?? LocationService();

  final LocationService locationService;

  RideStatus status = RideStatus.idle;
  FareSettings settings = const FareSettings();

  final List<LatLng> track = [];
  Position? lastPosition;

  double distanceMeters = 0;
  double currentSpeedKmh = 0;

  final Stopwatch _movingStopwatch = Stopwatch();
  Duration _waitingAccumulated = Duration.zero;
  DateTime? _waitingStartedAt;

  StreamSubscription<Position>? _positionSub;
  Timer? _uiTicker;

  Duration get movingDuration => _movingStopwatch.elapsed;

  Duration get waitingDuration {
    if (_waitingStartedAt == null) return _waitingAccumulated;
    return _waitingAccumulated + DateTime.now().difference(_waitingStartedAt!);
  }

  Duration get totalElapsed => movingDuration + waitingDuration;

  double get fare => FareCalculator.calculate(
        settings: settings,
        distanceMeters: distanceMeters,
        waitingDuration: waitingDuration,
      );

  bool get canStart => status == RideStatus.idle;
  bool get isRunning => status == RideStatus.running;
  bool get isWaiting => status == RideStatus.waiting;
  bool get isFinished => status == RideStatus.finished;

  /// Starts a brand-new ride, or resumes one that was paused for waiting.
  Future<void> startOrResume() async {
    if (status == RideStatus.running) return;

    await locationService.ensureReady();

    if (status == RideStatus.idle || status == RideStatus.finished) {
      track.clear();
      distanceMeters = 0;
      currentSpeedKmh = 0;
      lastPosition = null;
      _waitingAccumulated = Duration.zero;
      _waitingStartedAt = null;
      _movingStopwatch.reset();
    } else if (status == RideStatus.waiting && _waitingStartedAt != null) {
      _waitingAccumulated += DateTime.now().difference(_waitingStartedAt!);
      _waitingStartedAt = null;
    }

    status = RideStatus.running;
    _movingStopwatch.start();

    _positionSub ??= locationService.positionStream().listen(
          _onPosition,
          onError: (_) {
            // A transient GPS error should not crash the ride; the stream
            // will keep emitting once the signal recovers.
          },
        );

    _uiTicker ??= Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());

    notifyListeners();
  }

  /// Switches the meter into "waiting" mode: distance stops accruing at the
  /// per-km rate and the waiting-time rate starts instead (e.g. traffic jam,
  /// passenger running an errand).
  void pauseForWaiting() {
    if (status != RideStatus.running) return;
    status = RideStatus.waiting;
    _movingStopwatch.stop();
    _waitingStartedAt = DateTime.now();
    notifyListeners();
  }

  /// Ends the ride, stops all timers/streams and returns a summary snapshot.
  Future<RideSummary> stopAndFinish() async {
    if (_waitingStartedAt != null) {
      _waitingAccumulated += DateTime.now().difference(_waitingStartedAt!);
      _waitingStartedAt = null;
    }
    _movingStopwatch.stop();

    await _positionSub?.cancel();
    _positionSub = null;
    _uiTicker?.cancel();
    _uiTicker = null;

    status = RideStatus.finished;

    final summary = RideSummary(
      distanceMeters: distanceMeters,
      movingDuration: _movingStopwatch.elapsed,
      waitingDuration: _waitingAccumulated,
      fare: fare,
    );

    notifyListeners();
    return summary;
  }

  /// Clears everything so the driver can start a fresh ride from idle.
  void resetForNewRide() {
    status = RideStatus.idle;
    track.clear();
    distanceMeters = 0;
    currentSpeedKmh = 0;
    lastPosition = null;
    _waitingAccumulated = Duration.zero;
    _waitingStartedAt = null;
    _movingStopwatch.reset();
    notifyListeners();
  }

  void updateSettings(FareSettings newSettings) {
    settings = newSettings;
    notifyListeners();
  }

  void _onPosition(Position position) {
    final speedMs = position.speed;
    currentSpeedKmh = (speedMs.isFinite && speedMs > 0) ? speedMs * 3.6 : 0;

    if (status == RideStatus.running) {
      final previous = lastPosition;
      if (previous != null) {
        final segment = locationService.distanceBetween(
          previous.latitude,
          previous.longitude,
          position.latitude,
          position.longitude,
        );
        // Ignore sub-meter jitter from GPS noise while stationary.
        if (segment > 1.0) {
          distanceMeters += segment;
          track.add(LatLng(position.latitude, position.longitude));
        }
      } else {
        track.add(LatLng(position.latitude, position.longitude));
      }
    }

    lastPosition = position;
    notifyListeners();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _uiTicker?.cancel();
    super.dispose();
  }
}

// =============================================================================
// PRESENTATION LAYER — HOME PAGE
// =============================================================================

class MeterHomePage extends StatefulWidget {
  const MeterHomePage({super.key});

  @override
  State<MeterHomePage> createState() => _MeterHomePageState();
}

class _MeterHomePageState extends State<MeterHomePage> {
  static const LatLng _kigaliCenter = LatLng(-1.9441, 30.0619);

  late final MeterController _controller;
  final MapController _mapController = MapController();
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    _controller = MeterController();
    _controller.addListener(_onControllerChanged);
    _bootstrapLocation();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _mapController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    final position = _controller.lastPosition;
    if (position != null && _mapReady) {
      _mapController.move(
        LatLng(position.latitude, position.longitude),
        _mapController.camera.zoom,
      );
    }
  }

  Future<void> _bootstrapLocation() async {
    try {
      await _controller.locationService.ensureReady();
      final position = await _controller.locationService.currentPosition();
      _controller.lastPosition = position;
      if (mounted && _mapReady) {
        _mapController.move(LatLng(position.latitude, position.longitude), 16);
      }
      if (mounted) setState(() {});
    } on LocationUnavailableException catch (e) {
      if (mounted) _showLocationIssueDialog(e.reason);
    } catch (_) {
      // Initial location is best-effort; the map simply stays on Kigali.
    }
  }

  Future<void> _handleStart() async {
    try {
      await _controller.startOrResume();
    } on LocationUnavailableException catch (e) {
      if (mounted) _showLocationIssueDialog(e.reason);
    }
  }

  void _handlePauseOrResume() {
    if (_controller.isRunning) {
      _controller.pauseForWaiting();
    } else if (_controller.isWaiting) {
      _handleStart();
    }
  }

  Future<void> _handleStop() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Finish ride?'),
        content: const Text('This will stop the meter and calculate the final fare.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Finish'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final summary = await _controller.stopAndFinish();
    if (!mounted) return;
    await _showSummaryDialog(summary);
    _controller.resetForNewRide();
  }

  Future<void> _showSummaryDialog(RideSummary summary) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Ride complete'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SummaryRow(label: 'Distance', value: Formatters.distance(summary.distanceMeters)),
            _SummaryRow(label: 'Moving time', value: Formatters.duration(summary.movingDuration)),
            _SummaryRow(label: 'Waiting time', value: Formatters.duration(summary.waitingDuration)),
            _SummaryRow(label: 'Total time', value: Formatters.duration(summary.totalDuration)),
            const Divider(height: 24),
            _SummaryRow(
              label: 'TOTAL FARE',
              value: Formatters.rwf(summary.fare),
              emphasize: true,
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('New ride'),
          ),
        ],
      ),
    );
  }

  void _showLocationIssueDialog(LocationFailureReason reason) {
    String title;
    String message;
    String actionLabel;
    VoidCallback action;

    switch (reason) {
      case LocationFailureReason.serviceDisabled:
        title = 'Location services off';
        message = 'Please enable location services (GPS) to use the meter.';
        actionLabel = 'Open settings';
        action = () => _controller.locationService.openLocationSettings();
        break;
      case LocationFailureReason.permissionDenied:
        title = 'Location permission needed';
        message = 'Taxi Meter needs access to your location to track the ride.';
        actionLabel = 'Try again';
        action = _bootstrapLocation;
        break;
      case LocationFailureReason.permissionDeniedForever:
        title = 'Location permission blocked';
        message = 'Location access was permanently denied. Please enable it from app settings.';
        actionLabel = 'Open app settings';
        action = () => _controller.locationService.openAppSettings();
        break;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Dismiss'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              action();
            },
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }

  Future<void> _openFareSettings() async {
    final result = await showModalBottomSheet<FareSettings>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _FareSettingsSheet(initial: _controller.settings),
    );
    if (result != null) {
      _controller.updateSettings(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Taxi Meter — Kigali'),
        actions: [
          IconButton(
            tooltip: 'Fare settings',
            icon: const Icon(Icons.tune),
            onPressed: _openFareSettings,
          ),
        ],
      ),
      drawer: _DriverDrawer(onOpenSettings: _openFareSettings),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _kigaliCenter,
              initialZoom: 13,
              maxZoom: 19,
              onMapReady: () {
                setState(() => _mapReady = true);
                final position = _controller.lastPosition;
                if (position != null) {
                  _mapController.move(LatLng(position.latitude, position.longitude), 16);
                }
              },
            ),
            children: [
              // Free OpenStreetMap tiles — swap this urlTemplate for your own
              // tile provider before shipping to production (see the setup
              // notes at the top of this file).
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.taxi_meter_app',
                maxZoom: 19,
              ),
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _controller.track,
                    color: AppColors.yellow,
                    strokeWidth: 6,
                    strokeCap: StrokeCap.round,
                    strokeJoin: StrokeJoin.round,
                  ),
                ],
              ),
              if (_controller.lastPosition != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(
                        _controller.lastPosition!.latitude,
                        _controller.lastPosition!.longitude,
                      ),
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.green,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: const [
                            BoxShadow(color: Colors.black38, blurRadius: 6),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              // Required attribution for OpenStreetMap's tile usage policy —
              // keep this visible if you swap in a different tile provider,
              // updating the attribution text to match that provider's terms.
              const RichAttributionWidget(
                attributions: [
                  TextSourceAttribution('OpenStreetMap contributors'),
                ],
              ),
            ],
          ),
          if (!_mapReady)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black12,
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: _StatsPanel(controller: _controller),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: _ControlCard(
                controller: _controller,
                onStart: _handleStart,
                onPauseResume: _handlePauseOrResume,
                onStop: _handleStop,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// PRESENTATION LAYER — REUSABLE WIDGETS
// =============================================================================

/// Top overlay showing the four headline numbers: fare, distance, time, speed.
class _StatsPanel extends StatelessWidget {
  const _StatsPanel({required this.controller});

  final MeterController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.greenDark.withOpacity(0.92),
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _StatusBadge(status: controller.status),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            Formatters.rwf(controller.fare),
            style: const TextStyle(
              color: AppColors.yellow,
              fontSize: 40,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _MiniStat(
                icon: Icons.route,
                label: 'Distance',
                value: Formatters.distance(controller.distanceMeters),
              ),
              _MiniStat(
                icon: Icons.timer_outlined,
                label: 'Time',
                value: Formatters.duration(controller.totalElapsed),
              ),
              _MiniStat(
                icon: Icons.speed,
                label: 'Speed',
                value: Formatters.speedKmh(controller.currentSpeedKmh),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final RideStatus status;

  @override
  Widget build(BuildContext context) {
    late final String label;
    late final Color color;
    switch (status) {
      case RideStatus.idle:
        label = 'READY';
        color = Colors.white70;
        break;
      case RideStatus.running:
        label = 'ON TRIP';
        color = AppColors.yellow;
        break;
      case RideStatus.waiting:
        label = 'WAITING';
        color = Colors.white;
        break;
      case RideStatus.finished:
        label = 'FINISHED';
        color = Colors.white70;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color, width: 1.2),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.1),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: Colors.white70, size: 18),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
      ],
    );
  }
}

/// Bottom floating card holding the ride control buttons.
class _ControlCard extends StatelessWidget {
  const _ControlCard({
    required this.controller,
    required this.onStart,
    required this.onPauseResume,
    required this.onStop,
  });

  final MeterController controller;
  final Future<void> Function() onStart;
  final VoidCallback onPauseResume;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 14, offset: Offset(0, 6))],
      ),
      child: controller.canStart || controller.isFinished
          ? SizedBox(
              width: double.infinity,
              height: 58,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.green,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: onStart,
                icon: const Icon(Icons.play_arrow, size: 28),
                label: const Text(
                  'START RIDE',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            )
          : Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 58,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: controller.isWaiting ? AppColors.green : Colors.amber.shade800,
                        side: BorderSide(
                          color: controller.isWaiting ? AppColors.green : Colors.amber.shade800,
                          width: 1.6,
                        ),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: onPauseResume,
                      icon: Icon(controller.isWaiting ? Icons.play_arrow : Icons.pause),
                      label: Text(
                        controller.isWaiting ? 'RESUME' : 'PAUSE / WAITING',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 58,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        // Intentionally red rather than the brand palette —
                        // "stop" actions are universally read as red/danger,
                        // and keeping that convention matters more here than
                        // strict palette consistency.
                        backgroundColor: const Color(0xFFD32F2F),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: onStop,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text(
                        'STOP & FINISH',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value, this.emphasize = false});

  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: emphasize ? 16 : 14,
              fontWeight: emphasize ? FontWeight.bold : FontWeight.normal,
              color: emphasize ? Colors.black : Colors.black87,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: emphasize ? 20 : 14,
              fontWeight: FontWeight.bold,
              color: emphasize ? const Color(0xFFB8860B) : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// DRIVER PROFILE + DRAWER
// =============================================================================

class _DriverDrawer extends StatelessWidget {
  const _DriverDrawer({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            color: AppColors.greenDark,
            child: const Row(
              children: [
                _DriverAvatar(radius: 32),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Robert',
                        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Taxi • Kigali, Rwanda',
                        style: TextStyle(color: Colors.white60, fontSize: 13),
                      ),
                      SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(Icons.star, color: AppColors.yellow, size: 16),
                          SizedBox(width: 4),
                          Text('4.8', style: TextStyle(color: Colors.white, fontSize: 13)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Fare settings'),
            subtitle: const Text('Base fare, rate per km, waiting rate'),
            onTap: () {
              Navigator.of(context).pop();
              onOpenSettings();
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About Taxi Meter'),
            onTap: () {
              Navigator.of(context).pop();
              showAboutDialog(
                context: context,
                applicationName: 'Taxi Meter Rwanda',
                applicationVersion: '1.0.0',
                children: const [
                  Text('A live GPS taxi meter built for drivers operating in Rwanda.'),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Shows the driver's photo from `assets/driver_profile.png`. If the asset is
/// missing, unreadable, or still loading, falls back to a generated icon
/// avatar so the UI never shows a broken-image placeholder.
class _DriverAvatar extends StatelessWidget {
  const _DriverAvatar({required this.radius});

  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: Image.asset(
        'assets/driver_profile.png', // <-- driver's photo asset path
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _fallbackAvatar(),
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) return child;
          return _fallbackAvatar();
        },
      ),
    );
  }

  Widget _fallbackAvatar() {
    return Container(
      width: radius * 2,
      height: radius * 2,
      color: AppColors.yellow,
      child: Icon(Icons.local_taxi, color: AppColors.greenDark, size: radius),
    );
  }
}

// =============================================================================
// FARE SETTINGS BOTTOM SHEET
// =============================================================================

class _FareSettingsSheet extends StatefulWidget {
  const _FareSettingsSheet({required this.initial});

  final FareSettings initial;

  @override
  State<_FareSettingsSheet> createState() => _FareSettingsSheetState();
}

class _FareSettingsSheetState extends State<_FareSettingsSheet> {
  late final TextEditingController _baseFareCtrl;
  late final TextEditingController _ratePerKmCtrl;
  late final TextEditingController _waitingRateCtrl;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _baseFareCtrl = TextEditingController(text: widget.initial.baseFare.toStringAsFixed(0));
    _ratePerKmCtrl = TextEditingController(text: widget.initial.ratePerKm.toStringAsFixed(0));
    _waitingRateCtrl = TextEditingController(text: widget.initial.waitingRatePerMinute.toStringAsFixed(0));
  }

  @override
  void dispose() {
    _baseFareCtrl.dispose();
    _ratePerKmCtrl.dispose();
    _waitingRateCtrl.dispose();
    super.dispose();
  }

  String? _validatePositiveNumber(String? value) {
    if (value == null || value.trim().isEmpty) return 'Required';
    final parsed = double.tryParse(value.trim());
    if (parsed == null) return 'Enter a valid number';
    if (parsed < 0) return 'Must be zero or more';
    return null;
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final settings = FareSettings(
      baseFare: double.parse(_baseFareCtrl.text.trim()),
      ratePerKm: double.parse(_ratePerKmCtrl.text.trim()),
      waitingRatePerMinute: double.parse(_waitingRateCtrl.text.trim()),
    );
    Navigator.of(context).pop(settings);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const Text(
              'Fare calibration',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'All amounts are in Rwandan Francs (RWF).',
              style: TextStyle(color: Colors.black54, fontSize: 13),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _baseFareCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Base fare (RWF)',
                prefixIcon: Icon(Icons.attach_money),
                border: OutlineInputBorder(),
              ),
              validator: _validatePositiveNumber,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _ratePerKmCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Rate per kilometer (RWF/km)',
                prefixIcon: Icon(Icons.route_outlined),
                border: OutlineInputBorder(),
              ),
              validator: _validatePositiveNumber,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _waitingRateCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Waiting rate (RWF/min)',
                prefixIcon: Icon(Icons.hourglass_bottom),
                border: OutlineInputBorder(),
              ),
              validator: _validatePositiveNumber,
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton(
                onPressed: _save,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.green,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Save settings', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
