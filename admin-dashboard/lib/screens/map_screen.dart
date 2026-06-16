import 'dart:async';
import 'dart:convert';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/location_point.dart';
import '../services/api_service.dart';
import 'package:http/http.dart' as http;

class MapScreen extends StatefulWidget {
  final String token;
  MapScreen({required this.token});

  @override
  _MapScreenState createState() => _MapScreenState();
}

enum LocationFilterMode { all, liveOnly, staleOnly }

class _MapScreenState extends State<MapScreen> {
  List<LocationPoint> locations = [];
  late Timer _countdownTimer;
  late MapController _mapController;
  IO.Socket? _socket;
  bool isLoading = true;
  String? errorMessage;
  LocationFilterMode _filterMode = LocationFilterMode.all;
  DateTime? _lastUpdated;
  int _secondsUntilRefresh = 12;
  LocationPoint? _selectedLocation;
  List<LocationPoint>? _locationHistory;
  bool _showingHistory = false;
  bool _isPaused = false;
  Map<int, double> _userDistances = {};
  List<Map<String, dynamic>> _geofences = [];

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _fetchLocations();
    _initSocket();
    _loadInitialStatuses();
    _fetchGeofences();
    _countdownTimer = Timer.periodic(Duration(seconds: 1), (_) {
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
    super.dispose();
  }

  Future<void> _fetchLocations() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
      _secondsUntilRefresh = 12;
    });

    try {
      debugPrint('MapScreen._fetchLocations: requesting latest locations');
      final result = await ApiService.getLatestLocations(widget.token, includeStale: true);
      debugPrint('MapScreen._fetchLocations: received ${result.length} location(s)');
      setState(() {
        locations = result;
        isLoading = false;
        _lastUpdated = DateTime.now();
      });
      _fetchAllDistances();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _autoZoomToMarkers(_filteredLocations);
      });
    } catch (err, stackTrace) {
      debugPrint('MapScreen._fetchLocations failed: $err');
      debugPrint('$stackTrace');
      setState(() {
        locations = [];
        isLoading = false;
        errorMessage = err.toString();
      });
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

      _socket?.on('connect', (_) {
        debugPrint('Socket connected');
      });

      _socket?.on('disconnect', (_) {
        debugPrint('Socket disconnected');
      });

      _socket?.on('location:uploaded', (data) {
        try {
          debugPrint('Socket received location:uploaded: $data');
          final updated = LocationPoint.fromJson(Map<String, dynamic>.from(data));
          setState(() {
            final idx = locations.indexWhere((l) => l.userId == updated.userId);
            if (idx >= 0) {
              locations[idx] = updated;
            } else {
              locations.add(updated);
            }
            _lastUpdated = DateTime.now();
          });
          _fetchDistanceForUser(updated.userId);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _autoZoomToMarkers(_filteredLocations);
          });
        } catch (e, st) {
          debugPrint('Error handling socket location update: $e');
          debugPrint('$st');
        }
      });

      _socket?.on('geofence:alert', (data) {
        try {
          final d = Map<String, dynamic>.from(data);
          final event = d['event'] as String? ?? '';
          final geofenceId = d['geofence_id'];
          final gf = _geofences.firstWhere(
            (g) => g['id'] == geofenceId,
            orElse: () => {'name': 'Geofence'},
          );
          final gfName = gf['name'] ?? 'Geofence';
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Geofence alert: User ${event == 'entered' ? 'entered' : 'exited'} $gfName')),
            );
          }
        } catch (e) {
          debugPrint('Error handling geofence alert: $e');
        }
      });
    } catch (e, st) {
      debugPrint('Failed to init socket: $e');
      debugPrint('$st');
    }
  }

  Future<void> _fetchGeofences() async {
    try {
      final uri = Uri.parse('${ApiService.baseUrl}/geofences');
      final response = await http.get(uri, headers: {'Authorization': 'Bearer ${widget.token}'});
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _geofences = (body['geofences'] as List).map((g) => g as Map<String, dynamic>).toList();
        });
      }
    } catch (e) {
      debugPrint('Failed to fetch geofences: $e');
    }
  }

  Future<void> _fetchDistanceForUser(int userId) async {
    try {
      final today = DateTime.now().toIso8601String().split('T')[0];
      final uri = Uri.parse('${ApiService.baseUrl}/locations/stats/distance?user_id=$userId&date=$today');
      final response = await http.get(uri, headers: {'Authorization': 'Bearer ${widget.token}'});
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final km = (body['distance_km'] as num?)?.toDouble() ?? 0.0;
        setState(() {
          _userDistances[userId] = km;
        });
      }
    } catch (e) {
      debugPrint('Failed to fetch distance for user $userId: $e');
    }
  }

  Future<void> _fetchAllDistances() async {
    for (final loc in locations) {
      await _fetchDistanceForUser(loc.userId);
    }
  }

  Future<void> _sendNotification(int userId, String userName) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Notify $userName'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: 'Enter message'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Send'),
          ),
        ],
      ),
    );
    if (confirmed != true || controller.text.isEmpty) return;
    try {
      final uri = Uri.parse('${ApiService.baseUrl}/users/notify');
      final response = await http.post(
        uri,
        headers: {'Authorization': 'Bearer ${widget.token}', 'Content-Type': 'application/json'},
        body: jsonEncode({'user_id': userId, 'message': controller.text}),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(response.statusCode == 200 ? 'Notification sent' : 'Failed to send notification')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
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
            final updated = locations[idx];
            final merged = LocationPoint(
              userId: updated.userId,
              name: updated.name,
              latitude: updated.latitude,
              longitude: updated.longitude,
              recordedAt: updated.recordedAt,
              receivedAt: updated.receivedAt,
              isLive: updated.isLive,
              lastSeen: s['last_seen'] as String?,
              isOnline: s['is_online'] as bool?,
            );
            locations[idx] = merged;
          }
        }
      });
    } catch (e, st) {
      debugPrint('Failed to load initial statuses: $e');
      debugPrint('$st');
    }
  }

  Future<void> _fetchLocationHistory(LocationPoint location) async {
    try {
      final history = await ApiService.getLocationHistory(widget.token, location.userId);
      setState(() {
        _selectedLocation = location;
        _locationHistory = history;
        _showingHistory = true;
      });
    } catch (err) {
      debugPrint('Failed to fetch location history: $err');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load location history')),
      );
    }
  }

  int _getMinutesSinceUpdate(LocationPoint location) {
    try {
      final recordedTime = DateTime.parse(location.lastSeen ?? location.recordedAt);
      final now = DateTime.now();
      return now.difference(recordedTime).inMinutes;
    } catch (e) {
      return 0;
    }
  }

  Color _getPinColor(LocationPoint location) {
    // Online if isOnline flag provided, otherwise fallback to 30 minute rule
    final isOnline = location.isOnline ?? (_getMinutesSinceUpdate(location) < 30);
    return isOnline ? Colors.green : Colors.grey;
  }

  String _getLastSeenText(LocationPoint location) {
    final minutes = _getMinutesSinceUpdate(location);
    if (minutes < 1) return 'Just now';
    if (minutes == 1) return '1 min ago';
    if (minutes < 60) return '$minutes mins ago';
    final hours = minutes ~/ 60;
    if (hours == 1) return '1 hour ago';
    return '$hours hours ago';
  }

  String _getStatusText(LocationPoint location) {
    final isOnline = location.isOnline ?? (_getMinutesSinceUpdate(location) < 30);
    if (isOnline) return 'Active';
    try {
      final last = DateTime.parse(location.lastSeen ?? location.recordedAt);
      final hh = last.hour.toString().padLeft(2, '0');
      final mm = last.minute.toString().padLeft(2, '0');
      return 'Offline since $hh:$mm';
    } catch (e) {
      return 'Offline';
    }
  }

  List<LocationPoint> get _filteredLocations {
    switch (_filterMode) {
      case LocationFilterMode.liveOnly:
        return locations.where((l) {
          final minutesSince = _getMinutesSinceUpdate(l);
          return minutesSince < 15;
        }).toList();
      case LocationFilterMode.staleOnly:
        return locations.where((l) {
          final minutesSince = _getMinutesSinceUpdate(l);
          return minutesSince >= 15;
        }).toList();
      case LocationFilterMode.all:
      default:
        return locations;
    }
  }

  void _flyToLocation(LocationPoint location) {
    _mapController.move(
      LatLng(location.latitude, location.longitude),
      15.0,
    );
    setState(() {
      _selectedLocation = location;
    });
  }

  @override
  Widget build(BuildContext context) {
    final filteredLocations = _filteredLocations;
    final isMobileOrTablet = MediaQuery.of(context).size.width < 900;

    if (isLoading) {
      return Center(child: CircularProgressIndicator());
    }

    if (errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            'Unable to load live locations.\n$errorMessage',
            style: TextStyle(color: Colors.red),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (filteredLocations.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.location_off, size: 48, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                locations.isEmpty ? 'No Users Available' : 'No Users Match Filter',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 8),
              Text(
                locations.isEmpty
                    ? 'No users have reported a location yet.'
                    : 'No users match the selected filter.\nTry switching to Live + Stale.',
                style: TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        // Left sidebar
        if (!isMobileOrTablet)
          Container(
            width: 280,
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: Colors.grey[300]!)),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Text(
                    'Salespeople',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: locations.length,
                    itemBuilder: (context, index) {
                      final location = locations[index];
                      final minutesSince = _getMinutesSinceUpdate(location);
                      final statusColor = _getPinColor(location);
                      final isSelected = _selectedLocation?.userId == location.userId;
                      
                      return Container(
                        color: isSelected ? Colors.blue.withOpacity(0.1) : null,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => _flyToLocation(location),
                            child: Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 12,
                                        height: 12,
                                        decoration: BoxDecoration(
                                          color: statusColor,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          location.name,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  SizedBox(height: 4),
                                  Padding(
                                    padding: const EdgeInsets.only(left: 20.0),
                                    child: Text(
                                      _getLastSeenText(location),
                                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                                    ),
                                  ),
                                  if (isSelected) ...[
                                    SizedBox(height: 8),
                                    SizedBox(
                                      width: double.infinity,
                                      child: ElevatedButton(
                                        onPressed: () => _fetchLocationHistory(location),
                                        style: ElevatedButton.styleFrom(
                                          padding: EdgeInsets.symmetric(vertical: 6),
                                          backgroundColor: Colors.blue,
                                        ),
                                        child: Text(
                                          'View History',
                                          style: TextStyle(fontSize: 11, color: Colors.white),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        // Map area
        Expanded(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: ToggleButtons(
                        isSelected: [
                          _filterMode == LocationFilterMode.all,
                          _filterMode == LocationFilterMode.liveOnly,
                          _filterMode == LocationFilterMode.staleOnly,
                        ],
                        onPressed: (index) {
                          setState(() {
                            _filterMode = LocationFilterMode.values[index];
                          });
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            _autoZoomToMarkers(_filteredLocations);
                          });
                        },
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12.0),
                            child: Text('All'),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12.0),
                            child: Text('Live'),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12.0),
                            child: Text('Stale'),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Refreshing in ${_isPaused ? '--' : _secondsUntilRefresh}s',
                                  style: TextStyle(fontSize: 12, color: Colors.blue, fontWeight: FontWeight.w600),
                                ),
                                SizedBox(width: 12),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _isPaused ? Colors.green : Colors.amber,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      if (_isPaused) {
                                        // Resume
                                        _isPaused = false;
                                        _secondsUntilRefresh = 12;
                                        _fetchLocations();
                                      } else {
                                        // Pause
                                        _isPaused = true;
                                      }
                                    });
                                  },
                                  child: Row(
                                    children: [
                                      Text(_isPaused ? '▶ Resume Live' : '⏸ Pause Live'),
                                    ],
                                  ),
                                ),
                                SizedBox(width: 8),
                                if (_isPaused)
                                  Container(
                                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(4)),
                                    child: Text('PAUSED — not updating', style: TextStyle(color: Colors.white, fontSize: 12)),
                                  ),
                              ],
                            ),
                          Text(
                            'Last: ${_lastUpdated != null ? _formatTimestamp(_lastUpdated!) : '--:--:--'}',
                            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Legend
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                child: Row(
                  children: [
                    _buildLegendItem(Colors.green, 'Live (<15 min)'),
                    SizedBox(width: 16),
                    _buildLegendItem(Colors.orange, 'Stale (15-60 min)'),
                    SizedBox(width: 16),
                    _buildLegendItem(Colors.grey, 'Offline (>60 min)'),
                  ],
                ),
              ),
              Expanded(
                child: FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    center: filteredLocations.isNotEmpty
                        ? LatLng(filteredLocations.first.latitude, filteredLocations.first.longitude)
                        : LatLng(20, 0),
                    zoom: 5,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.gps_tracker',
                    ),
                    if (_showingHistory && _locationHistory != null)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: _locationHistory!
                                .map((loc) => LatLng(loc.latitude, loc.longitude))
                                .toList(),
                            color: Colors.blue.withOpacity(0.7),
                            strokeWidth: 3,
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        ...filteredLocations.map((location) {
                          final markerColor = _getPinColor(location);
                          final isSelected = _selectedLocation?.userId == location.userId;
                          final distKm = _userDistances[location.userId];
                          final battery = location.batteryLevel;
                          final batteryColor = (battery != null && battery < 20) ? Colors.red : Colors.green;
                          return Marker(
                            width: 190,
                            height: 145,
                            point: LatLng(location.latitude, location.longitude),
                            builder: (_) => Column(
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.location_pin, color: markerColor, size: 36),
                                    if (battery != null)
                                      Icon(
                                        battery > 80 ? Icons.battery_full :
                                        battery > 50 ? Icons.battery_5_bar :
                                        battery > 20 ? Icons.battery_3_bar :
                                        Icons.battery_alert,
                                        color: batteryColor,
                                        size: 16,
                                      ),
                                  ],
                                ),
                                Container(
                                  width: 160,
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: isSelected ? Colors.blue.withOpacity(0.95) : Colors.white.withOpacity(0.95),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isSelected ? Colors.blue : markerColor.withOpacity(0.8),
                                      width: isSelected ? 2 : 1,
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              location.name,
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                                color: (location.isOnline ?? false) ? (isSelected ? Colors.white : Colors.black) : (isSelected ? Colors.white70 : Colors.grey),
                                              ),
                                            ),
                                          ),
                                          GestureDetector(
                                            onTap: () => _sendNotification(location.userId, location.name),
                                            child: Icon(Icons.message, size: 14, color: isSelected ? Colors.white : Colors.blue),
                                          ),
                                        ],
                                      ),
                                      SizedBox(height: 2),
                                      Text(
                                        _getStatusText(location),
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: isSelected ? Colors.white70 : Colors.black54,
                                        ),
                                      ),
                                      if (distKm != null)
                                        Text(
                                          '${distKm.toStringAsFixed(1)} km today',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: isSelected ? Colors.white70 : Colors.black54,
                                          ),
                                        ),
                                      if (isSelected) ...[
                                        SizedBox(height: 4),
                                        GestureDetector(
                                          onTap: () => _fetchLocationHistory(location),
                                          child: Text(
                                            'View History →',
                                            style: TextStyle(
                                              fontSize: 9,
                                              color: Colors.white,
                                              decoration: TextDecoration.underline,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                        // History points
                        if (_showingHistory && _locationHistory != null)
                          ..._locationHistory!.map((historyPoint) {
                            return Marker(
                              width: 24,
                              height: 24,
                              point: LatLng(historyPoint.latitude, historyPoint.longitude),
                              builder: (_) => Tooltip(
                                message: _formatTimestamp(DateTime.parse(historyPoint.recordedAt)),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.blue,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 2),
                                  ),
                                  child: Center(
                                    child: Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLegendItem(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[700])),
      ],
    );
  }

  void _autoZoomToMarkers(List<LocationPoint> markersToShow) {
    if (markersToShow.isEmpty) return;

    if (markersToShow.length == 1) {
      _mapController.move(
        LatLng(markersToShow[0].latitude, markersToShow[0].longitude),
        13.0,
      );
      return;
    }

    double minLat = markersToShow[0].latitude;
    double maxLat = markersToShow[0].latitude;
    double minLng = markersToShow[0].longitude;
    double maxLng = markersToShow[0].longitude;

    for (final location in markersToShow) {
      minLat = (location.latitude < minLat) ? location.latitude : minLat;
      maxLat = (location.latitude > maxLat) ? location.latitude : maxLat;
      minLng = (location.longitude < minLng) ? location.longitude : minLng;
      maxLng = (location.longitude > maxLng) ? location.longitude : maxLng;
    }

    final latDelta = maxLat - minLat;
    final lngDelta = maxLng - minLng;
    const padding = 0.1;
    minLat -= latDelta * padding;
    maxLat += latDelta * padding;
    minLng -= lngDelta * padding;
    maxLng += lngDelta * padding;

    final centerLat = (minLat + maxLat) / 2;
    final centerLng = (minLng + maxLng) / 2;
    final maxDelta = (maxLat - minLat).abs() > (maxLng - minLng).abs()
        ? (maxLat - minLat).abs()
        : (maxLng - minLng).abs();

    double zoom = 18.0;
    if (maxDelta > 180) {
      zoom = 1.0;
    } else if (maxDelta > 90) {
      zoom = 2.0;
    } else if (maxDelta > 45) {
      zoom = 3.0;
    } else if (maxDelta > 22.5) {
      zoom = 4.0;
    } else if (maxDelta > 11.25) {
      zoom = 5.0;
    } else if (maxDelta > 5.625) {
      zoom = 6.0;
    } else if (maxDelta > 2.8125) {
      zoom = 7.0;
    } else if (maxDelta > 1.40625) {
      zoom = 8.0;
    } else if (maxDelta > 0.703125) {
      zoom = 9.0;
    } else if (maxDelta > 0.3515625) {
      zoom = 10.0;
    } else if (maxDelta > 0.17578125) {
      zoom = 11.0;
    } else if (maxDelta > 0.087890625) {
      zoom = 12.0;
    } else if (maxDelta > 0.0439453125) {
      zoom = 13.0;
    } else if (maxDelta > 0.02197265625) {
      zoom = 14.0;
    } else if (maxDelta > 0.010986328125) {
      zoom = 15.0;
    } else if (maxDelta > 0.0054931640625) {
      zoom = 16.0;
    } else if (maxDelta >= 0.0027465820312) {
      zoom = 17.0;
    } else {
      zoom = 18.0;
    }

    zoom = zoom.clamp(2.0, 18.0);
    _mapController.move(LatLng(centerLat, centerLng), zoom);
  }

  String _formatTimestamp(DateTime timestamp) {
    return '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}';
  }
}
