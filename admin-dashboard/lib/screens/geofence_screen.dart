import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';

class GeofenceScreen extends StatefulWidget {
  final String token;
  GeofenceScreen({required this.token});

  @override
  _GeofenceScreenState createState() => _GeofenceScreenState();
}

class _GeofenceScreenState extends State<GeofenceScreen> {
  final MapController _mapController = MapController();
  List<Map<String, dynamic>> _geofences = [];
  bool _drawMode = false;
  bool _loading = false;

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
  }

  Future<void> _createGeofence(double latitude, double longitude) async {
    final nameController = TextEditingController();
    final radiusController = TextEditingController(text: '500');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('New Geofence'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: InputDecoration(labelText: 'Name')),
            TextField(
              controller: radiusController,
              decoration: InputDecoration(labelText: 'Radius (meters)'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Create')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final uri = Uri.parse('${ApiService.baseUrl}/geofences');
      final response = await http.post(
        uri,
        headers: {'Authorization': 'Bearer ${widget.token}', 'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': nameController.text,
          'latitude': latitude,
          'longitude': longitude,
          'radius_meters': double.tryParse(radiusController.text) ?? 500.0,
        }),
      );
      if (response.statusCode == 201) {
        _loadGeofences();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Geofence created')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _deleteGeofence(int id) async {
    try {
      final uri = Uri.parse('${ApiService.baseUrl}/geofences/$id');
      await http.delete(uri, headers: {'Authorization': 'Bearer ${widget.token}'});
      _loadGeofences();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Text('Geofence Manager', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              SizedBox(width: 16),
              ElevatedButton.icon(
                icon: Icon(_drawMode ? Icons.cancel : Icons.add_location),
                label: Text(_drawMode ? 'Cancel' : 'Add Geofence'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _drawMode ? Colors.red : Colors.blue,
                ),
                onPressed: () => setState(() => _drawMode = !_drawMode),
              ),
              SizedBox(width: 8),
              if (_drawMode)
                Text('Tap on the map to place geofence center', style: TextStyle(color: Colors.blue, fontSize: 12)),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              // Geofence list
              Container(
                width: 240,
                decoration: BoxDecoration(border: Border(right: BorderSide(color: Colors.grey[300]!))),
                child: _loading
                    ? Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        itemCount: _geofences.length,
                        itemBuilder: (ctx, i) {
                          final gf = _geofences[i];
                          return ListTile(
                            leading: Icon(Icons.location_on, color: Colors.blue),
                            title: Text(gf['name'] ?? ''),
                            subtitle: Text('${gf['radius_meters']}m radius'),
                            trailing: IconButton(
                              icon: Icon(Icons.delete, color: Colors.red),
                              onPressed: () => _deleteGeofence(gf['id'] as int),
                            ),
                          );
                        },
                      ),
              ),
              // Map
              Expanded(
                child: FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    center: LatLng(20, 0),
                    zoom: 5,
                    onTap: _drawMode
                        ? (tapPosition, point) {
                            _createGeofence(point.latitude, point.longitude);
                            setState(() => _drawMode = false);
                          }
                        : null,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.gps_tracker',
                    ),
                    // Geofence circles as markers with CircleLayer
                    CircleLayer(
                      circles: _geofences.map((gf) {
                        final lat = (gf['latitude'] as num).toDouble();
                        final lng = (gf['longitude'] as num).toDouble();
                        final radius = (gf['radius_meters'] as num).toDouble();
                        return CircleMarker(
                          point: LatLng(lat, lng),
                          radius: radius,
                          useRadiusInMeter: true,
                          color: Colors.blue.withOpacity(0.2),
                          borderColor: Colors.blue,
                          borderStrokeWidth: 2,
                        );
                      }).toList(),
                    ),
                    MarkerLayer(
                      markers: _geofences.map((gf) {
                        final lat = (gf['latitude'] as num).toDouble();
                        final lng = (gf['longitude'] as num).toDouble();
                        return Marker(
                          width: 120,
                          height: 40,
                          point: LatLng(lat, lng),
                          builder: (_) => Column(
                            children: [
                              Icon(Icons.location_on, color: Colors.blue, size: 24),
                              Text(gf['name'] ?? '', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        );
                      }).toList(),
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
}
