import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import '../models/location_point.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

class GeofenceScreen extends StatefulWidget {
  final String token;
  const GeofenceScreen({required this.token});

  @override
  _GeofenceScreenState createState() => _GeofenceScreenState();
}

class _GeofenceScreenState extends State<GeofenceScreen> {
  final MapController _mapController = MapController();
  List<Map<String, dynamic>> _geofences = [];
  bool _drawMode = false;
  bool _loading = false;
  int? _selectedId;

  @override
  void initState() {
    super.initState();
    _loadGeofences();
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _loadGeofences() async {
    setState(() => _loading = true);
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
      debugPrint('Failed to load geofences: $e');
    } finally {
      setState(() => _loading = false);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerMapOnData());
  }

  Future<void> _centerMapOnData() async {
    if (!mounted) return;
    if (_geofences.isNotEmpty) {
      final lats = _geofences.map((g) => (g['latitude'] as num).toDouble());
      final lngs = _geofences.map((g) => (g['longitude'] as num).toDouble());
      final centerLat = lats.reduce((a, b) => a + b) / _geofences.length;
      final centerLng = lngs.reduce((a, b) => a + b) / _geofences.length;
      _mapController.move(LatLng(centerLat, centerLng), _geofences.length == 1 ? 13.0 : 10.0);
      return;
    }
    // No geofences yet — center on live user locations so admin can pick a spot.
    try {
      final locs = await ApiService.getLatestLocations(widget.token, includeStale: true);
      if (locs.isNotEmpty && mounted) {
        final avgLat = locs.map((l) => l.latitude).reduce((a, b) => a + b) / locs.length;
        final avgLng = locs.map((l) => l.longitude).reduce((a, b) => a + b) / locs.length;
        _mapController.move(LatLng(avgLat, avgLng), 11.0);
      }
    } catch (_) {}
  }

  Future<void> _createGeofence(double latitude, double longitude) async {
    final nameController = TextEditingController();
    final radiusController = TextEditingController(text: '500');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radius)),
        title: const Row(
          children: [
            Icon(Icons.add_location_alt, color: AppTheme.primaryLight),
            SizedBox(width: 10),
            Text('New Geofence', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                prefixIcon: Icon(Icons.label_outline, size: 18),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: radiusController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Radius (meters)',
                prefixIcon: Icon(Icons.radio_button_unchecked, size: 18),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.info_outline, size: 14, color: AppTheme.textMedium),
                const SizedBox(width: 6),
                Text(
                  'Center: ${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textMedium),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton.icon(
            icon: const Icon(Icons.check, size: 16),
            label: const Text('Create'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirmed != true || nameController.text.trim().isEmpty) return;
    try {
      final uri = Uri.parse('${ApiService.baseUrl}/geofences');
      final response = await http.post(
        uri,
        headers: {'Authorization': 'Bearer ${widget.token}', 'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': nameController.text.trim(),
          'latitude': latitude,
          'longitude': longitude,
          'radius_meters': double.tryParse(radiusController.text) ?? 500.0,
        }),
      );
      if (response.statusCode == 201) {
        _loadGeofences();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Geofence created'),
              backgroundColor: AppTheme.success,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _editGeofence(Map<String, dynamic> gf) async {
    final id = gf['id'] as int;
    final nameController = TextEditingController(text: gf['name'] as String? ?? '');
    final radiusController = TextEditingController(
      text: ((gf['radius_meters'] as num?)?.toDouble() ?? 500.0).toStringAsFixed(0),
    );
    final latitude = (gf['latitude'] as num).toDouble();
    final longitude = (gf['longitude'] as num).toDouble();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radius)),
        title: const Row(
          children: [
            Icon(Icons.edit_location_alt, color: AppTheme.primaryLight),
            SizedBox(width: 10),
            Text('Edit Geofence', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                prefixIcon: Icon(Icons.label_outline, size: 18),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: radiusController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Radius (meters)',
                prefixIcon: Icon(Icons.radio_button_unchecked, size: 18),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.info_outline, size: 14, color: AppTheme.textMedium),
                const SizedBox(width: 6),
                Text(
                  'Center: ${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textMedium),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton.icon(
            icon: const Icon(Icons.check, size: 16),
            label: const Text('Save'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirmed != true || nameController.text.trim().isEmpty) return;
    try {
      await ApiService.updateGeofence(
        widget.token,
        id,
        name: nameController.text.trim(),
        latitude: latitude,
        longitude: longitude,
        radiusMeters: double.tryParse(radiusController.text) ?? 500.0,
      );
      _loadGeofences();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Geofence updated'),
            backgroundColor: AppTheme.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _deleteGeofence(int id, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radius)),
        title: const Row(
          children: [
            Icon(Icons.delete_outline, color: AppTheme.error),
            SizedBox(width: 10),
            Text('Delete Geofence', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        content: Text('Delete "$name"? Alerts for this zone will stop immediately.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await http.delete(
        Uri.parse('${ApiService.baseUrl}/geofences/$id'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (_selectedId == id) setState(() => _selectedId = null);
      _loadGeofences();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  void _flyToGeofence(Map<String, dynamic> gf) {
    final lat = (gf['latitude'] as num).toDouble();
    final lng = (gf['longitude'] as num).toDouble();
    _mapController.move(LatLng(lat, lng), 14.0);
    setState(() => _selectedId = gf['id'] as int);
  }

  Color _geofenceColor(int id) =>
      _selectedId == id ? AppTheme.primary : AppTheme.primaryLight;

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 700;

    return Column(
      children: [
        // ── Toolbar ────────────────────────────────────────────────
        Container(
          color: AppTheme.surface,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.fence, color: AppTheme.primaryLight, size: 20),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Geofences',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textDark)),
              ),
              if (_drawMode)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryLight.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppTheme.primaryLight.withOpacity(0.4)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.touch_app, size: 14, color: AppTheme.primaryLight),
                      SizedBox(width: 6),
                      Text('Tap map to place', style: TextStyle(fontSize: 12, color: AppTheme.primaryLight, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                icon: Icon(_drawMode ? Icons.close : Icons.add_location_alt, size: 16),
                label: Text(_drawMode ? 'Cancel' : 'Add Zone'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _drawMode ? AppTheme.error : AppTheme.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                onPressed: () => setState(() => _drawMode = !_drawMode),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // ── Body (responsive) ──────────────────────────────────────
        Expanded(
          child: isMobile
              ? Column(children: [
                  Expanded(flex: 3, child: _buildMap()),
                  const Divider(height: 1),
                  SizedBox(height: 220, child: _buildSidebar()),
                ])
              : Row(children: [
                  SizedBox(width: 260, child: _buildSidebar()),
                  const VerticalDivider(width: 1),
                  Expanded(child: _buildMap()),
                ]),
        ),
      ],
    );
  }

  Widget _buildSidebar() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_geofences.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                  color: AppTheme.primaryLight.withOpacity(0.08),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.fence, size: 28, color: AppTheme.primaryLight),
              ),
              const SizedBox(height: 12),
              const Text('No geofences yet', style: TextStyle(fontWeight: FontWeight.w600, color: AppTheme.textDark)),
              const SizedBox(height: 6),
              const Text('Tap "Add Zone" then click on the map to create one.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textMedium), textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Row(
            children: [
              const Icon(Icons.layers, size: 14, color: AppTheme.textMedium),
              const SizedBox(width: 6),
              Text('${_geofences.length} zone${_geofences.length == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMedium, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _geofences.length,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 14, endIndent: 14),
            itemBuilder: (ctx, i) {
              final gf = _geofences[i];
              final id = gf['id'] as int;
              final isSelected = _selectedId == id;
              final radiusM = (gf['radius_meters'] as num).toDouble();
              final radiusLabel = radiusM >= 1000
                  ? '${(radiusM / 1000).toStringAsFixed(1)} km'
                  : '${radiusM.toStringAsFixed(0)} m';

              return Material(
                color: isSelected ? AppTheme.primary.withOpacity(0.06) : Colors.transparent,
                child: InkWell(
                  onTap: () => _flyToGeofence(gf),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(
                      children: [
                        Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: _geofenceColor(id).withOpacity(0.12),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.fence, size: 18, color: _geofenceColor(id)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(gf['name'] ?? '',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: isSelected ? AppTheme.primary : AppTheme.textDark,
                                  ),
                                  overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  const Icon(Icons.radio_button_unchecked, size: 11, color: AppTheme.textMedium),
                                  const SizedBox(width: 4),
                                  Text(radiusLabel, style: const TextStyle(fontSize: 11, color: AppTheme.textMedium)),
                                ],
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 18, color: AppTheme.primaryLight),
                          tooltip: 'Edit',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          onPressed: () => _editGeofence(gf),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.error),
                          tooltip: 'Delete',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          onPressed: () => _deleteGeofence(id, gf['name'] ?? ''),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMap() {
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            center: const LatLng(20, 0),
            zoom: 5,
            maxZoom: 19,
            onTap: _drawMode
                ? (tapPos, point) {
                    _createGeofence(point.latitude, point.longitude);
                    setState(() => _drawMode = false);
                  }
                : null,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.gps_tracker',
              maxZoom: 19,
            ),
            CircleLayer(
              circles: _geofences.map((gf) {
                final id = gf['id'] as int;
                final isSelected = _selectedId == id;
                final color = _geofenceColor(id);
                return CircleMarker(
                  point: LatLng(
                    (gf['latitude'] as num).toDouble(),
                    (gf['longitude'] as num).toDouble(),
                  ),
                  radius: (gf['radius_meters'] as num).toDouble(),
                  useRadiusInMeter: true,
                  color: color.withOpacity(isSelected ? 0.25 : 0.15),
                  borderColor: color.withOpacity(isSelected ? 1.0 : 0.7),
                  borderStrokeWidth: isSelected ? 2.5 : 1.5,
                );
              }).toList(),
            ),
            MarkerLayer(
              markers: _geofences.map((gf) {
                final id = gf['id'] as int;
                final isSelected = _selectedId == id;
                final color = _geofenceColor(id);
                return Marker(
                  width: 130, height: 48,
                  point: LatLng(
                    (gf['latitude'] as num).toDouble(),
                    (gf['longitude'] as num).toDouble(),
                  ),
                  builder: (_) => GestureDetector(
                    onTap: () => _flyToGeofence(gf),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: isSelected ? color : Colors.white.withOpacity(0.92),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: color, width: isSelected ? 0 : 1.5),
                            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 4)],
                          ),
                          child: Text(
                            gf['name'] ?? '',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: isSelected ? Colors.white : color,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(Icons.location_on, color: color, size: 20),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),

        // Draw mode hint overlay
        if (_drawMode)
          Positioned(
            bottom: 16, left: 0, right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withOpacity(0.93),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: AppTheme.cardShadow,
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.touch_app, color: Colors.white, size: 18),
                    SizedBox(width: 8),
                    Text('Tap anywhere on the map to place geofence center',
                        style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),

        // Count badge
        Positioned(
          top: 12, right: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.93),
              borderRadius: BorderRadius.circular(20),
              boxShadow: AppTheme.cardShadow,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.fence, size: 14, color: AppTheme.primaryLight),
                const SizedBox(width: 6),
                Text(
                  '${_geofences.length} zone${_geofences.length == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
