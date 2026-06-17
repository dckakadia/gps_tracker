// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

class AttendanceScreen extends StatefulWidget {
  final String token;
  const AttendanceScreen({required this.token});

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAttendance());
  }

  Future<void> _loadAttendance() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    final dateStr = _selectedDate.toIso8601String().split('T')[0];
    try {
      final data = await ApiService.getAttendance(widget.token, date: dateStr);
      if (!mounted) return;
      setState(() { _attendance = data; _loading = false; });
    } catch (err) {
      if (!mounted) return;
      setState(() { _error = err.toString(); _loading = false; });
    }
  }

  void _exportCsv() {
    if (!kIsWeb) return;
    final dateStr = _selectedDate.toIso8601String().split('T')[0];
    final url = '${ApiService.baseUrl}/admin/attendance/export?date=$dateStr&token=${widget.token}';
    html.window.open(url, '_blank');
  }

  String _formatTime(String? isoString) {
    if (isoString == null) return '--';
    try {
      final dt = DateTime.parse(isoString).toLocal();
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) { return '--'; }
  }

  String _formatHours(dynamic hours) {
    if (hours == null) return '--';
    // PostgreSQL EXTRACT returns numeric → node-postgres sends it as a JS string
    final double h;
    if (hours is num) {
      h = hours.toDouble();
    } else {
      h = double.tryParse(hours.toString()) ?? 0.0;
    }
    final hoursInt = h.floor();
    final minutes = ((h - hoursInt) * 60).round();
    return '${hoursInt}h ${minutes}m';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header bar ────────────────────────────────────────────────
        Container(
          color: AppTheme.surface,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              const Icon(Icons.today, size: 20, color: AppTheme.primaryLight),
              const SizedBox(width: 10),
              const Text('Attendance', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppTheme.textDark)),
              const SizedBox(width: 16),
              // Date picker button
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today, size: 14),
                label: Text(_selectedDate.toIso8601String().split('T')[0],
                    style: const TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primaryLight,
                  side: const BorderSide(color: AppTheme.border),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
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
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh, size: 15),
                label: const Text('Refresh'),
                onPressed: _loading ? null : _loadAttendance,
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.download, size: 15),
                label: const Text('Export CSV'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primaryLight,
                  side: const BorderSide(color: AppTheme.border),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                onPressed: (_loading || _attendance.isEmpty) ? null : _exportCsv,
              ),
              const Spacer(),
              // Summary chip
              if (!_loading && _attendance.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.successLight,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text('${_attendance.length} staff',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.success)),
                ),
            ],
          ),
        ),
        const Divider(height: 1),

        // ── Content ───────────────────────────────────────────────────
        Expanded(child: _buildContent()),
      ],
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: AppTheme.error, size: 40),
              const SizedBox(height: 12),
              Text('Failed to load attendance', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(_error!, style: const TextStyle(color: AppTheme.textMedium, fontSize: 13), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh, size: 15),
                label: const Text('Retry'),
                onPressed: _loadAttendance,
              ),
            ],
          ),
        ),
      );
    }

    if (_attendance.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(color: AppTheme.background, shape: BoxShape.circle),
              child: const Icon(Icons.event_busy_outlined, size: 32, color: AppTheme.textLight),
            ),
            const SizedBox(height: 14),
            const Text('No attendance records', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
            const SizedBox(height: 6),
            Text('No data for ${_selectedDate.toIso8601String().split('T')[0]}',
                style: const TextStyle(fontSize: 13, color: AppTheme.textMedium)),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStateProperty.all(AppTheme.background),
            headingTextStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppTheme.textDark),
            dataTextStyle: const TextStyle(fontSize: 13, color: AppTheme.textDark),
            columns: const [
              DataColumn(label: Text('Name')),
              DataColumn(label: Text('Check-In')),
              DataColumn(label: Text('Check-Out')),
              DataColumn(label: Text('Hours in Field')),
              DataColumn(label: Text('Status')),
            ],
            rows: _attendance.map((a) {
              final checkIn = a['check_in'] as String?;
              final checkOut = a['check_out'] as String?;
              final hours = a['hours'];
              final present = checkIn != null;
              return DataRow(cells: [
                DataCell(Row(children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: AppTheme.primaryLight.withOpacity(0.12),
                    child: Text((a['name'] as String? ?? '?')[0].toUpperCase(),
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.primaryLight)),
                  ),
                  const SizedBox(width: 8),
                  Text(a['name'] ?? '--', style: const TextStyle(fontWeight: FontWeight.w600)),
                ])),
                DataCell(Text(_formatTime(checkIn))),
                DataCell(Text(_formatTime(checkOut))),
                DataCell(Text(_formatHours(hours))),
                DataCell(Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: present ? AppTheme.successLight : AppTheme.errorLight,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    present ? 'Present' : 'Absent',
                    style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600,
                      color: present ? AppTheme.success : AppTheme.error,
                    ),
                  ),
                )),
              ]);
            }).toList(),
          ),
        ),
      ),
    );
  }
}
