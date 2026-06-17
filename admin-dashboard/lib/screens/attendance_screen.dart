import 'package:flutter/material.dart';
import '../services/api_service.dart';

class AttendanceScreen extends StatefulWidget {
  final String token;
  AttendanceScreen({required this.token});

  @override
  _AttendanceScreenState createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  DateTime _selectedDate = DateTime.now();
  bool _loading = false;
  List<Map<String, dynamic>> _attendance = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAttendance();
  }

  Future<void> _loadAttendance() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final dateStr = _selectedDate.toIso8601String().split('T')[0];
    try {
      final data = await ApiService.getAttendance(widget.token, date: dateStr);
      setState(() {
        _attendance = data;
        _loading = false;
      });
    } catch (err) {
      setState(() {
        _error = 'Failed to load attendance: $err';
        _loading = false;
      });
    }
  }

  String _formatTime(String? isoString) {
    if (isoString == null) return '--';
    try {
      final dt = DateTime.parse(isoString).toLocal();
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return '$hh:$mm';
    } catch (_) {
      return '--';
    }
  }

  String _formatHours(dynamic hours) {
    if (hours == null) return '--';
    final h = (hours as num).toDouble();
    final hoursInt = h.floor();
    final minutes = ((h - hoursInt) * 60).round();
    return '${hoursInt}h ${minutes}m';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Attendance',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              SizedBox(width: 16),
              TextButton(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _selectedDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) {
                    setState(() => _selectedDate = picked);
                    _loadAttendance();
                  }
                },
                child: Text(_selectedDate.toIso8601String().split('T')[0]),
              ),
              SizedBox(width: 8),
              ElevatedButton(
                onPressed: _loading ? null : _loadAttendance,
                child: Text('Refresh'),
              ),
            ],
          ),
          SizedBox(height: 12),
          Expanded(
            child: _buildContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 40),
            SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Colors.red)),
            SizedBox(height: 12),
            ElevatedButton(onPressed: _loadAttendance, child: Text('Retry')),
          ],
        ),
      );
    }
    if (_attendance.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.event_busy, size: 48, color: Colors.grey),
            SizedBox(height: 12),
            Text(
              'No attendance records for ${_selectedDate.toIso8601String().split('T')[0]}',
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('Name', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Check-In', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Check-Out', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Hours in Field', style: TextStyle(fontWeight: FontWeight.bold))),
        ],
        rows: _attendance.map((a) {
          return DataRow(cells: [
            DataCell(Text(a['name'] ?? '--')),
            DataCell(Text(_formatTime(a['check_in'] as String?))),
            DataCell(Text(_formatTime(a['check_out'] as String?))),
            DataCell(Text(_formatHours(a['hours']))),
          ]);
        }).toList(),
      ),
    );
  }
}
