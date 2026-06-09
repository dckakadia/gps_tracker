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

class _MapScreenState extends State<MapScreen> {
  List<LocationPoint> locations = [];
  late Timer _timer;

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
    try {
      final result = await ApiService.getLatestLocations(widget.token);
      setState(() {
        locations = result;
      });
    } catch (_) {
      // ignore errors silently for polling
    }
  }

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      options: MapOptions(
        center: locations.isNotEmpty ? LatLng(locations.first.latitude, locations.first.longitude) : LatLng(0, 0),
        zoom: 5,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.gps_tracker',
        ),
        MarkerLayer(
          markers: locations.map((location) {
            return Marker(
              width: 60,
              height: 60,
              point: LatLng(location.latitude, location.longitude),
              builder: (_) => Icon(Icons.location_pin, color: Colors.red, size: 36),
            );
          }).toList(),
        ),
      ],
    );
  }
}
