import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/location_point.dart';
import '../models/user.dart';
import '../services/api_service.dart';

class HistoryScreen extends StatefulWidget {
  final String token;
  HistoryScreen({required this.token});

  @override
  _HistoryScreenState createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<UserModel> _users = [];
  UserModel? _selectedUser;
  DateTime _selectedDate = DateTime.now();
  bool _loading = false;
  List<LocationPoint> _points = [];
  String? _error;

  // Replay
  Timer? _replayTimer;
  int _replayIndex = 0;
  bool _isReplaying = false;
  int _speedMultiplier = 1;
  LatLng? _replayPosition;

  late MapController _mapController;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _loadUsers();
  }

  @override
  void dispose() {
    _replayTimer?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    try {
      final users = await ApiService.getUsers(widget.token);
      setState(() => _users = users);
    } catch (err) {
      setState(() => _error = 'Failed to load users: $err');
    }
  }

  Future<void> _loadHistory() async {
    if (_selectedUser == null) return;
    setState(() {
      _loading = true;
      _error = null;
      _points = [];
    });

    final dateStr = _selectedDate.toIso8601String().split('T')[0];
    try {
      final history = await ApiService.getLocationHistory(widget.token, _selectedUser!.id, date: dateStr);
      setState(() {
        _points = history;
        _loading = false;
      });
      if (_points.isNotEmpty) {
        _fitMapToPoints(_points);
      }
    } catch (err) {
      setState(() {
        _error = 'Failed to load history: $err';
        _loading = false;
      });
    }
  }

  void _fitMapToPoints(List<LocationPoint> pts) {
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      _mapController.move(LatLng(pts[0].latitude, pts[0].longitude), 13.0);
      return;
    }
    double minLat = pts[0].latitude, maxLat = pts[0].latitude;
    double minLng = pts[0].longitude, maxLng = pts[0].longitude;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final centerLat = (minLat + maxLat) / 2;
    final centerLng = (minLng + maxLng) / 2;
    _mapController.move(LatLng(centerLat, centerLng), 13.0);
  }

  double _computeTotalDistanceKm(List<LocationPoint> pts) {
    if (pts.length < 2) return 0.0;
    final Distance d = Distance();
    double meters = 0.0;
    for (int i = 1; i < pts.length; i++) {
      final a = LatLng(pts[i - 1].latitude, pts[i - 1].longitude);
      final b = LatLng(pts[i].latitude, pts[i].longitude);
      meters += d.as(LengthUnit.Meter, a, b);
    }
    return meters / 1000.0;
  }

  void _startReplay() {
    if (_points.isEmpty) return;
    _replayTimer?.cancel();
    setState(() {
      _isReplaying = true;
      _replayIndex = 0;
      _replayPosition = LatLng(_points[0].latitude, _points[0].longitude);
    });

    final intervalMs = (1000 / _speedMultiplier).round();
    _replayTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      if (!mounted) return;
      setState(() {
        _replayIndex++;
        if (_replayIndex >= _points.length) {
          _replayTimer?.cancel();
          _isReplaying = false;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Replay complete')));
          return;
        }
        _replayPosition = LatLng(_points[_replayIndex].latitude, _points[_replayIndex].longitude);
      });
    });
  }

  void _pauseReplay() {
    _replayTimer?.cancel();
    setState(() => _isReplaying = false);
  }

  void _resetReplay() {
    _replayTimer?.cancel();
    setState(() {
      _isReplaying = false;
      _replayIndex = 0;
      _replayPosition = _points.isNotEmpty ? LatLng(_points[0].latitude, _points[0].longitude) : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButton<UserModel>(
                  isExpanded: true,
                  value: _selectedUser,
                  hint: Text('Select salesperson'),
                  items: _users.map((u) => DropdownMenuItem(value: u, child: Text(u.name))).toList(),
                  onChanged: (v) => setState(() => _selectedUser = v),
                ),
              ),
              SizedBox(width: 12),
              TextButton(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _selectedDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setState(() => _selectedDate = picked);
                },
                child: Text('${_selectedDate.toIso8601String().split('T')[0]}'),
              ),
              SizedBox(width: 12),
              ElevatedButton(
                onPressed: _loading ? null : _loadHistory,
                child: _loading ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Text('Load History'),
              ),
            ],
          ),
          SizedBox(height: 12),
          if (_points.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  children: [
                    Text('Points: ${_points.length}'),
                    SizedBox(width: 16),
                    Text('Distance: ${_computeTotalDistanceKm(_points).toStringAsFixed(2)} km'),
                    SizedBox(width: 16),
                    Text('Time: ${_points.isNotEmpty ? _formatDurationBetween(_points.first.recordedAt, _points.last.recordedAt) : '--'}'),
                  ],
                ),
              ),
            ),
          if (_points.isEmpty && !_loading && _error == null)
            Padding(
              padding: const EdgeInsets.only(top: 12.0),
              child: Text('No location data for this user on the selected date', style: TextStyle(color: Colors.grey[700])),
            ),
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: Colors.red)),
          ],
          SizedBox(height: 12),

          // Replay controls
          if (_points.isNotEmpty) ...[
            Row(
              children: [
                ElevatedButton(
                  onPressed: _isReplaying ? null : _startReplay,
                  child: Text('▶ Play'),
                ),
                SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isReplaying ? _pauseReplay : null,
                  child: Text('⏸ Pause'),
                ),
                SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _resetReplay,
                  child: Text('⏮ Reset'),
                ),
                SizedBox(width: 16),
                Text('Speed:'),
                SizedBox(width: 8),
                DropdownButton<int>(
                  value: _speedMultiplier,
                  items: [1, 5, 10].map((s) => DropdownMenuItem(value: s, child: Text('${s}×'))).toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      _speedMultiplier = v;
                      if (_isReplaying) {
                        _pauseReplay();
                        _startReplay();
                      }
                    });
                  },
                ),
              ],
            ),
            SizedBox(height: 8),
          ],

          // Map
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(center: LatLng(20, 0), zoom: 5),
              children: [
                TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.example.gps_tracker'),
                if (_points.isNotEmpty)
                  PolylineLayer(polylines: [
                    Polyline(points: _points.map((p) => LatLng(p.latitude, p.longitude)).toList(), color: Colors.blue, strokeWidth: 4),
                  ]),
                MarkerLayer(markers: [
                  // Start marker
                  if (_points.isNotEmpty)
                    Marker(
                      width: 80,
                      height: 80,
                      point: LatLng(_points.first.latitude, _points.first.longitude),
                      builder: (_) => Column(
                        children: [
                          Icon(Icons.flag, color: Colors.green),
                          Text('Start', style: TextStyle(color: Colors.green)),
                        ],
                      ),
                    ),
                  // End marker
                  if (_points.isNotEmpty)
                    Marker(
                      width: 80,
                      height: 80,
                      point: LatLng(_points.last.latitude, _points.last.longitude),
                      builder: (_) => Column(
                        children: [
                          Icon(Icons.flag, color: Colors.red),
                          Text('End', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  // Replay moving marker
                  if (_replayPosition != null)
                    Marker(
                      width: 36,
                      height: 36,
                      point: _replayPosition!,
                      builder: (_) => Icon(Icons.location_on, color: Colors.blue, size: 28),
                    ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDurationBetween(String aIso, String bIso) {
    try {
      final a = DateTime.parse(aIso);
      final b = DateTime.parse(bIso);
      final d = b.difference(a);
      final hours = d.inHours;
      final mins = d.inMinutes.remainder(60);
      final secs = d.inSeconds.remainder(60);
      return '${hours}h ${mins}m ${secs}s';
    } catch (e) {
      return '--';
    }
  }
}
