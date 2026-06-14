import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/location_point.dart';
import '../services/api_service.dart';

class MapScreen extends StatefulWidget {
  final String token;
  MapScreen({required this.token});

  @override
  _MapScreenState createState() => _MapScreenState();
}

enum LocationFilterMode { all, liveOnly, staleOnly }

class _MapScreenState extends State<MapScreen> {
  List<LocationPoint> locations = [];
  late Timer _timer;
  bool isLoading = true;
  String? errorMessage;
  LocationFilterMode _filterMode = LocationFilterMode.all;
  DateTime? _lastUpdated;

  @override
  void initState() {
    super.initState();
    _fetchLocations();
    _timer = Timer.periodic(Duration(seconds: 12), (_) => _fetchLocations());
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  Future<void> _fetchLocations() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
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

  List<LocationPoint> get _filteredLocations {
    switch (_filterMode) {
      case LocationFilterMode.liveOnly:
        return locations.where((l) => l.isLive).toList();
      case LocationFilterMode.staleOnly:
        return locations.where((l) => !l.isLive).toList();
      case LocationFilterMode.all:
      default:
        return locations;
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredLocations = _filteredLocations;
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
                'No Users Available',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 8),
              Text(
                'No users match the selected filter.\nTry switching to Live + Stale.',
                style: TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 16),
              if (locations.isNotEmpty)
                Text(
                  'Total known users: ${locations.length}',
                  style: TextStyle(color: Colors.grey[700]),
                ),
              SizedBox(height: 16),
              if (_lastUpdated != null)
                Text(
                  'Last updated: ${_formatTimestamp(_lastUpdated!)}',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              SizedBox(height: 8),
              Text(
                'Refreshing every 12 seconds',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
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
              if (_lastUpdated != null)
                Text(
                  'Updated: ${_formatTimestamp(_lastUpdated!)}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
            ],
          ),
        ),
        Expanded(
          child: FlutterMap(
            options: MapOptions(
              center: LatLng(filteredLocations.first.latitude, filteredLocations.first.longitude),
              zoom: 5,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.gps_tracker',
              ),
              MarkerLayer(
                markers: filteredLocations.map((location) {
                  final markerColor = location.isLive ? Colors.red : Colors.grey;
                  return Marker(
                    width: 180,
                    height: 90,
                    point: LatLng(location.latitude, location.longitude),
                    builder: (_) => Column(
                      children: [
                        Icon(Icons.location_pin, color: markerColor, size: 36),
                        Container(
                          width: 150,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.9),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: markerColor.withOpacity(0.8)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(location.name,
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              SizedBox(height: 2),
                              Text(location.isLive ? 'Live location' : 'Last seen',
                                  style: TextStyle(fontSize: 10, color: Colors.black54)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatTimestamp(DateTime timestamp) {
    return '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}';
  }
}
