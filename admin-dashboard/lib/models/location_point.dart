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
  });

  factory LocationPoint.fromJson(Map<String, dynamic> json) {
    return LocationPoint(
      userId: json['user_id'],
      name: json['name'],
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      recordedAt: json['recorded_at'],
      receivedAt: json['received_at'],
      isLive: json['is_live'] as bool? ?? false,
      lastSeen: json['last_seen'] as String? ?? json['received_at'] as String?,
      isOnline: json['is_online'] as bool? ?? null,
      batteryLevel: json['battery_level'] as int?,
    );
  }
}
