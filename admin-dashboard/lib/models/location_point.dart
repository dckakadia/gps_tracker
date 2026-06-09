class LocationPoint {
  final int userId;
  final String name;
  final double latitude;
  final double longitude;
  final String recordedAt;
  final String receivedAt;

  LocationPoint({
    required this.userId,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.recordedAt,
    required this.receivedAt,
  });

  factory LocationPoint.fromJson(Map<String, dynamic> json) {
    return LocationPoint(
      userId: json['user_id'],
      name: json['name'],
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      recordedAt: json['recorded_at'],
      receivedAt: json['received_at'],
    );
  }
}
