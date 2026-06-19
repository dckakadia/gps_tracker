import 'dart:async';
import 'dart:convert';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/location_point.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import 'package:http/http.dart' as http;

class MapScreen extends StatefulWidget {
  final String token;
  const MapScreen({required this.token});

  @override
  _MapScreenState createState() => _MapScreenState();
}

enum _Filter { all, live, stale }

class _MapScreenState extends State<MapScreen> {
  List<LocationPoint> locations = [];
  late Timer _countdownTimer;
  late MapController _mapController;
  IO.Socket? _socket;
  bool isLoading = true;
  String? errorMessage;
  _Filter _filter = _Filter.all;
  int _secondsUntilRefresh = 12;
  LocationPoint? _selectedLocation;
  List<LocationPoint>? _locationHistory;
  bool _showingHistory = false;
  bool _isPaused = false;
  Map<int, double> _userDistances = {};
  List<Map<String, dynamic>> _geofences = [];
  // True after the first successful fetch — suppresses the full-screen loading
  // spinner on subsequent 12-second polls so FlutterMap is never removed from
  // the widget tree. Removing it causes FlutterMapState to reinitialize from
  // MapOptions.zoom = 5, which is the root cause of the camera-reset bug.
  bool _initialLoadDone = false;

  // --- Follow-mode camera state ---
  // True when the admin has tapped a specific user and is in the live single-user view.
  bool _isFollowingSingleUser = false;
  // True means the camera auto-pans to keep the followed user in view.
  // Becomes false the moment the admin manually drags/zooms the map.
  bool _isFollowModeActive = false;
  // Tracks the last time the admin manually moved the map (drag, pinch, scroll).
  DateTime? _lastManualMapInteraction;

  final DraggableScrollableController _sheetController = DraggableScrollableController();

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _fetchLocations();
    _initSocket();
    _loadInitialStatuses();
    _fetchGeofences();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (!_isPaused) {
          _secondsUntilRefresh--;
          if (_secondsUntilRefresh <= 0) {
            _secondsUntilRefresh = 12;
            _fetchLocations();
          }
        }
      });
    });
  }

  @override
  void dispose() {
    _socket?.disconnect();
    _socket?.destroy();
    _countdownTimer.cancel();
    _mapController.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  Future<void> _fetchLocations() async {
    // Only show the full-screen loading spinner on the very first fetch.
    // Subsequent polls must NOT set isLoading = true: doing so returns a plain
    // CircularProgressIndicator from build(), which removes FlutterMap from the
    // widget tree. When FlutterMap is re-inserted its FlutterMapState is recreated
    // and re-reads MapOptions.zoom = 5, resetting the camera regardless of follow mode.
    setState(() {
      if (!_initialLoadDone) isLoading = true;
      errorMessage = null;
      _secondsUntilRefresh = 12;
    });
    try {
      final result = await ApiService.getLatestLocations(widget.token, includeStale: true);
      setState(() { locations = result; isLoading = false; _initialLoadDone = true; });
      _fetchAllDistances();
      // Overview mode: only auto-zoom if the admin hasn't manually panned within the last 45 s.
      // Single-user follow mode: camera is driven by the socket handler, not the poll.
      if (!_isFollowingSingleUser) {
        final sinceInteraction = _lastManualMapInteraction == null
            ? null
            : DateTime.now().difference(_lastManualMapInteraction!);
        if (sinceInteraction == null || sinceInteraction.inSeconds > 45) {
          WidgetsBinding.instance.addPostFrameCallback(
              (_) => _autoZoomToMarkers(_filteredLocations));
        }
      }
    } catch (err) {
      setState(() { locations = []; isLoading = false; errorMessage = err.toString(); });
    }
  }

  void _initSocket() {
    try {
      final uri = Uri.parse(ApiService.baseUrl.replaceFirst('/api', ''));
      final url = '${uri.scheme}://${uri.host}:${uri.port}';
      _socket = IO.io(url, IO.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': widget.token})
          .build());

      _socket?.on('location:uploaded', (data) {
        try {
          final updated = LocationPoint.fromJson(Map<String, dynamic>.from(data));
          // Capture follow state before setState to use it consistently below.
          final shouldFollow = _isFollowingSingleUser &&
              _isFollowModeActive &&
              _selectedLocation?.userId == updated.userId;
          setState(() {
            final idx = locations.indexWhere((l) => l.userId == updated.userId);
            if (idx >= 0) locations[idx] = updated; else locations.add(updated);
            if (shouldFollow) _selectedLocation = updated;
          });
          _fetchDistanceForUser(updated.userId);
          if (shouldFollow) {
            // flutter_map v5 has no AnimatedMapController; using plain .move().
            // Keeps the admin's current zoom — never recomputes from a bounding box.
            _mapController.move(
              LatLng(updated.latitude, updated.longitude),
              _mapController.zoom,
            );
          }
        } catch (_) {}
      });

      _socket?.on('geofence:alert', (data) {
        try {
          final d = Map<String, dynamic>.from(data);
          final event = d['event'] as String? ?? '';
          final geofenceId = d['geofence_id'];
          final userId = d['user_id'];
          final gf = _geofences.firstWhere((g) => g['id'] == geofenceId, orElse: () => {'name': 'Geofence'});
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('⚡ User ${event == 'entered' ? 'entered' : 'exited'} ${gf['name']}'),
                behavior: SnackBarBehavior.floating,
                backgroundColor: AppTheme.warning,
              ),
            );
          }
          // Persist the event for the Events history screen.
          if (userId != null && geofenceId != null) {
            final eventType = event == 'entered' ? 'enter' : 'exit';
            ApiService.postGeofenceEvent(widget.token, userId as int, geofenceId as int, eventType)
                .catchError((_) {});
          }
        } catch (_) {}
      });
    } catch (_) {}
  }

  Future<void> _fetchGeofences() async {
    try {
      final response = await http.get(
        Uri.parse('${ApiService.baseUrl}/geofences'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _geofences = (body['geofences'] as List).map((g) => g as Map<String, dynamic>).toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _fetchDistanceForUser(int userId) async {
    try {
      final today = DateTime.now().toIso8601String().split('T')[0];
      final response = await http.get(
        Uri.parse('${ApiService.baseUrl}/locations/stats/distance?user_id=$userId&date=$today'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() { _userDistances[userId] = (body['distance_km'] as num?)?.toDouble() ?? 0.0; });
      }
    } catch (_) {}
  }

  Future<void> _fetchAllDistances() async {
    for (final loc in locations) { await _fetchDistanceForUser(loc.userId); }
  }

  Future<void> _sendNotification(int userId, String userName) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radius)),
        title: Row(
          children: [
            const Icon(Icons.send, color: AppTheme.primaryLight),
            const SizedBox(width: 10),
            Text('Notify $userName', style: const TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              children: [
                for (final template in ['Running late?', 'Please check in', 'Heading to next stop?'])
                  ActionChip(
                    label: Text(template, style: const TextStyle(fontSize: 12)),
                    onPressed: () => controller.text = template,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              decoration: const InputDecoration(hintText: 'Enter message...', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton.icon(
            icon: const Icon(Icons.send, size: 16),
            label: const Text('Send'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirmed != true || controller.text.isEmpty) return;
    try {
      final response = await http.post(
        Uri.parse('${ApiService.baseUrl}/users/notify'),
        headers: {'Authorization': 'Bearer ${widget.token}', 'Content-Type': 'application/json'},
        body: jsonEncode({'user_id': userId, 'message': controller.text}),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(response.statusCode == 200 ? 'Notification sent to $userName' : 'Failed to send notification'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _loadInitialStatuses() async {
    try {
      final statuses = await ApiService.getUsersStatus(widget.token);
      setState(() {
        for (final s in statuses) {
          final uid = s['user_id'] as int?;
          if (uid == null) continue;
          final idx = locations.indexWhere((l) => l.userId == uid);
          if (idx >= 0) {
            final u = locations[idx];
            locations[idx] = LocationPoint(
              userId: u.userId, name: u.name, latitude: u.latitude,
              longitude: u.longitude, recordedAt: u.recordedAt, receivedAt: u.receivedAt,
              isLive: u.isLive, lastSeen: s['last_seen'] as String?, isOnline: s['is_online'] as bool?,
            );
          }
        }
      });
    } catch (_) {}
  }

  Future<void> _fetchLocationHistory(LocationPoint location) async {
    try {
      final history = await ApiService.getLocationHistory(widget.token, location.userId);
      setState(() {
        _selectedLocation = location;
        _locationHistory = history;
        _showingHistory = true;
        _isFollowingSingleUser = false; // history view, not live follow
        _isFollowModeActive = false;
      });
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to load location history')),
      );
    }
  }

  int _minutesSince(LocationPoint l) {
    try {
      return DateTime.now().difference(DateTime.parse(l.lastSeen ?? l.recordedAt)).inMinutes;
    } catch (_) { return 0; }
  }

  Color _pinColor(LocationPoint l) {
    final mins = _minutesSince(l);
    final online = l.isOnline ?? (mins < 30);
    if (online) return AppTheme.liveGreen;
    if (mins < 60) return AppTheme.staleOrange;
    return AppTheme.offlineGrey;
  }

  String _lastSeenText(LocationPoint l) {
    final m = _minutesSince(l);
    if (m < 1) return 'Just now';
    if (m < 60) return '$m min ago';
    final h = m ~/ 60;
    return '$h hr ago';
  }

  String _statusText(LocationPoint l) {
    final online = l.isOnline ?? (_minutesSince(l) < 30);
    if (online) return 'Active';
    try {
      final dt = DateTime.parse(l.lastSeen ?? l.recordedAt);
      return 'Last: ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) { return 'Offline'; }
  }

  List<LocationPoint> get _filteredLocations {
    switch (_filter) {
      case _Filter.live: return locations.where((l) => _minutesSince(l) < 15).toList();
      case _Filter.stale: return locations.where((l) => _minutesSince(l) >= 15).toList();
      default: return locations;
    }
  }

  void _flyToLocation(LocationPoint l) {
    _mapController.move(LatLng(l.latitude, l.longitude), 15.0);
    setState(() {
      _selectedLocation = l;
      _showingHistory = false;
      _locationHistory = null;
      _isFollowingSingleUser = true;
      _isFollowModeActive = true;
      _lastManualMapInteraction = null;
    });
  }

  void _autoZoomToMarkers(List<LocationPoint> pts) {
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      _mapController.move(LatLng(pts[0].latitude, pts[0].longitude), 13.0);
      return;
    }
    double minLat = pts[0].latitude, maxLat = pts[0].latitude;
    double minLng = pts[0].longitude, maxLng = pts[0].longitude;
    for (final l in pts) {
      if (l.latitude < minLat) minLat = l.latitude;
      if (l.latitude > maxLat) maxLat = l.latitude;
      if (l.longitude < minLng) minLng = l.longitude;
      if (l.longitude > maxLng) maxLng = l.longitude;
    }
    final delta = ((maxLat - minLat).abs() + (maxLng - minLng).abs()) / 2;
    double zoom = 5;
    if (delta < 0.01) zoom = 15;
    else if (delta < 0.1) zoom = 12;
    else if (delta < 1) zoom = 10;
    else if (delta < 5) zoom = 8;
    else if (delta < 20) zoom = 6;
    _mapController.move(LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2), zoom.clamp(2, 18));
  }

  String _formatTs(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final filteredLocations = _filteredLocations;
    final isMobile = MediaQuery.of(context).size.width < 900;

    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.signal_wifi_off, size: 48, color: AppTheme.textMedium),
              const SizedBox(height: 16),
              const Text('Unable to load locations', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(errorMessage!, style: const TextStyle(color: AppTheme.textMedium, fontSize: 13), textAlign: TextAlign.center),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
                onPressed: _fetchLocations,
              ),
            ],
          ),
        ),
      );
    }

    if (filteredLocations.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.location_off, size: 48, color: AppTheme.textMedium),
            const SizedBox(height: 16),
            Text(
              locations.isEmpty ? 'No Users Available' : 'No Users Match Filter',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              locations.isEmpty
                  ? 'No users have reported a location yet.'
                  : 'Try switching to "All".',
              style: const TextStyle(color: AppTheme.textMedium, fontSize: 13),
            ),
            if (locations.isNotEmpty) ...[
              const SizedBox(height: 16),
              TextButton(onPressed: () => setState(() => _filter = _Filter.all), child: const Text('Show All')),
            ],
          ],
        ),
      );
    }

    final mapWidget = _buildMap(filteredLocations);

    if (isMobile) {
      return Stack(
        children: [
          mapWidget,
          // Filter chips overlay (top)
          Positioned(
            top: 10, left: 12, right: 12,
            child: _buildFilterBar(compact: true),
          ),
          // Camera action button (follow/re-center) — above the bottom sheet handle
          Positioned(
            bottom: 180, right: 16,
            child: _buildCameraActionButton(),
          ),
          // Mobile bottom sheet for user list
          DraggableScrollableSheet(
            controller: _sheetController,
            initialChildSize: 0.18,
            minChildSize: 0.1,
            maxChildSize: 0.6,
            snap: true,
            snapSizes: const [0.1, 0.18, 0.6],
            builder: (ctx, scrollController) => Container(
              decoration: const BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 12, offset: Offset(0, -2))],
              ),
              child: Column(
                children: [
                  // Handle
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    width: 36, height: 4,
                    decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        const Icon(Icons.people, size: 16, color: AppTheme.primaryLight),
                        const SizedBox(width: 8),
                        Text('${locations.length} Salespeople',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textDark)),
                        const Spacer(),
                        _refreshBadge(),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: ListView.separated(
                      controller: scrollController,
                      itemCount: locations.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
                      itemBuilder: (_, i) => _buildUserTile(locations[i]),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    // Desktop / wide layout
    return Row(
      children: [
        // Sidebar
        Container(
          width: 280,
          color: AppTheme.surface,
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
                child: Row(
                  children: [
                    const Icon(Icons.people, size: 16, color: AppTheme.primaryLight),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${locations.length} Salespeople',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textDark)),
                    ),
                    _refreshBadge(),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: locations.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
                  itemBuilder: (_, i) => _buildUserTile(locations[i]),
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        // Map area
        Expanded(
          child: Stack(
            children: [
              mapWidget,
              Positioned(
                top: 10, left: 12, right: 12,
                child: Row(
                  children: [
                    _buildFilterBar(compact: false),
                    const Spacer(),
                    _pauseButton(),
                  ],
                ),
              ),
              Positioned(
                bottom: 16, right: 16,
                child: _buildCameraActionButton(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMap(List<LocationPoint> filteredLocations) {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        center: filteredLocations.isNotEmpty
            ? LatLng(filteredLocations.first.latitude, filteredLocations.first.longitude)
            : const LatLng(20, 0),
        zoom: 5,
        // Detect manual map interaction to pause auto-camera.
        // flutter_map v5.0.0 API note:
        //   MapEventMove covers onDrag (drag pan) and onMultiFinger (pinch pan/zoom).
        //   MapEventScrollWheelZoom is a separate class for trackpad/scroll-wheel zoom.
        //   MapEventDoubleTapZoomStart fires once when a double-tap zoom begins.
        //   MapEventFlingAnimationStart fires once when a fling gesture begins.
        //   MapEventSource.multiFingerEnd produces MapEventMoveEnd, not MapEventMove.
        onMapEvent: (MapEvent event) {
          final bool isUserGesture;
          if (event is MapEventMove) {
            isUserGesture = event.source == MapEventSource.onDrag ||
                event.source == MapEventSource.onMultiFinger;
          } else if (event is MapEventScrollWheelZoom ||
              event is MapEventDoubleTapZoomStart ||
              event is MapEventFlingAnimationStart) {
            isUserGesture = true;
          } else {
            isUserGesture = false;
          }
          if (isUserGesture) {
            // Mutate directly — no setState needed; the 1-s countdown timer will
            // trigger the next rebuild to show/hide the camera action buttons.
            _lastManualMapInteraction = DateTime.now();
            if (_isFollowingSingleUser) _isFollowModeActive = false;
          }
        },
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.gps_tracker',
        ),
        // Geofence circles
        CircleLayer(
          circles: _geofences.map((gf) => CircleMarker(
            point: LatLng((gf['latitude'] as num).toDouble(), (gf['longitude'] as num).toDouble()),
            radius: (gf['radius_meters'] as num).toDouble(),
            useRadiusInMeter: true,
            color: AppTheme.primaryLight.withOpacity(0.1),
            borderColor: AppTheme.primaryLight.withOpacity(0.5),
            borderStrokeWidth: 1.5,
          )).toList(),
        ),
        // History polyline
        if (_showingHistory && _locationHistory != null)
          PolylineLayer(polylines: [
            Polyline(
              points: _locationHistory!.map((l) => LatLng(l.latitude, l.longitude)).toList(),
              color: AppTheme.primaryLight.withOpacity(0.75),
              strokeWidth: 3,
            ),
          ]),
        // Markers
        MarkerLayer(
          markers: [
            ...filteredLocations.map((loc) {
              final color = _pinColor(loc);
              final isSelected = _selectedLocation?.userId == loc.userId;
              final distKm = _userDistances[loc.userId];
              final battery = loc.batteryLevel;
              final battColor = battery == null ? Colors.grey : battery < 20 ? Colors.red : battery < 50 ? Colors.orange : Colors.green;
              final battIcon = battery == null ? Icons.battery_unknown
                  : battery > 80 ? Icons.battery_full
                  : battery > 50 ? Icons.battery_5_bar
                  : battery > 20 ? Icons.battery_3_bar
                  : Icons.battery_alert;

              return Marker(
                width: 170, height: 130,
                point: LatLng(loc.latitude, loc.longitude),
                builder: (_) => GestureDetector(
                  onTap: () => _flyToLocation(loc),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.location_pin, color: color, size: 36),
                      Container(
                        width: 155,
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                        decoration: BoxDecoration(
                          color: isSelected ? AppTheme.primary.withOpacity(0.95) : Colors.white.withOpacity(0.96),
                          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                          border: Border.all(color: isSelected ? AppTheme.primary : color.withOpacity(0.6), width: isSelected ? 2 : 1),
                          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 4)],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Expanded(
                                child: Text(loc.name, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
                                    color: isSelected ? Colors.white : AppTheme.textDark), overflow: TextOverflow.ellipsis),
                              ),
                              GestureDetector(
                                onTap: () => _sendNotification(loc.userId, loc.name),
                                child: Icon(Icons.message, size: 13, color: isSelected ? Colors.white70 : AppTheme.primaryLight),
                              ),
                            ]),
                            const SizedBox(height: 3),
                            // Battery row — always shown
                            Row(children: [
                              Icon(battIcon, size: 12, color: isSelected ? Colors.white70 : battColor),
                              const SizedBox(width: 3),
                              Text(
                                battery != null ? '$battery%' : 'No data',
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                                    color: isSelected ? Colors.white70 : battColor),
                              ),
                              const SizedBox(width: 6),
                              Text(_statusText(loc),
                                  style: TextStyle(fontSize: 10, color: isSelected ? Colors.white60 : AppTheme.textMedium)),
                            ]),
                            if (distKm != null)
                              Text('${distKm.toStringAsFixed(1)} km today',
                                  style: TextStyle(fontSize: 10, color: isSelected ? Colors.white70 : AppTheme.textMedium)),
                            if (isSelected) ...[
                              const SizedBox(height: 4),
                              GestureDetector(
                                onTap: () => _fetchLocationHistory(loc),
                                child: const Text('View route →',
                                    style: TextStyle(fontSize: 9, color: Colors.white, decoration: TextDecoration.underline)),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
            // History dots
            if (_showingHistory && _locationHistory != null)
              ..._locationHistory!.map((hp) => Marker(
                width: 20, height: 20,
                point: LatLng(hp.latitude, hp.longitude),
                builder: (_) => Tooltip(
                  message: _formatTs(DateTime.parse(hp.recordedAt).toLocal()),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppTheme.primaryLight,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const SizedBox.shrink(),
                  ),
                ),
              )),
          ],
        ),
      ],
    );
  }

  Widget _buildFilterBar({required bool compact}) {
    final labels = ['All', 'Live', 'Stale'];
    final values = _Filter.values;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.95),
        borderRadius: BorderRadius.circular(24),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(values.length, (i) {
          final selected = _filter == values[i];
          final dotColor = i == 1 ? AppTheme.liveGreen : i == 2 ? AppTheme.staleOrange : AppTheme.primaryLight;
          return InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () {
              setState(() => _filter = values[i]);
              WidgetsBinding.instance.addPostFrameCallback((_) => _autoZoomToMarkers(_filteredLocations));
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: selected ? dotColor.withOpacity(0.12) : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: selected ? dotColor : Colors.transparent),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 8, height: 8,
                      decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Text(labels[i],
                      style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
                          color: selected ? dotColor : AppTheme.textMedium)),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _pauseButton() {
    final isPaused = _isPaused;
    return Material(
      color: Colors.white.withOpacity(0.95),
      borderRadius: BorderRadius.circular(20),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          setState(() {
            if (isPaused) { _isPaused = false; _secondsUntilRefresh = 12; _fetchLocations(); }
            else { _isPaused = true; }
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: isPaused ? AppTheme.error.withOpacity(0.5) : AppTheme.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                size: 16,
                color: isPaused ? AppTheme.success : AppTheme.primaryLight,
              ),
              const SizedBox(width: 6),
              Text(
                isPaused ? 'Resume auto-refresh' : 'Refresh in ${_secondsUntilRefresh}s',
                style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600,
                  color: isPaused ? AppTheme.error : AppTheme.textDark,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Floating action button shown over the map when the camera is out of sync
  /// with the data. Shows "Resume following" in single-user mode when the admin
  /// has panned away, or "Re-center" in overview mode after a manual pan.
  Widget _buildCameraActionButton() {
    if (_isFollowingSingleUser && !_isFollowModeActive) {
      // Single-user follow mode: admin panned away — offer to resume.
      return Material(
        color: AppTheme.primary,
        borderRadius: BorderRadius.circular(20),
        elevation: 3,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            final current = locations.firstWhere(
              (l) => l.userId == _selectedLocation!.userId,
              orElse: () => _selectedLocation!,
            );
            setState(() {
              _isFollowModeActive = true;
              _lastManualMapInteraction = null;
              _selectedLocation = current;
            });
            // flutter_map v5: plain .move(), keeps current zoom.
            _mapController.move(
              LatLng(current.latitude, current.longitude),
              _mapController.zoom,
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.gps_fixed, size: 15, color: Colors.white),
                SizedBox(width: 6),
                Text('Resume following',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
              ],
            ),
          ),
        ),
      );
    }

    if (!_isFollowingSingleUser) {
      final sinceInteraction = _lastManualMapInteraction == null
          ? null
          : DateTime.now().difference(_lastManualMapInteraction!);
      if (sinceInteraction != null && sinceInteraction.inSeconds <= 45) {
        // Overview mode: admin panned away — offer to re-center on all users.
        return Material(
          color: Colors.white.withOpacity(0.95),
          borderRadius: BorderRadius.circular(20),
          elevation: 2,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () {
              setState(() => _lastManualMapInteraction = null);
              _autoZoomToMarkers(_filteredLocations);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppTheme.border),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.center_focus_strong, size: 15, color: AppTheme.primaryLight),
                  SizedBox(width: 6),
                  Text('Re-center',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
                ],
              ),
            ),
          ),
        );
      }
    }

    return const SizedBox.shrink();
  }

  Widget _refreshBadge() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        setState(() {
          if (_isPaused) { _isPaused = false; _secondsUntilRefresh = 12; _fetchLocations(); }
          else _fetchLocations();
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: _isPaused ? AppTheme.errorLight : AppTheme.successLight,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_isPaused ? Icons.pause_circle_outline : Icons.refresh,
                size: 12, color: _isPaused ? AppTheme.error : AppTheme.success),
            const SizedBox(width: 4),
            Text(
              _isPaused ? 'Paused' : '${_secondsUntilRefresh}s',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                  color: _isPaused ? AppTheme.error : AppTheme.success),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUserTile(LocationPoint loc) {
    final color = _pinColor(loc);
    final isSelected = _selectedLocation?.userId == loc.userId;
    final distKm = _userDistances[loc.userId];
    final battery = loc.batteryLevel;
    final battColor = battery == null ? AppTheme.textLight
        : battery < 20 ? AppTheme.error
        : battery < 50 ? AppTheme.staleOrange
        : AppTheme.success;
    final battIcon = battery == null ? Icons.battery_unknown
        : battery > 80 ? Icons.battery_full
        : battery > 50 ? Icons.battery_5_bar
        : battery > 20 ? Icons.battery_3_bar
        : Icons.battery_alert;

    return Material(
      color: isSelected ? AppTheme.primary.withOpacity(0.06) : Colors.transparent,
      child: InkWell(
        onTap: () => _flyToLocation(loc),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              // Status dot
              Container(
                width: 10, height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: color.withOpacity(0.4), blurRadius: 4)]),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(loc.name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                        color: isSelected ? AppTheme.primary : AppTheme.textDark), overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Row(children: [
                      Icon(battIcon, size: 13, color: battColor),
                      const SizedBox(width: 3),
                      Text(
                        battery != null ? '$battery%' : '--',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: battColor),
                      ),
                      const Text('  ·  ', style: TextStyle(color: AppTheme.textLight)),
                      Text(_lastSeenText(loc), style: const TextStyle(fontSize: 11, color: AppTheme.textMedium)),
                      if (distKm != null) ...[
                        const Text(' · ', style: TextStyle(color: AppTheme.textLight)),
                        Text('${distKm.toStringAsFixed(1)} km', style: const TextStyle(fontSize: 11, color: AppTheme.textMedium)),
                      ],
                    ]),
                  ],
                ),
              ),
              // Action buttons
              Row(mainAxisSize: MainAxisSize.min, children: [
                Tooltip(
                  message: 'Send notification',
                  child: IconButton(
                    icon: const Icon(Icons.message_outlined, size: 16),
                    color: AppTheme.primaryLight,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    onPressed: () => _sendNotification(loc.userId, loc.name),
                  ),
                ),
                if (isSelected)
                  Tooltip(
                    message: 'View route',
                    child: IconButton(
                      icon: const Icon(Icons.route, size: 16),
                      color: AppTheme.primaryLight,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      onPressed: () => _fetchLocationHistory(loc),
                    ),
                  ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
