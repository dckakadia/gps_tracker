import 'dart:async';
import 'dart:ui' as ui;
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/location_point.dart';
import '../models/stop_point.dart';
import '../models/user.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

// ── Speed colour thresholds (in km/h) ─────────────────────────────────────────
Color _speedColor(double? speedMs) {
  if (speedMs == null) return AppTheme.primaryLight.withOpacity(0.85);
  final kmh = speedMs * 3.6;
  if (kmh < 30)  return const Color(0xFF2ECC71);  // green
  if (kmh < 60)  return const Color(0xFFF39C12);  // amber
  if (kmh < 90)  return const Color(0xFFE67E22);  // orange
  return const Color(0xFFE74C3C);                  // red
}

class HistoryScreen extends StatefulWidget {
  final String token;
  const HistoryScreen({required this.token});

  @override
  _HistoryScreenState createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<UserModel> _users = [];
  UserModel? _selectedUser;
  DateTime _selectedDate = DateTime.now();
  DateTime? _loadedDate;
  bool _loading = false;
  List<LocationPoint> _points = [];
  List<StopPoint> _stops = [];
  Map<String, dynamic>? _summary;
  String? _error;

  // ── Replay (smooth interpolation) ────────────────────────────────────────────
  Timer? _replayTimer;
  bool _isReplaying = false;
  int _speedMultiplier = 1;
  LatLng? _replayPosition;
  double? _replayAccuracy;     // for accuracy circle
  double? _replayHeading;

  // Smooth replay state
  int    _segmentIdx   = 0;    // current pair index (from _points[i] to _points[i+1])
  double _segmentT     = 0.0;  // interpolation progress 0.0–1.0 within current segment
  int    _displayIndex = 0;    // closest GPS point index for counter display

  late MapController _mapController;
  double _currentZoom = 13.0;

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

  // ── Data loading ──────────────────────────────────────────────────────────────

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
    _replayTimer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _points = [];
      _stops  = [];
      _summary = null;
      _isReplaying = false;
      _segmentIdx  = 0;
      _segmentT    = 0;
      _replayPosition = null;
    });

    final dateStr = _selectedDate.toIso8601String().split('T')[0];
    try {
      // Parallel load: history + stops + summary
      final results = await Future.wait([
        ApiService.getLocationHistory(widget.token, _selectedUser!.id, date: dateStr),
        ApiService.getStops(widget.token, _selectedUser!.id, dateStr)
            .catchError((_) => <StopPoint>[]),
        ApiService.getRouteSummary(widget.token, _selectedUser!.id, dateStr)
            .catchError((_) => <String, dynamic>{}),
      ]);

      final points  = results[0] as List<LocationPoint>;
      final stops   = results[1] as List<StopPoint>;
      final summary = results[2] as Map<String, dynamic>;

      setState(() {
        _points  = points;
        _stops   = stops;
        _summary = summary.isNotEmpty ? summary : null;
        _loadedDate = _selectedDate;
        _loading = false;
      });

      if (_points.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _fitMapToPoints(_points);
        });
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
      _mapController.move(LatLng(pts[0].latitude, pts[0].longitude), 14.0);
      return;
    }
    double minLat = pts[0].latitude, maxLat = pts[0].latitude;
    double minLng = pts[0].longitude, maxLng = pts[0].longitude;
    for (final p in pts) {
      if (p.latitude < minLat)  minLat = p.latitude;
      if (p.latitude > maxLat)  maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    _mapController.move(LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2), 13.0);
  }

  // ── Smooth replay ─────────────────────────────────────────────────────────────
  // Each tick of the 50 ms timer advances the interpolation parameter by an amount
  // proportional to the real time between the two GPS points (scaled by speedMultiplier).

  void _startReplay() {
    if (_points.length < 2) return;
    _replayTimer?.cancel();

    if (!_isReplaying) {
      setState(() {
        _isReplaying    = true;
        _segmentIdx     = 0;
        _segmentT       = 0;
        _displayIndex   = 0;
        _replayPosition = LatLng(_points[0].latitude, _points[0].longitude);
        _replayAccuracy = _points[0].accuracy;
        _replayHeading  = _points[0].heading;
      });
    } else {
      setState(() => _isReplaying = true);
    }

    const tickMs = 50;  // 20 fps
    _replayTimer = Timer.periodic(const Duration(milliseconds: tickMs), (_) {
      if (!mounted || _segmentIdx >= _points.length - 1) {
        _replayTimer?.cancel();
        if (mounted) setState(() { _isReplaying = false; });
        return;
      }

      final from = _points[_segmentIdx];
      final to   = _points[_segmentIdx + 1];

      DateTime? fromDt, toDt;
      try {
        fromDt = DateTime.parse(from.recordedAt);
        toDt   = DateTime.parse(to.recordedAt);
      } catch (_) {}

      final segDurationMs = (fromDt != null && toDt != null)
          ? toDt.difference(fromDt).inMilliseconds.toDouble()
          : 1000.0;

      // How much of real-time does one 50ms tick represent at this speed multiplier?
      final dtReal = tickMs.toDouble() * _speedMultiplier;
      final advance = segDurationMs > 0 ? dtReal / segDurationMs : 1.0;
      double newT = _segmentT + advance;

      int newIdx = _segmentIdx;
      while (newT >= 1.0 && newIdx < _points.length - 1) {
        newT -= 1.0;
        newIdx++;
      }
      if (newIdx >= _points.length - 1) {
        newT = 1.0;
        newIdx = _points.length - 2;
      }

      final f = _points[newIdx];
      final t = _points[newIdx + 1];
      final lat = f.latitude  + (t.latitude  - f.latitude)  * newT;
      final lng = f.longitude + (t.longitude - f.longitude) * newT;
      final acc = f.accuracy  != null && t.accuracy != null
          ? f.accuracy! + (t.accuracy! - f.accuracy!) * newT
          : (f.accuracy ?? t.accuracy);

      setState(() {
        _segmentIdx     = newIdx;
        _segmentT       = newT;
        _displayIndex   = newIdx;
        _replayPosition = LatLng(lat, lng);
        _replayAccuracy = acc;
        _replayHeading  = t.heading;
      });
      _mapController.move(LatLng(lat, lng), _currentZoom);
    });
  }

  void _pauseReplay() {
    _replayTimer?.cancel();
    setState(() => _isReplaying = false);
  }

  void _resetReplay() {
    _replayTimer?.cancel();
    setState(() {
      _isReplaying    = false;
      _segmentIdx     = 0;
      _segmentT       = 0;
      _displayIndex   = 0;
      _replayPosition = _points.isNotEmpty ? LatLng(_points[0].latitude, _points[0].longitude) : null;
      _replayAccuracy = _points.isNotEmpty ? _points[0].accuracy : null;
    });
  }

  // ── Speed-coloured polyline segments ─────────────────────────────────────────

  List<Polyline> _buildSpeedPolylines() {
    if (_points.length < 2) {
      return [Polyline(
        points: _points.map((p) => LatLng(p.latitude, p.longitude)).toList(),
        color: AppTheme.primaryLight.withOpacity(0.85),
        strokeWidth: 5,
      )];
    }
    final lines = <Polyline>[];
    for (int i = 0; i < _points.length - 1; i++) {
      lines.add(Polyline(
        points: [
          LatLng(_points[i].latitude, _points[i].longitude),
          LatLng(_points[i + 1].latitude, _points[i + 1].longitude),
        ],
        color: _speedColor(_points[i + 1].speed),
        strokeWidth: 5,
        strokeCap: StrokeCap.round,
      ));
    }
    return lines;
  }

  // ── CSV export ────────────────────────────────────────────────────────────────

  bool _exporting = false;

  Future<void> _exportCsv() async {
    if (!kIsWeb || _selectedUser == null || _loadedDate == null || _exporting) return;
    setState(() => _exporting = true);

    final dateStr = _loadedDate!.toIso8601String().split('T')[0];
    final uri = Uri.parse('${ApiService.baseUrl}/locations/history/${_selectedUser!.id}/export?date=$dateStr');

    try {
      final response = await http.get(uri, headers: {'Authorization': 'Bearer ${widget.token}'});
      if (response.statusCode != 200) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed (${response.statusCode})'), backgroundColor: Colors.red));
        return;
      }
      final blob    = html.Blob([response.bodyBytes], 'text/csv');
      final blobUrl = html.Url.createObjectUrlFromBlob(blob);
      final anchor  = html.AnchorElement(href: blobUrl)
        ..download = 'route-${_selectedUser!.name}-$dateStr.csv'
        ..style.display = 'none';
      html.document.body!.append(anchor);
      anchor.click();
      anchor.remove();
      html.Url.revokeObjectUrl(blobUrl);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('CSV downloaded'), duration: Duration(seconds: 2)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export error: $e'), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}/${d.year}';

  String _fmtTs(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
    } catch (_) { return '--'; }
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hasData = _points.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Filter bar ───────────────────────────────────────────────────────────
        Container(
          color: AppTheme.surface,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(children: [
            Expanded(flex: 3, child: _userDropdown()),
            const SizedBox(width: 12),
            _datePicker(),
            const SizedBox(width: 12),
            _loadButton(),
            const SizedBox(width: 12),
            _exportButton(),
          ]),
        ),
        const Divider(height: 1),

        // ── Summary stats row ────────────────────────────────────────────────────
        if (hasData && _summary != null) _buildSummaryRow(),

        // ── Replay controls ──────────────────────────────────────────────────────
        if (hasData)
          Container(
            color: AppTheme.surface,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              _replayBtn(Icons.play_arrow_rounded, 'Play',  AppTheme.success,
                  _isReplaying ? null : _startReplay),
              const SizedBox(width: 8),
              _replayBtn(Icons.pause_rounded, 'Pause', AppTheme.warning,
                  _isReplaying ? _pauseReplay : null),
              const SizedBox(width: 8),
              _replayBtn(Icons.replay_rounded, 'Reset', AppTheme.textMedium, _resetReplay),
              const SizedBox(width: 16),
              const Text('Speed', style: TextStyle(fontSize: 12, color: AppTheme.textMedium)),
              const SizedBox(width: 8),
              DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _speedMultiplier,
                  isDense: true,
                  items: [1, 5, 10, 50].map((s) => DropdownMenuItem(
                    value: s, child: Text('${s}×',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  )).toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _speedMultiplier = v);
                    if (_isReplaying) { _pauseReplay(); _startReplay(); }
                  },
                ),
              ),
              const Spacer(),
              if (_isReplaying)
                _replayCounter(),
            ]),
          ),

        if (hasData) const Divider(height: 1),

        // ── Error ────────────────────────────────────────────────────────────────
        if (_error != null)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.errorLight,
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              border: Border.all(color: AppTheme.error.withOpacity(0.3)),
            ),
            child: Row(children: [
              const Icon(Icons.error_outline, color: AppTheme.error, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(_error!,
                style: const TextStyle(color: AppTheme.error, fontSize: 13))),
            ]),
          ),

        // ── Empty state ──────────────────────────────────────────────────────────
        if (!hasData && !_loading && _error == null)
          Expanded(child: Center(child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 72, height: 72,
                decoration: BoxDecoration(
                  color: AppTheme.primaryLight.withOpacity(0.08),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.history_toggle_off, size: 36, color: AppTheme.primaryLight),
              ),
              const SizedBox(height: 16),
              const Text('No route loaded',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
              const SizedBox(height: 6),
              const Text('Select a salesperson and date, then tap Load Route',
                style: TextStyle(fontSize: 13, color: AppTheme.textMedium)),
            ],
          ))),

        if (_loading) const Expanded(child: Center(child: CircularProgressIndicator())),

        // ── Map ──────────────────────────────────────────────────────────────────
        if (hasData)
          Expanded(child: Stack(children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                center: const LatLng(20, 0),
                zoom: 5,
                maxZoom: 19,
                onMapEvent: (event) {
                  if (event is MapEventMove) _currentZoom = event.targetZoom;
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.gps_tracker',
                  maxZoom: 19,
                ),

                // ── Speed-coloured polyline ──────────────────────────────────
                PolylineLayer(polylines: _buildSpeedPolylines()),

                // ── Accuracy circle around replay dot ────────────────────────
                if (_replayPosition != null && _replayAccuracy != null && _replayAccuracy! > 0)
                  CircleLayer(circles: [
                    CircleMarker(
                      point: _replayPosition!,
                      radius: _replayAccuracy!,
                      useRadiusInMeter: true,
                      color: Colors.blue.withOpacity(0.12),
                      borderColor: Colors.blue.withOpacity(0.5),
                      borderStrokeWidth: 1,
                    ),
                  ]),

                // ── Stop markers ─────────────────────────────────────────────
                MarkerLayer(markers: [
                  // Start / End
                  Marker(
                    width: 70, height: 60,
                    point: LatLng(_points.first.latitude, _points.first.longitude),
                    builder: (_) => _flagMarker('Start', AppTheme.success),
                  ),
                  Marker(
                    width: 70, height: 60,
                    point: LatLng(_points.last.latitude, _points.last.longitude),
                    builder: (_) => _flagMarker('End', AppTheme.error),
                  ),

                  // Detected stops
                  ..._stops.map((stop) => Marker(
                    width: 80, height: 70,
                    point: LatLng(stop.lat, stop.lng),
                    builder: (_) => _stopMarker(stop),
                  )),

                  // Replay dot
                  if (_replayPosition != null)
                    Marker(
                      width: 40, height: 40,
                      point: _replayPosition!,
                      builder: (_) => _replayDot(),
                    ),
                ]),
              ],
            ),

            // ── Speed legend overlay ─────────────────────────────────────────
            Positioned(
              bottom: 12, left: 12,
              child: _speedLegend(),
            ),

            // ── Route info overlay ───────────────────────────────────────────
            Positioned(
              top: 12, left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.93),
                  borderRadius: BorderRadius.circular(AppTheme.radius),
                  boxShadow: AppTheme.cardShadow,
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.person_pin_circle, size: 16, color: AppTheme.primaryLight),
                  const SizedBox(width: 6),
                  Text(_selectedUser?.name ?? '',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                        color: AppTheme.textDark)),
                  const SizedBox(width: 8),
                  Text(_formatDate(_selectedDate),
                    style: const TextStyle(fontSize: 12, color: AppTheme.textMedium)),
                ]),
              ),
            ),
          ])),
      ],
    );
  }

  // ── Sub-widgets ───────────────────────────────────────────────────────────────

  Widget _buildSummaryRow() {
    final s = _summary!;
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          AppTheme.statChip(icon: Icons.location_on, label: 'Points',
              value: '${s['point_count'] ?? _points.length}', color: AppTheme.primaryLight),
          const SizedBox(width: 10),
          AppTheme.statChip(icon: Icons.straighten, label: 'Distance',
              value: '${s['total_distance_km'] ?? '--'} km', color: AppTheme.success),
          const SizedBox(width: 10),
          AppTheme.statChip(icon: Icons.schedule, label: 'Duration',
              value: '${s['duration_minutes'] ?? '--'} min', color: AppTheme.warning),
          const SizedBox(width: 10),
          AppTheme.statChip(icon: Icons.speed, label: 'Avg Speed',
              value: '${s['avg_speed_kmh'] ?? '--'} km/h', color: const Color(0xFF3498DB)),
          const SizedBox(width: 10),
          AppTheme.statChip(icon: Icons.flash_on, label: 'Max Speed',
              value: '${s['max_speed_kmh'] ?? '--'} km/h', color: const Color(0xFFE74C3C)),
          const SizedBox(width: 10),
          AppTheme.statChip(icon: Icons.pause_circle, label: 'Stops',
              value: '${s['stop_count'] ?? _stops.length}', color: const Color(0xFF9B59B6)),
        ]),
      ),
    );
  }

  Widget _replayDot() {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppTheme.primaryLight,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [BoxShadow(color: AppTheme.primaryLight.withOpacity(0.4), blurRadius: 8)],
      ),
      child: _replayHeading != null
          ? Transform.rotate(
              angle: (_replayHeading! * 3.14159265 / 180),
              child: const Icon(Icons.navigation, size: 20, color: Colors.white),
            )
          : const Icon(Icons.circle, size: 12, color: Colors.white),
    );
  }

  Widget _replayCounter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.success.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.success.withOpacity(0.4)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.circle, size: 8, color: AppTheme.success),
        const SizedBox(width: 6),
        Text(
          '${_displayIndex + 1} / ${_points.length}',
          style: const TextStyle(fontSize: 12, color: AppTheme.success, fontWeight: FontWeight.w600),
        ),
      ]),
    );
  }

  Widget _stopMarker(StopPoint stop) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFF9B59B6),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: Colors.purple.withOpacity(0.35), blurRadius: 4, offset: const Offset(0, 2))],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.pause_circle_outline, size: 11, color: Colors.white),
            const SizedBox(width: 3),
            Text(stop.durationLabel,
              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
          ]),
        ),
        CustomPaint(
          size: const Size(10, 6),
          painter: _TrianglePainter(const Color(0xFF9B59B6)),
        ),
      ],
    );
  }

  Widget _speedLegend() {
    final items = [
      ('< 30 km/h',   const Color(0xFF2ECC71)),
      ('30–60 km/h',  const Color(0xFFF39C12)),
      ('60–90 km/h',  const Color(0xFFE67E22)),
      ('90+ km/h',    const Color(0xFFE74C3C)),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Speed', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
              color: AppTheme.textMedium)),
          const SizedBox(height: 4),
          ...items.map((e) => Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 16, height: 4,
                decoration: BoxDecoration(color: e.$2, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 6),
              Text(e.$1, style: const TextStyle(fontSize: 10, color: AppTheme.textDark)),
            ]),
          )),
        ],
      ),
    );
  }

  Widget _userDropdown() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: AppTheme.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<UserModel>(
          value: _selectedUser,
          isExpanded: true,
          hint: const Row(children: [
            Icon(Icons.person_outline, size: 16, color: AppTheme.textMedium),
            SizedBox(width: 8),
            Text('Select salesperson',
              style: TextStyle(color: AppTheme.textMedium, fontSize: 14)),
          ]),
          items: _users.map((u) => DropdownMenuItem(
            value: u,
            child: Row(children: [
              const Icon(Icons.person, size: 16, color: AppTheme.primaryLight),
              const SizedBox(width: 8),
              Text(u.name, style: const TextStyle(fontSize: 14)),
            ]),
          )).toList(),
          onChanged: (v) => setState(() => _selectedUser = v),
        ),
      ),
    );
  }

  Widget _datePicker() {
    return InkWell(
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: _selectedDate,
          firstDate: DateTime(2020),
          lastDate: DateTime.now(),
        );
        if (picked != null) setState(() {
          _selectedDate = picked;
          _points = [];
          _loadedDate = null;
        });
      },
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.calendar_today, size: 15, color: AppTheme.primaryLight),
          const SizedBox(width: 8),
          Text(_formatDate(_selectedDate),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500,
                color: AppTheme.textDark)),
        ]),
      ),
    );
  }

  Widget _loadButton() {
    return SizedBox(
      height: 44,
      child: ElevatedButton.icon(
        icon: _loading
            ? const SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.route, size: 18),
        label: const Text('Load Route'),
        onPressed: (_loading || _selectedUser == null) ? null : _loadHistory,
      ),
    );
  }

  Widget _exportButton() {
    final canExport = _points.isNotEmpty && _loadedDate != null && !_exporting;
    return SizedBox(
      height: 44,
      child: OutlinedButton.icon(
        icon: _exporting
            ? const SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.download, size: 18),
        label: Text(_exporting ? 'Exporting…' : 'Export CSV'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.primaryLight,
          side: const BorderSide(color: AppTheme.border),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
        ),
        onPressed: canExport ? _exportCsv : null,
      ),
    );
  }

  Widget _replayBtn(IconData icon, String label, Color color, VoidCallback? onPressed) {
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: onPressed != null ? color.withOpacity(0.1) : Colors.grey.withOpacity(0.05),
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            border: Border.all(
              color: onPressed != null ? color.withOpacity(0.3) : Colors.grey.withOpacity(0.2)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 18, color: onPressed != null ? color : Colors.grey),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                color: onPressed != null ? color : Colors.grey)),
          ]),
        ),
      ),
    );
  }

  Widget _flagMarker(String label, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: color.withOpacity(0.4), blurRadius: 4,
                offset: const Offset(0, 2))],
          ),
          child: Text(label,
            style: const TextStyle(color: Colors.white, fontSize: 11,
                fontWeight: FontWeight.bold)),
        ),
        CustomPaint(
          size: const Size(10, 6),
          painter: _TrianglePainter(color),
        ),
      ],
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final Color color;
  const _TrianglePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = ui.Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
