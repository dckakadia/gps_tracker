class StopPoint {
  final int? id;
  final double lat;
  final double lng;
  final String startTime;
  final String endTime;
  final int durationSeconds;

  StopPoint({
    this.id,
    required this.lat,
    required this.lng,
    required this.startTime,
    required this.endTime,
    required this.durationSeconds,
  });

  factory StopPoint.fromJson(Map<String, dynamic> json) {
    return StopPoint(
      id:              json['id'] as int?,
      lat:             (json['lat'] as num).toDouble(),
      lng:             (json['lng'] as num).toDouble(),
      startTime:       json['start_time'] as String,
      endTime:         json['end_time'] as String,
      durationSeconds: (json['duration_seconds'] as num).toInt(),
    );
  }

  String get durationLabel {
    final h = durationSeconds ~/ 3600;
    final m = (durationSeconds % 3600) ~/ 60;
    final s = durationSeconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }
}
