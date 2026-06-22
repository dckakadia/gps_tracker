class LocationPoint {
  final int userId;
  final String name;
  final double latitude;
  final double longitude;
  final String recordedAt;
  final String receivedAt;
  final bool isLive;
  final String? lastSeen;
  final bool? isOnline;
  final int? batteryLevel;
  // GPS quality fields
  final double? accuracy;       // metres
  final double? speed;          // m/s — raw GPS speed (may be 0 under poor signal)
  final double? heading;        // degrees
  final bool isFiltered;        // Kalman-smoothed
  // Derived speed fields
  final double? computedSpeed;  // m/s — server-derived speed (Haversine from consecutive points)
  final String? speedSource;    // 'gps' | 'derived' | 'none'

  LocationPoint({
    required this.userId,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.recordedAt,
    required this.receivedAt,
    required this.isLive,
    this.lastSeen,
    this.isOnline,
    this.batteryLevel,
    this.accuracy,
    this.speed,
    this.heading,
    this.isFiltered = false,
    this.computedSpeed,
    this.speedSource,
  });

  factory LocationPoint.fromJson(Map<String, dynamic> json) {
    return LocationPoint(
      userId:        json['user_id'] as int,
      name:          json['name'] as String? ?? '',
      latitude:      (json['latitude'] as num).toDouble(),
      longitude:     (json['longitude'] as num).toDouble(),
      recordedAt:    json['recorded_at'] as String? ?? '',
      receivedAt:    json['received_at'] as String? ?? '',
      isLive:        json['is_live'] as bool? ?? false,
      lastSeen:      json['last_seen'] as String? ?? json['received_at'] as String?,
      isOnline:      json['is_online'] as bool?,
      batteryLevel:  json['battery_level'] as int?,
      accuracy:      (json['accuracy'] as num?)?.toDouble(),
      speed:         (json['speed'] as num?)?.toDouble(),
      heading:       (json['heading'] as num?)?.toDouble(),
      isFiltered:    json['is_filtered'] as bool? ?? false,
      computedSpeed: (json['computed_speed'] as num?)?.toDouble(),
      speedSource:   json['speed_source'] as String?,
    );
  }

  /// Raw GPS speed in km/h.
  double? get speedKmh => speed != null ? speed! * 3.6 : null;

  /// Effective speed respecting priority: GPS → computed → null.
  /// Use this for display and polyline colouring.
  double? get effectiveSpeed {
    if (speedSource == 'gps') return speed;
    if (speedSource == 'derived') return computedSpeed ?? speed;
    // Fallback for old rows that predate the speed_source column.
    if (speed != null && speed! > 0) return speed;
    if (computedSpeed != null && computedSpeed! > 0) return computedSpeed;
    return null;
  }

  /// True when the displayed speed was derived from coordinates, not measured by GPS.
  bool get isSpeedDerived => speedSource == 'derived';
}
