import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'dart:ui' as ui show PictureRecorder, Image, ImageByteFormat, Gradient;

import 'package:flutter/foundation.dart';
import '../core/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:vibration/vibration.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart' as latlng2;

import '../core/game_dialog.dart';
import 'package:flutter_compass/flutter_compass.dart';

// ─── Constants ────────────────────────────────────────────────────────────────

const double _kCatchRadiusMeters = 20.0;
const double _kDefaultZoom = 18.0;
const int _kGpsRetries = 5;
const Duration _kGpsTimeout = Duration(seconds: 15);
const Duration _kGpsRetryDelay = Duration(seconds: 2);
const Duration _kNotificationDuration = Duration(seconds: 3);
const double _kPoliceAlertRadiusMeters = 40.0;

// ─── Data Model ───────────────────────────────────────────────────────────────

class _PlayerData {
  const _PlayerData({
    required this.id,
    required this.lat,
    required this.lng,
    required this.isPolice,
  });

  final String id;
  final double lat;
  final double lng;
  final bool isPolice;

  latlng2.LatLng get latLng => latlng2.LatLng(lat, lng);

  factory _PlayerData.fromMap(String id, Map<dynamic, dynamic> map) {
    return _PlayerData(
      id: id,
      lat: (map['lat'] as num).toDouble(),
      lng: (map['lng'] as num).toDouble(),
      isPolice: map['is_police'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _PlayerData &&
          id == other.id &&
          lat == other.lat &&
          lng == other.lng &&
          isPolice == other.isPolice;

  @override
  int get hashCode => Object.hash(id, lat, lng, isPolice);
}

enum MapTrackingMode {
  none,
  follow,
  navigation,
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class FreeMapGameScreen extends StatefulWidget {
  const FreeMapGameScreen({
    super.key,
    required this.gameId,
    required this.userId,
    required this.isPolice,
  });

  final String gameId;
  final String userId;
  final bool isPolice;

  @override
  State<FreeMapGameScreen> createState() => _FreeMapGameScreenState();
}

class _FreeMapGameScreenState extends State<FreeMapGameScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // Config state
  int _roomDurationSeconds = 40 * 60; // default 40 minutes
  bool _recenterPressed = false;

  // Firebase
  late final DatabaseReference _gameRef;
  StreamSubscription<DatabaseEvent>? _playersSubscription;
  StreamSubscription<DatabaseEvent>? _gameStatusSubscription;

  // Map
  final Completer<GoogleMapController> _mapController = Completer<GoogleMapController>();
  MapTrackingMode _trackingMode = MapTrackingMode.follow;
  bool _isProgrammaticMove = false;

  // Compass and Smooth Camera Animation
  StreamSubscription<CompassEvent>? _compassSubscription;
  double _smoothDx = 0.0;
  double _smoothDy = 0.0;
  double _currentBearing = 0.0;
  bool _hasCompass = false;

  Timer? _cameraUpdateTimer;
  LatLng? _lastAnimatedLocation;
  double? _lastAnimatedBearing;
  double? _lastAnimatedTilt;

  // Modernized Custom Icons
  BitmapDescriptor? _thiefIcon;
  BitmapDescriptor? _policeIcon;

  // Location
  latlng2.LatLng _currentLocation = const latlng2.LatLng(6.9271, 79.8612); // Colombo default
  StreamSubscription<Position>? _positionSubscription;
  String _locationStatus = 'Waiting for GPS…';

  // Game state
  List<_PlayerData> _visiblePlayers = [];
  List<_PlayerData> _latestPlayers = [];
  final ValueNotifier<List<Marker>> _markersNotifier = ValueNotifier([]);
  int _catchCount = 0;
  bool _gameRunning = true;
  bool _gameEnded = false;
  bool _policeRevealActive = false;
  bool _policeNearby = false;
  int _remainingHints = 3;
  Timer? _policeRevealTimer;
  final Set<String> _caughtThieves = {};

  // Timer
  final ValueNotifier<int> _elapsedSeconds = ValueNotifier(0);
  Timer? _gameTimer;

  bool _returnedFromSettings = false;
  bool _thiefCaughtNotified = false;

  // Catch counter animation
  late final AnimationController _catchAnimController;
  late final Animation<double> _catchScaleAnim;

  // Cached location settings (avoid re-allocating per GPS event)
  late final LocationSettings _locationSettings;
  Position? _lastGoodPosition;


  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    _catchAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _catchScaleAnim = Tween<double>(begin: 1.0, end: 1.3).animate(
      CurvedAnimation(parent: _catchAnimController, curve: Curves.elasticOut),
    );



    if (kIsWeb) {
      _locationSettings = LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
      );
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      _locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
        forceLocationManager: false,
        intervalDuration: const Duration(seconds: 1),
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      _locationSettings = AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
        activityType: ActivityType.fitness,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: false,
      );
    } else {
      _locationSettings = LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
      );
    }

    _gameRef = FirebaseDatabase.instance.ref();
    WidgetsBinding.instance.addObserver(this);
    _loadGameDuration();
    _startTimer();
    // Start Firebase listener immediately – independent of GPS permission.
    // Police sees thieves even before their own GPS fix arrives.
    _listenToPlayers();
    // Thieves listen for the police-left signal so they can win instantly.
    if (!widget.isPolice) _listenToGameStatus();
    _initLocation();
    _listenToCompass();
    _startCameraUpdateTimer();
    _initMarkerIcons();
  }

  @override
  void dispose() {
    _catchAnimController.dispose();
    _elapsedSeconds.dispose();
    _markersNotifier.dispose();
    _gameRunning = false;
    WidgetsBinding.instance.removeObserver(this);
    _gameTimer?.cancel();
    _policeRevealTimer?.cancel();
    _positionSubscription?.cancel();
    _playersSubscription?.cancel();
    _gameStatusSubscription?.cancel();
    _compassSubscription?.cancel();
    _cameraUpdateTimer?.cancel();
    // Fire-and-forget – no need to await on dispose.
    _gameRef.child('locations/${widget.gameId}/${widget.userId}').remove();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _returnedFromSettings) {
      _returnedFromSettings = false;
      _initLocation();
    }
  }

  // ── Timer ──────────────────────────────────────────────────────────────────

  void _loadGameDuration() {
    _gameRef.child('active_games/${widget.gameId}').get().then((snapshot) {
      if (!mounted) return;
      if (snapshot.exists) {
        final data = Map<dynamic, dynamic>.from(snapshot.value as Map);
        final durationMinutes = (data['duration_minutes'] as num?)?.toInt() ?? 40;
        setState(() {
          _roomDurationSeconds = durationMinutes * 60;
        });
      }
    }).catchError((err) {
      debugPrint("Error loading game duration: $err");
    });
  }

  void _startTimer() {
    _gameTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_gameRunning || _gameEnded) return;
      _elapsedSeconds.value++;
      if (_elapsedSeconds.value >= _roomDurationSeconds) {
        _endGameByTime();
      }
    });
  }

  void _endGameByTime() {
    if (_gameEnded) return;

    _gameEnded = true;
    _gameRunning = false;
    _gameTimer?.cancel();

    final durationMinutes = _roomDurationSeconds ~/ 60;
    final title = widget.isPolice ? 'TIME UP' : 'YOU WIN!';
    final message = widget.isPolice
        ? 'The room ended at $durationMinutes minutes. The thief wins.'
        : 'The room ended at $durationMinutes minutes. You win!';
    final icon = widget.isPolice ? Icons.timer_off : Icons.emoji_events;
    final color = widget.isPolice ? AppTheme.warning : AppTheme.success;

    _showFloatingNotification(
      title: title,
      message: message,
      icon: icon,
      color: color,
    );

    Future.delayed(const Duration(seconds: 2), () async {
      if (!mounted) return;
      await _gameRef.child('locations/${widget.gameId}/${widget.userId}').remove();
      if (mounted) Navigator.pop(context);
    });
  }

  static String _formatTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Location ───────────────────────────────────────────────────────────────

  Future<void> _initLocation() async {
    final granted = await _requestLocationPermission();
    if (!granted || !mounted) return;
    await _startLocationStream();
  }

  Future<bool> _requestLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _setStatus('GPS is OFF');
      await _showGpsOffDialog();
      return false;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.deniedForever) {
      _setStatus('Permission permanently denied');
      await _showPermanentlyDeniedDialog();
      return false;
    }

    if (permission == LocationPermission.denied) {
      _setStatus('Requesting permission…');
      for (var attempt = 0; attempt < 3; attempt++) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.always ||
            permission == LocationPermission.whileInUse) {
          break;
        }
        if (permission == LocationPermission.deniedForever) {
          _setStatus('Permission permanently denied');
          await _showPermanentlyDeniedDialog();
          return false;
        }
        if (attempt < 2 && mounted) {
          final retry = await _showPermissionRationaleDialog(attempt + 1);
          if (!retry) {
            _setStatus('Permission denied');
            return false;
          }
        }
      }
    }

    final final_ = await Geolocator.checkPermission();
    if (final_ == LocationPermission.always ||
        final_ == LocationPermission.whileInUse) {
      _setStatus('Starting GPS…');
      return true;
    }

    _setStatus('Permission denied');
    return false;
  }

  Future<void> _startLocationStream() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;

    Position? position;
    for (var i = 0; i < _kGpsRetries && position == null; i++) {
      try {
        _setStatus('Getting GPS… (${i + 1}/$_kGpsRetries)');
        position = await Geolocator.getCurrentPosition(
          locationSettings: _locationSettings,
        ).timeout(_kGpsTimeout);
      } catch (_) {
        if (i < _kGpsRetries - 1) await Future.delayed(_kGpsRetryDelay);
      }
    }

    if (position == null) {
      _setStatus('GPS failed — restart app');
      return;
    }

    _onPositionUpdate(position);
    await _animateToCurrentLocation();

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: _locationSettings,
    ).listen(
      _onPositionUpdate,
      onError: (error) {
        if (!mounted) return;
        _setStatus('GPS stream error');
      },
    );
  }

  // Throttle: skip Firebase write if movement < 2 m to cut bandwidth.
  latlng2.LatLng? _lastUploaded;

  void _onPositionUpdate(Position position) async {
    if (!_gameRunning || !mounted) return;

    final newLatLng = latlng2.LatLng(position.latitude, position.longitude);
    final accuracy = position.accuracy;
    final isInitial = _lastGoodPosition == null;
    final now = DateTime.now();
    final positionAge = position.timestamp.isAfter(now)
        ? position.timestamp.difference(now)
        : now.difference(position.timestamp);

    if (positionAge > const Duration(seconds: 30)) {
      _setStatus('Stale GPS fix');
      return;
    }

    final isFirstAcceptable = accuracy.isFinite && accuracy <= 150.0;
    final movedEnough = _lastGoodPosition == null
        ? true
        : _haversineDistance(
            latlng2.LatLng(_lastGoodPosition!.latitude, _lastGoodPosition!.longitude),
            newLatLng,
          ) >=
            2.0;
    final isAcceptable =
        (isInitial && isFirstAcceptable) ||
        (accuracy.isFinite && accuracy <= 100.0) ||
        movedEnough;

    if (!isAcceptable) {
      _setStatus('Low GPS accuracy');
      return;
    }

    _lastGoodPosition = position;
    _currentLocation = newLatLng;

    if (!_hasCompass && position.heading.isFinite && position.heading > 0.0) {
      _currentBearing = position.heading;
    }

    final shouldUpload =
        _lastUploaded == null ||
        _haversineDistance(_lastUploaded!, newLatLng) >= 2.0;

    if (shouldUpload) {
      _lastUploaded = newLatLng;
      _gameRef.child('locations/${widget.gameId}/${widget.userId}').update({
        'lat': position.latitude,
        'lng': position.longitude,
        'timestamp': ServerValue.timestamp,
        'is_police': widget.isPolice,
      });
    }

    if (_trackingMode != MapTrackingMode.none) {
      _updateCameraTick();
    }

    if (_locationStatus != 'GPS Active ✓') {
      _setStatus('GPS Active ✓');
    }
  }

  void _setStatus(String status) {
    if (!mounted || _locationStatus == status) return;
    setState(() => _locationStatus = status);
  }

  // ── Firebase listener ──────────────────────────────────────────────────────

  void _listenToPlayers() {
    _playersSubscription?.cancel();
    _playersSubscription = _gameRef
        .child('locations/${widget.gameId}')
        .onValue
        .listen(_onPlayersSnapshot);
  }

  void _onPlayersSnapshot(DatabaseEvent event) {
    if (!mounted) return;
    final raw = event.snapshot.value;

    if (raw == null) {
      if (_visiblePlayers.isNotEmpty) {
        setState(() => _visiblePlayers = []);
        _markersNotifier.value = [];
      }
      return;
    }

    final rawMap = Map<String, dynamic>.from(raw as Map);

    final allPlayers = <_PlayerData>[];
    for (final e in rawMap.entries) {
      final data = Map<dynamic, dynamic>.from(e.value as Map);
      if (data['lat'] == null || data['lng'] == null) continue;
      if (_caughtThieves.contains(e.key)) continue;
      allPlayers.add(_PlayerData.fromMap(e.key, data));
    }

    _latestPlayers = allPlayers;

    final visiblePlayers = _getVisiblePlayers(allPlayers);

    final changed = _listChanged(visiblePlayers, _visiblePlayers);
    if (changed) {
      _markersNotifier.value = visiblePlayers.map(_buildMarker).toList();
      setState(() => _visiblePlayers = visiblePlayers);
    }

    if (widget.isPolice) _checkCatches(allPlayers);

    if (!widget.isPolice) {
      final policeNearby = allPlayers.any((p) {
        return p.isPolice &&
            _haversineDistance(p.latLng, _currentLocation) <=
                _kPoliceAlertRadiusMeters;
      });

      if (policeNearby && !_policeNearby) {
        _policeNearby = true;
        _vibrate(1);
        _showFloatingNotification(
          title: 'POLICE NEARBY',
          message: 'A police officer is within 40 meters!',
          icon: Icons.warning_amber_rounded,
          color: Colors.orange.shade700,
        );
      } else if (!policeNearby) {
        _policeNearby = false;
      }
    }

    // Thief caught detection
    if (!widget.isPolice && !_thiefCaughtNotified) {
      final stillAlive = allPlayers.any((p) => p.id == widget.userId);
      if (!stillAlive && mounted) {
        _thiefCaughtNotified = true;
        _vibrate(1);
        _showFloatingNotification(
          title: '😭 YOU WERE CAUGHT!',
          message: 'The police caught you. Game over.',
          icon: Icons.sentiment_very_dissatisfied,
          color: Colors.red.shade700,
        );
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.pop(context);
        });
      }
    }
  }

  static bool _listChanged(
      List<_PlayerData> next, List<_PlayerData> prev) {
    if (next.length != prev.length) return true;
    for (var i = 0; i < next.length; i++) {
      if (next[i] != prev[i]) return true;
    }
    return false;
  }

  Marker _buildMarker(_PlayerData player) {
    final isSelf = player.id == widget.userId;
    
    if (isSelf) {
      return Marker(
        markerId: MarkerId(player.id),
        position: _toGoogleLatLng(_currentLocation),
        visible: _trackingMode == MapTrackingMode.none,
        icon: player.isPolice
            ? (_policeIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed))
            : (_thiefIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen)),
        anchor: const Offset(0.5, 1.0),
        infoWindow: InfoWindow(
          title: player.isPolice ? 'Police (You)' : 'Thief (You)',
          onTap: () => _showPlayerSnackBar(player, true),
        ),
        onTap: () => _showPlayerSnackBar(player, true),
      );
    }

    return Marker(
      markerId: MarkerId(player.id),
      position: LatLng(player.lat, player.lng),
      icon: player.isPolice
          ? (_policeIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed))
          : (_thiefIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen)),
      anchor: const Offset(0.5, 1.0),
      infoWindow: InfoWindow(
        title: player.isPolice ? 'Police' : 'Thief',
        onTap: () => _showPlayerSnackBar(player, false),
      ),
      onTap: () => _showPlayerSnackBar(player, false),
    );
  }

  void _showPlayerSnackBar(_PlayerData player, bool isSelf) {
    final label =
        '${player.isPolice ? '👮 Police' : '🦹 Thief'}${isSelf ? ' (You)' : ''}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(label),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<void> _checkCatches(List<_PlayerData> players) async {
    final self = players.firstWhere(
      (p) => p.id == widget.userId,
      orElse: () => _PlayerData(
        id: widget.userId,
        lat: _currentLocation.latitude,
        lng: _currentLocation.longitude,
        isPolice: true,
      ),
    );

    for (final player in players) {
      if (player.id == widget.userId) continue;
      if (player.isPolice) continue;
      if (_caughtThieves.contains(player.id)) continue;

      final dist = _haversineDistance(self.latLng, player.latLng);
      if (dist < _kCatchRadiusMeters) {
        _caughtThieves.add(player.id);

        await Future.wait([
          _gameRef.child('caught_events/${widget.gameId}/${player.id}').set({
            'caught_by': widget.userId,
            'caught_at': ServerValue.timestamp,
          }),
          _gameRef.child('locations/${widget.gameId}/${player.id}').remove(),
        ]);

        if (!mounted) return;
        setState(() => _catchCount++);
        _catchAnimController
            .forward()
            .then((_) => _catchAnimController.reverse());
        _vibrate(0);
        _showFloatingNotification(
          title: '🏆 THIEF CAUGHT!',
          message: 'You caught a thief! Total: $_catchCount',
          icon: Icons.celebration,
          color: Colors.green.shade700,
        );
      }
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static double _haversineDistance(latlng2.LatLng a, latlng2.LatLng b) {
    const r = 6371000.0;
    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLon = (b.longitude - a.longitude) * pi / 180;
    final sinDLat = sin(dLat / 2);
    final sinDLon = sin(dLon / 2);
    final h = sinDLat * sinDLat +
        cos(a.latitude * pi / 180) *
            cos(b.latitude * pi / 180) *
            sinDLon *
            sinDLon;
    return r * 2 * atan2(sqrt(h), sqrt(1 - h));
  }



  Future<void> _vibrate(int type) async {
    final hasVibrator = await Vibration.hasVibrator();
    if (!hasVibrator || !mounted) return;
    Vibration.vibrate(duration: type == 0 ? 50 : 200);
  }

  // ── Dialogs ────────────────────────────────────────────────────────────────

  Future<void> _showGpsOffDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => GameDialog(
        title: 'GPS Required',
        message:
            'Location services are turned off. Please enable GPS to play.',
        cancelLabel: 'Cancel',
        confirmLabel: 'Open Settings',
        onConfirm: () async {
          Navigator.pop(ctx);
          _returnedFromSettings = true;
          await Geolocator.openLocationSettings();
        },
        onCancel: () => Navigator.pop(ctx),
      ),
    );
  }

  Future<bool> _showPermissionRationaleDialog(int attempt) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => GameDialog(
        title: 'Location Required',
        message: attempt == 1
            ? 'This game needs your location to show you and other players on the map.'
            : 'Without location access the game cannot work. Please allow it.',
        cancelLabel: 'Cancel',
        confirmLabel: 'Allow',
        onConfirm: () => Navigator.pop(ctx, true),
        onCancel: () => Navigator.pop(ctx, false),
      ),
    );
    return result ?? false;
  }

  Future<void> _showPermanentlyDeniedDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => GameDialog(
        title: 'Permission Required',
        message:
            'Location permission is permanently denied.\n\nGo to App Settings → Permissions → Location → Allow.',
        cancelLabel: 'Cancel',
        confirmLabel: 'Open App Settings',
        onConfirm: () async {
          Navigator.pop(ctx);
          _returnedFromSettings = true;
          await Geolocator.openAppSettings();
        },
        onCancel: () => Navigator.pop(ctx),
      ),
    );
  }

  Future<bool> _onExitRequested() async {
    final confirm = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => GameDialog(
        title: 'EXIT GAME',
        message: 'Are you sure you want to leave this game?',
        cancelLabel: 'CANCEL',
        confirmLabel: 'EXIT',
        confirmColor: Colors.red.shade700,
        leadingIcon: Icons.warning_amber_rounded,
        onConfirm: () => Navigator.pop(ctx, true),
        onCancel: () => Navigator.pop(ctx, false),
      ),
    );

    if (confirm == true && mounted) {
      // If the police exits, broadcast the event BEFORE removing the
      // location so every thief's listener fires with the flag set.
      if (widget.isPolice) {
        await _gameRef.child('active_games/${widget.gameId}').update({
          'police_left': true,
          'police_left_at': ServerValue.timestamp,
        });
      }
      await _gameRef
          .child('locations/${widget.gameId}/${widget.userId}')
          .remove();
      if (mounted) Navigator.pop(context);
      return true;
    }
    return false;
  }

  // ── Police-left listener (thieves only) ────────────────────────────────────

  void _listenToGameStatus() {
    _gameStatusSubscription?.cancel();
    _gameStatusSubscription = _gameRef
        .child('active_games/${widget.gameId}')
        .onValue
        .listen(_onGameStatusChanged);
  }

  void _onGameStatusChanged(DatabaseEvent event) {
    if (!mounted || _gameEnded) return;
    final raw = event.snapshot.value;
    if (raw == null) return;

    final data = Map<dynamic, dynamic>.from(raw as Map);
    final policeLeft = data['police_left'] as bool? ?? false;

    if (policeLeft) {
      _handlePoliceLeft();
    }
  }

  void _handlePoliceLeft() {
    if (_gameEnded) return;

    _gameEnded = true;
    _gameRunning = false;
    _gameTimer?.cancel();
    _gameStatusSubscription?.cancel();

    _vibrate(1);
    _showFloatingNotification(
      title: '🏆 POLICE LEFT — YOU WIN!',
      message: 'The police has abandoned the chase. Thieves win!',
      icon: Icons.emoji_events_rounded,
      color: Colors.green.shade600,
    );

    Future.delayed(const Duration(seconds: 3), () async {
      if (!mounted) return;
      await _gameRef
          .child('locations/${widget.gameId}/${widget.userId}')
          .remove();
      if (mounted) Navigator.pop(context);
    });
  }

  void _useHint() {
    if (widget.isPolice || _remainingHints <= 0 || _policeRevealActive) return;

    setState(() {
      _remainingHints--;
      _policeRevealActive = true;
    });

    _showFloatingNotification(
      title: 'HINT USED',
      message: 'Police locations revealed for 10 seconds.',
      icon: Icons.visibility,
      color: Colors.blue.shade400,
    );

    _updateVisiblePlayers();

    _policeRevealTimer?.cancel();
    _policeRevealTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted) return;
      setState(() {
        _policeRevealActive = false;
      });
      _updateVisiblePlayers();
    });
  }

  List<_PlayerData> _getVisiblePlayers(List<_PlayerData> players) {
    final self = players.where((p) => p.id == widget.userId).toList();
    final others = players.where((p) => p.id != widget.userId).toList();
    
    final List<_PlayerData> visibleOthers;
    if (widget.isPolice) {
      visibleOthers = others;
    } else {
      visibleOthers = [
        ...others.where((p) => !p.isPolice),
        if (_policeRevealActive) ...others.where((p) => p.isPolice),
      ];
    }
    
    return [
      ...self,
      ...visibleOthers,
    ];
  }

  void _updateVisiblePlayers() {
    final visiblePlayers = _getVisiblePlayers(_latestPlayers);

    final changed = _listChanged(visiblePlayers, _visiblePlayers);
    if (changed) {
      _markersNotifier.value = visiblePlayers.map(_buildMarker).toList();
      setState(() => _visiblePlayers = visiblePlayers);
    }
  }

  void _showFloatingNotification({
    required String title,
    required String message,
    required IconData icon,
    required Color color,
  }) {
    if (!mounted) return;
    OverlayEntry? entry;
    entry = OverlayEntry(
      builder: (_) => _FloatingNotification(
        title: title,
        message: message,
        icon: icon,
        color: color,
        onDismiss: () => entry?.remove(),
      ),
    );
    Overlay.of(context).insert(entry);
    Future.delayed(_kNotificationDuration, () => entry?.remove());
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // PopScope replaces the deprecated WillPopScope.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _onExitRequested();
      },
      child: Scaffold(
        body: Stack(
          children: [
            _buildMap(),
            IgnorePointer(
              child: AnimatedOpacity(
                opacity: _trackingMode != MapTrackingMode.none ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 350),
                child: Center(
                  child: TacticalPlayerPin(
                    isPolice: widget.isPolice,
                    bearing: _currentBearing,
                    isNavigationMode: _trackingMode == MapTrackingMode.navigation,
                  ),
                ),
              ),
            ),
            _buildTopBar(),
            if (widget.isPolice) _buildCatchCounter(),
            _buildRecenterButton(),
            _buildBottomPanel(),
          ],
        ),
      ),
    );
  }

  Widget _buildMap() {
    return ValueListenableBuilder<List<Marker>>(
      valueListenable: _markersNotifier,
      builder: (_, markers, __) {
        return GoogleMap(
          initialCameraPosition: CameraPosition(
            target: _toGoogleLatLng(_currentLocation),
            zoom: _kDefaultZoom,
          ),
          mapType: MapType.normal,
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          compassEnabled: true,
          onMapCreated: (controller) {
            if (!_mapController.isCompleted) {
              _mapController.complete(controller);
            }
          },
          onCameraMoveStarted: () {
            if (!_isProgrammaticMove && _trackingMode != MapTrackingMode.none) {
              setState(() {
                _trackingMode = MapTrackingMode.none;
              });
              _updateMarkersList();
            }
          },
          markers: Set<Marker>.of(markers),
        );
      },
    );
  }

  LatLng _toGoogleLatLng(latlng2.LatLng point) {
    return LatLng(point.latitude, point.longitude);
  }

  Future<void> _animateToCurrentLocation() async {
    if (!_mapController.isCompleted) return;
    final controller = await _mapController.future;
    
    final targetBearing = _trackingMode == MapTrackingMode.navigation ? _currentBearing : 0.0;
    final targetTilt = _trackingMode == MapTrackingMode.navigation ? 45.0 : 0.0;

    _isProgrammaticMove = true;
    _lastAnimatedLocation = _toGoogleLatLng(_currentLocation);
    _lastAnimatedBearing = targetBearing;
    _lastAnimatedTilt = targetTilt;

    await controller.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: _toGoogleLatLng(_currentLocation),
          zoom: _kDefaultZoom,
          bearing: targetBearing,
          tilt: targetTilt,
        ),
      ),
      duration: const Duration(milliseconds: 300),
    );

    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) {
        _isProgrammaticMove = false;
      }
    });
  }

  void _listenToCompass() {
    _compassSubscription = FlutterCompass.events?.listen((CompassEvent event) {
      final heading = event.heading;
      if (heading != null) {
        _hasCompass = true;
        // Exponential Moving Average (EMA) using vector components to smooth out compass jitter
        final rad = heading * pi / 180.0;
        const alpha = 0.15; // smoothing factor (0.15 gives a smooth but responsive transition)
        
        if (_smoothDx == 0.0 && _smoothDy == 0.0) {
          _smoothDx = cos(rad);
          _smoothDy = sin(rad);
        } else {
          _smoothDx = _smoothDx * (1 - alpha) + cos(rad) * alpha;
          _smoothDy = _smoothDy * (1 - alpha) + sin(rad) * alpha;
        }
        
        double calculatedBearing = atan2(_smoothDy, _smoothDx) * 180.0 / pi;
        if (calculatedBearing < 0) {
          calculatedBearing += 360.0;
        }
        _currentBearing = calculatedBearing;
      }
    });
  }

  void _startCameraUpdateTimer() {
    _cameraUpdateTimer?.cancel();
    _cameraUpdateTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      _updateCameraTick();
    });
  }

  void _updateMarkersList() {
    final visiblePlayers = _getVisiblePlayers(_latestPlayers.isEmpty ? _visiblePlayers : _latestPlayers);
    _markersNotifier.value = visiblePlayers.map(_buildMarker).toList();
    if (mounted) {
      setState(() {});
    }
  }

  void _updateCameraTick() async {
    if (!_gameRunning || !mounted) return;
    
    final targetLatLng = _toGoogleLatLng(_currentLocation);
    final targetBearing = _trackingMode == MapTrackingMode.navigation ? _currentBearing : 0.0;
    final targetTilt = _trackingMode == MapTrackingMode.navigation ? 45.0 : 0.0;

    // Check if we actually need to animate
    final locChanged = _lastAnimatedLocation == null ||
        _haversineDistance(_currentLocation, latlng2.LatLng(_lastAnimatedLocation!.latitude, _lastAnimatedLocation!.longitude)) > 0.2;
    
    double bearingDiff = 0.0;
    if (_lastAnimatedBearing != null) {
      double diff = (targetBearing - _lastAnimatedBearing!).abs();
      bearingDiff = diff > 180 ? 360 - diff : diff;
    }
    
    final bearingChanged = _lastAnimatedBearing == null || bearingDiff > 0.5;
    final tiltChanged = _lastAnimatedTilt == null || _lastAnimatedTilt != targetTilt;

    // Rebuild marker list if position or rotation has updated to keep them perfectly in sync
    if (locChanged || bearingChanged || tiltChanged) {
      _updateMarkersList();
    }

    if (_trackingMode == MapTrackingMode.none) return;
    if (!_mapController.isCompleted) return;

    final controller = await _mapController.future;

    if (locChanged || bearingChanged || tiltChanged) {
      _isProgrammaticMove = true;
      _lastAnimatedLocation = targetLatLng;
      _lastAnimatedBearing = targetBearing;
      _lastAnimatedTilt = targetTilt;

      await controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: targetLatLng,
            zoom: _kDefaultZoom,
            bearing: targetBearing,
            tilt: targetTilt,
          ),
        ),
        duration: const Duration(milliseconds: 150),
      );

      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) {
          _isProgrammaticMove = false;
        }
      });
    }
  }

  Future<void> _initMarkerIcons() async {
    final thief = await _createCustomMarker(
      false, 
      const Color(0xFF2ECC71), 
      const Color(0xFF27AE60)
    );
    final police = await _createCustomMarker(
      true, 
      const Color(0xFFFF3366), 
      const Color(0xFFC0392B)
    );
    
    if (mounted) {
      setState(() {
        _thiefIcon = thief;
        _policeIcon = police;
      });
    }
  }

  Future<BitmapDescriptor> _createCustomMarker(bool isPolice, Color backgroundColor, Color borderColor) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    
    // Using larger canvas size for extreme high-DPI crispness on all devices (80x100)
    const double width = 80.0;
    const double height = 100.0;
    
    // Draw the ambient drop shadow underneath the pin's bottom tip (perfectly aligned with (40.0, 88.0))
    final Paint shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);
    canvas.drawOval(
      Rect.fromCenter(
        center: const Offset(40.0, 90.0),
        width: 32.0,
        height: 10.0,
      ),
      shadowPaint,
    );

    // Build modern sleek teardrop path centered horizontally at x=40, pin head y=36, tip at y=88
    final Path pinPath = Path();
    pinPath.moveTo(40.0, 88.0); // bottom tip
    pinPath.cubicTo(18.0, 56.0, 18.0, 36.0, 18.0, 36.0); // left pointer to head
    pinPath.arcToPoint(
      const Offset(62.0, 36.0),
      radius: const Radius.circular(22.0),
      clockwise: true,
    ); // top circle head
    pinPath.cubicTo(62.0, 36.0, 62.0, 56.0, 40.0, 88.0); // right head to pointer tip
    pinPath.close();

    // Premium Linear Gradient matching the role
    final Color colorDark = isPolice ? const Color(0xFF0F172A) : const Color(0xFF0D0D0D);
    final Color colorLight = isPolice ? const Color(0xFF1E40AF) : const Color(0xFF065F46);
    
    final Paint pinPaint = Paint()
      ..shader = ui.Gradient.linear(
        const Offset(40.0, 14.0),
        const Offset(40.0, 88.0),
        [colorLight, colorDark],
      )
      ..style = PaintingStyle.fill;
    canvas.drawPath(pinPath, pinPaint);

    // Dynamic glowing outer neon border matching role
    final Color neonGlowColor = isPolice ? const Color(0xFF00D4FF) : const Color(0xFF00FF88);
    final Paint glowPaint = Paint()
      ..color = neonGlowColor.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
    canvas.drawPath(pinPath, glowPaint);

    final Paint borderPaint = Paint()
      ..color = isPolice ? const Color(0xFFE0F2FE) : const Color(0xFFD1FAE5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawPath(pinPath, borderPaint);

    // Draw Sleek, Dark Glass Circle backdrop inside pin head
    canvas.drawCircle(
      const Offset(40.0, 36.0),
      14.0,
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );
    canvas.drawCircle(
      const Offset(40.0, 36.0),
      14.0,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    // Draw Sleek, Professional Minimal Vector Emblem Graphics
    final Paint emblemPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (isPolice) {
      // Sleek tactical shield vector
      final Path shieldPath = Path();
      shieldPath.moveTo(40.0, 29.0);
      shieldPath.quadraticBezierTo(46.0, 29.0, 46.0, 34.0);
      shieldPath.quadraticBezierTo(46.0, 41.0, 40.0, 46.0);
      shieldPath.quadraticBezierTo(34.0, 41.0, 34.0, 34.0);
      shieldPath.quadraticBezierTo(34.0, 29.0, 40.0, 29.0);
      shieldPath.close();
      canvas.drawPath(shieldPath, emblemPaint);

      // Mini inner core star dot
      canvas.drawCircle(const Offset(40.0, 36.5), 1.5, Paint()..color = Colors.white);
    } else {
      // Sleek cyberpunk stealth chevron/hood vector
      final Path thiefPath = Path();
      thiefPath.moveTo(34.0, 33.0);
      thiefPath.lineTo(40.0, 27.0);
      thiefPath.lineTo(46.0, 33.0);
      thiefPath.lineTo(46.0, 39.0);
      thiefPath.lineTo(40.0, 45.0);
      thiefPath.lineTo(34.0, 39.0);
      thiefPath.close();
      canvas.drawPath(thiefPath, emblemPaint);

      // Sleek diagonal cyber visor line
      final Paint visorPaint = Paint()
        ..color = const Color(0xFF00FF88)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawLine(const Offset(36.0, 35.0), const Offset(44.0, 35.0), visorPaint);
    }

    final ui.Image image = await pictureRecorder.endRecording().toImage(width.toInt(), height.toInt());
    final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    
    if (byteData == null) {
      return BitmapDescriptor.defaultMarker;
    }
    return BitmapDescriptor.bytes(byteData.buffer.asUint8List());
  }

  Widget _buildTopBar() {
    final isGpsActive = _locationStatus.contains('Active');
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 12,
      right: 12,
      child: _GlassCard(
        child: Row(
          children: [
            _RoleIcon(isPolice: widget.isPolice),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.isPolice ? 'POLICE MODE' : 'THIEF MODE',
                    style: GoogleFonts.bangers(
                      fontSize: 15,
                      color: Colors.white,
                      letterSpacing: 1,
                    ),
                  ),
                  Row(
                    children: [
                      Icon(
                        isGpsActive ? Icons.gps_fixed : Icons.gps_off,
                        size: 11,
                        color: isGpsActive
                            ? Colors.greenAccent
                            : Colors.red,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          _locationStatus,
                          style: GoogleFonts.poppins(
                            fontSize: 10,
                            color: Colors.white60,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Only the timer text rebuilds every second – not the whole top bar.
            ValueListenableBuilder<int>(
              valueListenable: _elapsedSeconds,
              builder: (_, seconds, __) {
                final remaining = max(0, _roomDurationSeconds - seconds);
                return _TimerDisplay(time: _formatTime(remaining));
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCatchCounter() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 86,
      right: 12,
      child: AnimatedBuilder(
        animation: _catchScaleAnim,
        builder: (context, child) =>
            Transform.scale(scale: _catchScaleAnim.value, child: child),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [AppTheme.warning, AppTheme.danger],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(40),
            boxShadow: [
              BoxShadow(
                color: AppTheme.warning.withValues(alpha: 0.5),
                blurRadius: 16,
                spreadRadius: 2,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedRotation(
                turns: _catchCount > 0 ? 0.1 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(
                  Icons.star_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$_catchCount',
                style: GoogleFonts.bangers(
                  fontSize: 22,
                  color: Colors.white,
                  shadows: const [
                    Shadow(
                      offset: Offset(1, 1),
                      blurRadius: 2,
                      color: Colors.black26,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Text(
                'CATCH',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecenterButton() {
    final bottomOffset = widget.isPolice ? 120.0 : 185.0;
    final active = _trackingMode != MapTrackingMode.none;
    return Positioned(
      bottom: bottomOffset,
      right: 12,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _recenterPressed = true),
        onTapUp: (_) => setState(() => _recenterPressed = false),
        onTapCancel: () => setState(() => _recenterPressed = false),
        onTap: () {
          // Reset the programmatic-move flag before we animate so any
          // in-flight camera update doesn't get mis-classified as a user drag.
          _isProgrammaticMove = false;
          setState(() {
            if (_trackingMode == MapTrackingMode.none) {
              _trackingMode = MapTrackingMode.follow;
            } else if (_trackingMode == MapTrackingMode.follow) {
              _trackingMode = MapTrackingMode.navigation;
            } else {
              _trackingMode = MapTrackingMode.follow;
            }
          });
          _updateMarkersList();
          _animateToCurrentLocation();
        },
        child: AnimatedScale(
          scale: _recenterPressed ? 0.90 : 1.0,
          duration: const Duration(milliseconds: 100),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: active ? AppTheme.accent : Colors.black87,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: (active ? AppTheme.accent : Colors.black)
                      .withValues(alpha: active ? 0.5 : 0.3),
                  blurRadius: active ? 14 : 8,
                  spreadRadius: active ? 2 : 0,
                  offset: const Offset(0, 4),
                ),
              ],
              border: Border.all(
                color: active
                    ? AppTheme.accentSoft.withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.1),
                width: 1.5,
              ),
            ),
            child: Icon(
              _trackingMode == MapTrackingMode.none
                  ? Icons.location_searching
                  : _trackingMode == MapTrackingMode.follow
                      ? Icons.my_location
                      : Icons.explore,
              color: Colors.white,
              size: 24,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomPanel() {
    return Positioned(
      bottom: 16,
      left: 12,
      right: 12,
      child: _GlassCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  widget.isPolice
                      ? Icons.gps_fixed
                      : Icons.directions_run,
                  color: Colors.amber.shade400,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.isPolice
                      ? 'GET WITHIN 20 M TO CATCH'
                      : 'STAY AWAY FROM POLICE!',
                  style: GoogleFonts.bangers(
                    fontSize: 13,
                    color: Colors.amber.shade400,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // ValueListenableBuilder keeps player count in sync with
                // the notifier without needing an extra setState.
                ValueListenableBuilder<List<Marker>>(
                  valueListenable: _markersNotifier,
                  builder: (_, markers, __) => _StatChip(
                    icon: Icons.people,
                    value: '${markers.length}',
                    label: 'PLAYERS',
                  ),
                ),
                _StatChip(
                  icon: Icons.my_location,
                  value: _currentLocation.latitude.toStringAsFixed(4),
                  label: 'LAT',
                ),
                _StatChip(
                  icon: Icons.location_on,
                  value: _currentLocation.longitude.toStringAsFixed(4),
                  label: 'LNG',
                ),
              ],
            ),
            if (!widget.isPolice) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _HintStatusChip(
                    remainingHints: _remainingHints,
                    active: _policeRevealActive,
                  ),
                  ElevatedButton.icon(
                    onPressed:
                        _remainingHints > 0 && !_policeRevealActive
                            ? _useHint
                            : null,
                    icon: const Icon(Icons.visibility),
                    label: Text(_policeRevealActive
                        ? 'REVEALING...'
                        : 'USE HINT ($_remainingHints)'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amber.shade700,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Reusable Widgets ─────────────────────────────────────────────────────────

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xDD000000), Color(0x99000000)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _RoleIcon extends StatelessWidget {
  const _RoleIcon({required this.isPolice});
  final bool isPolice;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        isPolice ? Icons.local_police : Icons.person,
        color: Colors.white,
        size: 22,
      ),
    );
  }
}

class _HintStatusChip extends StatelessWidget {
  const _HintStatusChip({
    required this.remainingHints,
    required this.active,
  });

  final int remainingHints;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.lightbulb,
            color: active ? Colors.yellow.shade300 : Colors.white70,
            size: 18,
          ),
          const SizedBox(width: 8),
          Text(
            active ? 'REVEAL ACTIVE' : 'HINTS: $remainingHints',
            style: GoogleFonts.poppins(
              fontSize: 12,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _TimerDisplay extends StatelessWidget {
  const _TimerDisplay({required this.time});
  final String time;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            time,
            style: GoogleFonts.spaceMono(
              fontSize: 18,
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            'TIME REMAINING',
            style: GoogleFonts.poppins(fontSize: 8, color: Colors.white60),
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.icon,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.white60),
          const SizedBox(width: 4),
          Text(
            value,
            style: GoogleFonts.poppins(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 3),
          Text(
            label,
            style: GoogleFonts.poppins(fontSize: 8, color: Colors.white60),
          ),
        ],
      ),
    );
  }
}

// ─── Floating notification overlay ───────────────────────────────────────────

class _FloatingNotification extends StatefulWidget {
  const _FloatingNotification({
    required this.title,
    required this.message,
    required this.icon,
    required this.color,
    required this.onDismiss,
  });

  final String title;
  final String message;
  final IconData icon;
  final Color color;
  final VoidCallback onDismiss;

  @override
  State<_FloatingNotification> createState() => _FloatingNotificationState();
}

class _FloatingNotificationState extends State<_FloatingNotification>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scaleAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.0, 0.7, curve: Curves.elasticOut)),
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.0, 0.4, curve: Curves.easeIn)),
    );
    _slideAnim = Tween<Offset>(begin: const Offset(0.0, -0.6), end: Offset.zero).animate(
      CurvedAnimation(parent: _controller, curve: Curves.elasticOut),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).size.height * 0.14,
      left: 16,
      right: 16,
      child: Material(
        color: Colors.transparent,
        child: SlideTransition(
          position: _slideAnim,
          child: ScaleTransition(
            scale: _scaleAnim,
            child: FadeTransition(
              opacity: _fadeAnim,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          widget.color.withValues(alpha: 0.15),
                          widget.color.withValues(alpha: 0.05),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: widget.color.withValues(alpha: 0.45),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: widget.color.withValues(alpha: 0.25),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                widget.color,
                                widget.color.withValues(alpha: 0.8),
                              ],
                            ),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: widget.color.withValues(alpha: 0.5),
                                blurRadius: 10,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: Icon(widget.icon, color: Colors.white, size: 26),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.title,
                                style: GoogleFonts.bangers(
                                  fontSize: 18,
                                  color: Colors.white,
                                  letterSpacing: 0.8,
                                  shadows: [
                                    Shadow(
                                      offset: const Offset(1, 1),
                                      blurRadius: 4,
                                      color: Colors.black.withValues(alpha: 0.6),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                widget.message,
                                style: GoogleFonts.poppins(
                                  fontSize: 12,
                                  color: Colors.white.withValues(alpha: 0.85),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Tactical Center Reticle and Minimal Pulse Pin ───────────────────────────

class TacticalPlayerPin extends StatefulWidget {
  final bool isPolice;
  final double bearing;
  final bool isNavigationMode;

  const TacticalPlayerPin({
    super.key,
    required this.isPolice,
    required this.bearing,
    required this.isNavigationMode,
  });

  @override
  State<TacticalPlayerPin> createState() => _TacticalPlayerPinState();
}

class _TacticalPlayerPinState extends State<TacticalPlayerPin>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final AnimationController _rotateController;
  late final AnimationController _breathController;

  @override
  void initState() {
    super.initState();
    
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
    
    _rotateController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 8000),
    )..repeat();
    
    _breathController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _rotateController.dispose();
    _breathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Designer theme colors
    final Color themeColor = widget.isPolice ? const Color(0xFF00E5FF) : const Color(0xFF39FF14);
    final Color coreBorderColor = widget.isPolice ? const Color(0xFFE0F2FE) : const Color(0xFFD1FAE5);
    final Color darkBackdrop = widget.isPolice ? const Color(0xFF0F172A) : const Color(0xFF0D0D0D);

    // Target angle in radians
    final double targetAngle = widget.isNavigationMode ? 0.0 : (widget.bearing * pi / 180.0);

    return SizedBox(
      width: 110,
      height: 110,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // ── Concentric Pulse Rings (Concentric wave) ──────────────────────
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, _) {
              final double p1 = _pulseController.value;
              final double p2 = (p1 + 0.5) % 1.0;

              final double scale1 = 0.8 + 1.6 * p1;
              final double scale2 = 0.8 + 1.6 * p2;

              final double opacity1 = 0.65 * (1.0 - p1);
              final double opacity2 = 0.65 * (1.0 - p2);

              return Stack(
                alignment: Alignment.center,
                children: [
                  Transform.scale(
                    scale: scale1,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: themeColor.withValues(alpha: opacity1),
                          width: 1.2,
                        ),
                      ),
                    ),
                  ),
                  Transform.scale(
                    scale: scale2,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: themeColor.withValues(alpha: opacity2),
                          width: 1.2,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),

          // ── Rotating Outer Tactical Reticle ──────────────────────────────
          RotationTransition(
            turns: _rotateController,
            child: CustomPaint(
              size: const Size(80, 80),
              painter: _TacticalReticlePainter(color: themeColor),
            ),
          ),

          // ── Compass Dynamic Direction Pointer (Tween for 100% smoothness) ──
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.0, end: targetAngle),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            builder: (context, angle, _) {
              return Transform.rotate(
                angle: angle,
                child: CustomPaint(
                  size: const Size(96, 96),
                  painter: _TacticalCompassPointerPainter(color: themeColor),
                ),
              );
            },
          ),

          // ── Breathing Central Core ───────────────────────────────────────
          AnimatedBuilder(
            animation: _breathController,
            builder: (context, child) {
              final double breathScale = 0.94 + 0.08 * sin(_breathController.value * 2 * pi);
              
              return Transform.scale(
                scale: breathScale,
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: darkBackdrop,
                    boxShadow: [
                      BoxShadow(
                        color: themeColor.withValues(alpha: 0.45),
                        blurRadius: 10,
                        spreadRadius: 2,
                      ),
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 4,
                        offset: const Offset(0, 3),
                      ),
                    ],
                    border: Border.all(
                      color: coreBorderColor,
                      width: 2.0,
                    ),
                  ),
                  child: CustomPaint(
                    size: const Size(34, 34),
                    painter: _TacticalCorePainter(isPolice: widget.isPolice, themeColor: themeColor),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _TacticalReticlePainter extends CustomPainter {
  final Color color;

  _TacticalReticlePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final double radius = size.width / 2;
    final Offset center = Offset(radius, radius);

    // Draw dashed circular reticle ring
    final Paint dashPaint = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    const int totalDashes = 36;
    for (int i = 0; i < totalDashes; i++) {
      if (i % 2 == 0) continue;
      final double angle1 = (i * 2 * pi) / totalDashes;
      final double angle2 = ((i + 1) * 2 * pi) / totalDashes;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - 3),
        angle1,
        angle2 - angle1,
        false,
        dashPaint,
      );
    }

    // Draw 4 precision crosshair ticks on the ring
    final Paint tickPaint = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Top, Right, Bottom, Left ticks
    const double tickLength = 5.0;
    canvas.drawLine(Offset(radius, 0), Offset(radius, tickLength), tickPaint);
    canvas.drawLine(Offset(radius, size.height), Offset(radius, size.height - tickLength), tickPaint);
    canvas.drawLine(Offset(0, radius), Offset(tickLength, radius), tickPaint);
    canvas.drawLine(Offset(size.width, radius), Offset(size.width - tickLength, radius), tickPaint);
  }

  @override
  bool shouldRepaint(covariant _TacticalReticlePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _TacticalCompassPointerPainter extends CustomPainter {
  final Color color;

  _TacticalCompassPointerPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final double radius = size.width / 2;

    // Draw small glowing directional pointer at the top
    final Paint pointerPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // Small sharp chevron pointing straight UP at the top boundary
    final Path path = Path();
    path.moveTo(radius, 0.0); // tip
    path.lineTo(radius - 5.0, 7.0); // left shoulder
    path.lineTo(radius, 5.0); // inner center
    path.lineTo(radius + 5.0, 7.0); // right shoulder
    path.close();

    // Draw shadow/glow under the chevron
    final Paint glowPaint = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0);
    canvas.drawPath(path.shift(const Offset(0.0, 1.0)), glowPaint);
    canvas.drawPath(path, pointerPaint);
  }

  @override
  bool shouldRepaint(covariant _TacticalCompassPointerPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _TacticalCorePainter extends CustomPainter {
  final bool isPolice;
  final Color themeColor;

  _TacticalCorePainter({required this.isPolice, required this.themeColor});

  @override
  void paint(Canvas canvas, Size size) {
    final double radius = size.width / 2;

    // Draw central premium role-based emblem
    final Paint emblemPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    if (isPolice) {
      // Sleek tactical shield
      final Path shieldPath = Path();
      shieldPath.moveTo(radius, radius - 7);
      shieldPath.quadraticBezierTo(radius + 5.5, radius - 7, radius + 5.5, radius - 2);
      shieldPath.quadraticBezierTo(radius + 5.5, radius + 4, radius, radius + 9);
      shieldPath.quadraticBezierTo(radius - 5.5, radius + 4, radius - 5.5, radius - 2);
      shieldPath.quadraticBezierTo(radius - 5.5, radius - 7, radius, radius - 7);
      shieldPath.close();
      canvas.drawPath(shieldPath, emblemPaint);

      // Star core dot
      canvas.drawCircle(Offset(radius, radius + 0.5), 1.5, Paint()..color = Colors.white);
    } else {
      // Sleek ninja/cyber mask
      final Path thiefPath = Path();
      thiefPath.moveTo(radius - 6.5, radius - 3);
      thiefPath.lineTo(radius, radius - 9);
      thiefPath.lineTo(radius + 6.5, radius - 3);
      thiefPath.lineTo(radius + 6.5, radius + 3);
      thiefPath.lineTo(radius, radius + 9);
      thiefPath.lineTo(radius - 6.5, radius + 3);
      thiefPath.close();
      canvas.drawPath(thiefPath, emblemPaint);

      // Cyber visor line
      final Paint visorPaint = Paint()
        ..color = themeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(radius - 4.5, radius - 1), Offset(radius + 4.5, radius - 1), visorPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _TacticalCorePainter oldDelegate) {
    return oldDelegate.isPolice != isPolice || oldDelegate.themeColor != themeColor;
  }
}
