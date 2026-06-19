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
import '../models/user.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

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
  String? _error;

  // Replay
  Timer? _replayTimer;
  int _replayIndex = 0;
  bool _isReplaying = false;
  int _speedMultiplier = 1;
  LatLng? _replayPosition;

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
      _isReplaying = false;
      _replayIndex = 0;
      _replayPosition = null;
    });

    final dateStr = _selectedDate.toIso8601String().split('T')[0];
    try {
      final history = await ApiService.getLocationHistory(widget.token, _selectedUser!.id, date: dateStr);
      setState(() {
        _points = history;
        _loadedDate = _selectedDate;
        _loading = false;
      });
      // Map renders conditionally on hasData — wait for next frame before moving the controller
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
    _mapController.move(LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2), 13.0);
  }

  double _computeTotalDistanceKm(List<LocationPoint> pts) {
    if (pts.length < 2) return 0.0;
    final d = Distance();
    double meters = 0.0;
    for (int i = 1; i < pts.length; i++) {
      meters += d.as(LengthUnit.Meter,
          LatLng(pts[i - 1].latitude, pts[i - 1].longitude),
          LatLng(pts[i].latitude, pts[i].longitude));
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
    _replayTimer = Timer.periodic(Duration(milliseconds: (1000 / _speedMultiplier).round()), (_) {
      if (!mounted) return;
      setState(() {
        _replayIndex++;
        if (_replayIndex >= _points.length) {
          _replayTimer?.cancel();
          _isReplaying = false;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Replay complete')));
          return;
        }
        _replayPosition = LatLng(_points[_replayIndex].latitude, _points[_replayIndex].longitude);
        _mapController.move(_replayPosition!, _currentZoom);
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

  String _formatDuration(String aIso, String bIso) {
    try {
      final d = DateTime.parse(bIso).difference(DateTime.parse(aIso));
      if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
      if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
      return '${d.inSeconds}s';
    } catch (_) { return '--'; }
  }

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  bool _exporting = false;

  Future<void> _exportCsv() async {
    if (!kIsWeb || _selectedUser == null || _loadedDate == null || _exporting) return;
    setState(() => _exporting = true);

    final dateStr = _loadedDate!.toIso8601String().split('T')[0];
    final uri = Uri.parse('${ApiService.baseUrl}/locations/history/${_selectedUser!.id}/export?date=$dateStr');

    try {
      final response = await http.get(
        uri,
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );

      if (response.statusCode != 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Export failed (${response.statusCode})'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // Build a blob URL from the response bytes and trigger download via anchor.
      // This is the only approach that reliably works in Flutter CanvasKit web builds.
      final blob = html.Blob([response.bodyBytes], 'text/csv');
      final blobUrl = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: blobUrl)
        ..download = 'location-history-${_selectedUser!.name}-$dateStr.csv'
        ..style.display = 'none';
      html.document.body!.append(anchor);
      anchor.click();
      anchor.remove();
      html.Url.revokeObjectUrl(blobUrl);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('CSV downloaded'), duration: Duration(seconds: 2)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    final hasData = _points.isNotEmpty;
    final distKm = hasData ? _computeTotalDistanceKm(_points) : 0.0;
    final duration = hasData ? _formatDuration(_points.first.recordedAt, _points.last.recordedAt) : '--';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Filter bar ──────────────────────────────────────────────
        Container(
          color: AppTheme.surface,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: isMobile
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _userDropdown(),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: _datePicker()),
                      const SizedBox(width: 8),
                      _loadButton(),
                      const SizedBox(width: 8),
                      _exportButton(),
                    ]),
                  ],
                )
              : Row(children: [
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

        // ── Stats row ────────────────────────────────────────────────
        if (hasData)
          Container(
            color: AppTheme.background,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: AppTheme.statChip(
                    icon: Icons.location_on,
                    label: 'GPS Points',
                    value: '${_points.length}',
                    color: AppTheme.primaryLight,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: AppTheme.statChip(
                    icon: Icons.straighten,
                    label: 'Distance',
                    value: '${distKm.toStringAsFixed(2)} km',
                    color: AppTheme.success,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: AppTheme.statChip(
                    icon: Icons.schedule,
                    label: 'Duration',
                    value: duration,
                    color: AppTheme.warning,
                  ),
                ),
              ],
            ),
          ),

        // ── Error ────────────────────────────────────────────────────
        if (_error != null)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.errorLight,
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              border: Border.all(color: AppTheme.error.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: AppTheme.error, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(_error!, style: const TextStyle(color: AppTheme.error, fontSize: 13))),
              ],
            ),
          ),

        // ── Replay controls ─────────────────────────────────────────
        if (hasData)
          Container(
            color: AppTheme.surface,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _replayBtn(
                  icon: Icons.play_arrow_rounded,
                  label: 'Play',
                  color: AppTheme.success,
                  onPressed: _isReplaying ? null : _startReplay,
                ),
                const SizedBox(width: 8),
                _replayBtn(
                  icon: Icons.pause_rounded,
                  label: 'Pause',
                  color: AppTheme.warning,
                  onPressed: _isReplaying ? _pauseReplay : null,
                ),
                const SizedBox(width: 8),
                _replayBtn(
                  icon: Icons.replay_rounded,
                  label: 'Reset',
                  color: AppTheme.textMedium,
                  onPressed: _resetReplay,
                ),
                const SizedBox(width: 16),
                const Text('Speed', style: TextStyle(fontSize: 12, color: AppTheme.textMedium)),
                const SizedBox(width: 8),
                DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: _speedMultiplier,
                    isDense: true,
                    items: [1, 5, 10].map((s) => DropdownMenuItem(
                      value: s,
                      child: Text('${s}×', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    )).toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() { _speedMultiplier = v; });
                      if (_isReplaying) { _pauseReplay(); _startReplay(); }
                    },
                  ),
                ),
                const Spacer(),
                if (_isReplaying)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.success.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppTheme.success.withOpacity(0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.circle, size: 8, color: AppTheme.success),
                        const SizedBox(width: 6),
                        Text(
                          '${_replayIndex + 1} / ${_points.length}',
                          style: const TextStyle(fontSize: 12, color: AppTheme.success, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

        if (hasData) const Divider(height: 1),

        // ── Empty state ──────────────────────────────────────────────
        if (!hasData && !_loading && _error == null)
          Expanded(
            child: Center(
              child: Column(
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
                  const Text('No route loaded', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
                  const SizedBox(height: 6),
                  const Text('Select a salesperson and date, then tap Load History',
                      style: TextStyle(fontSize: 13, color: AppTheme.textMedium)),
                ],
              ),
            ),
          ),

        // ── Loading ──────────────────────────────────────────────────
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator())),

        // ── Map ──────────────────────────────────────────────────────
        if (hasData)
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    center: const LatLng(20, 0),
                    zoom: 5,
                    onMapEvent: (event) {
                      if (event is MapEventMove) _currentZoom = event.targetZoom;
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.gps_tracker',
                    ),
                    PolylineLayer(polylines: [
                      Polyline(
                        points: _points.map((p) => LatLng(p.latitude, p.longitude)).toList(),
                        color: AppTheme.primaryLight.withOpacity(0.85),
                        strokeWidth: 4,
                      ),
                    ]),
                    MarkerLayer(markers: [
                      // Start
                      Marker(
                        width: 70, height: 60,
                        point: LatLng(_points.first.latitude, _points.first.longitude),
                        builder: (_) => _flagMarker('Start', AppTheme.success),
                      ),
                      // End
                      Marker(
                        width: 70, height: 60,
                        point: LatLng(_points.last.latitude, _points.last.longitude),
                        builder: (_) => _flagMarker('End', AppTheme.error),
                      ),
                      // Replay dot
                      if (_replayPosition != null)
                        Marker(
                          width: 40, height: 40,
                          point: _replayPosition!,
                          builder: (_) => Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppTheme.primaryLight,
                              border: Border.all(color: Colors.white, width: 3),
                              boxShadow: [BoxShadow(color: AppTheme.primaryLight.withOpacity(0.4), blurRadius: 8)],
                            ),
                            child: const Icon(Icons.navigation, size: 20, color: Colors.white),
                          ),
                        ),
                    ]),
                  ],
                ),
                // Route info overlay
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.93),
                      borderRadius: BorderRadius.circular(AppTheme.radius),
                      boxShadow: AppTheme.cardShadow,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.person_pin_circle, size: 16, color: AppTheme.primaryLight),
                        const SizedBox(width: 6),
                        Text(
                          _selectedUser?.name ?? '',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatDate(_selectedDate),
                          style: const TextStyle(fontSize: 12, color: AppTheme.textMedium),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
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
          hint: const Row(
            children: [
              Icon(Icons.person_outline, size: 16, color: AppTheme.textMedium),
              SizedBox(width: 8),
              Text('Select salesperson', style: TextStyle(color: AppTheme.textMedium, fontSize: 14)),
            ],
          ),
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
        if (picked != null) {
          setState(() {
            _selectedDate = picked;
            // clear loaded data so export button disables until re-loaded
            _points = [];
            _loadedDate = null;
          });
        }
      },
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.calendar_today, size: 15, color: AppTheme.primaryLight),
            const SizedBox(width: 8),
            Text(_formatDate(_selectedDate),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppTheme.textDark)),
          ],
        ),
      ),
    );
  }

  Widget _loadButton() {
    return SizedBox(
      height: 44,
      child: ElevatedButton.icon(
        icon: _loading
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
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
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.download, size: 18),
        label: Text(_exporting ? 'Exporting…' : 'Export CSV'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.primaryLight,
          side: const BorderSide(color: AppTheme.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
        ),
        onPressed: canExport ? _exportCsv : null,
      ),
    );
  }

  Widget _replayBtn({required IconData icon, required String label, required Color color, VoidCallback? onPressed}) {
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
            border: Border.all(color: onPressed != null ? color.withOpacity(0.3) : Colors.grey.withOpacity(0.2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: onPressed != null ? color : Colors.grey),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                  color: onPressed != null ? color : Colors.grey)),
            ],
          ),
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
            boxShadow: [BoxShadow(color: color.withOpacity(0.4), blurRadius: 4, offset: const Offset(0, 2))],
          ),
          child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
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
