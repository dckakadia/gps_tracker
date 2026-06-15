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
  late MapController _mapController;
  bool isLoading = true;
  String? errorMessage;
  LocationFilterMode _filterMode = LocationFilterMode.all;
  DateTime? _lastUpdated;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _fetchLocations();
    _timer = Timer.periodic(Duration(seconds: 12), (_) => _fetchLocations());
  }

  @override
  void dispose() {
    _timer.cancel();
    _mapController.dispose();
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
            mapController: _mapController,
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

  void _autoZoomToMarkers(List<LocationPoint> markersToShow) {
    if (markersToShow.isEmpty) return;

    if (markersToShow.length == 1) {
      // Single marker: zoom to street level
      _mapController.move(
        LatLng(markersToShow[0].latitude, markersToShow[0].longitude),
        13.0,
      );
      return;
    }

    // Multiple markers: calculate bounds
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

    // Apply 10% padding
    final latDelta = maxLat - minLat;
    final lngDelta = maxLng - minLng;
    const padding = 0.1;
    minLat -= latDelta * padding;
    maxLat += latDelta * padding;
    minLng -= lngDelta * padding;
    maxLng += lngDelta * padding;

    // Calculate center and determine zoom
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
