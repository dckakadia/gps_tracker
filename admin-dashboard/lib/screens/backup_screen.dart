import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';

class BackupScreen extends StatefulWidget {
  final String token;

  BackupScreen({required this.token});

  @override
  _BackupScreenState createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  static const String baseUrl = 'http://192.168.2.101:4000/api';

  bool _isBackingUp = false;
  Map<String, dynamic>? _backupProgress;
  Timer? _statusCheckTimer;

  @override
  void initState() {
    super.initState();
    _checkBackupStatus();
  }

  @override
  void dispose() {
    _statusCheckTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkBackupStatus() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/backup/status'),
        headers: {'Authorization': 'Bearer ' + widget.token},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _backupProgress = data;
          _isBackingUp = data['running'] == true;
        });

        if (_isBackingUp && _statusCheckTimer == null) {
          _startPolling();
        } else if (!_isBackingUp && _statusCheckTimer != null) {
          _statusCheckTimer?.cancel();
          _statusCheckTimer = null;
        }
      }
    } catch (e) {
      print('Status check error: $e');
    }
  }

  void _startPolling() {
    _statusCheckTimer = Timer.periodic(Duration(seconds: 2), (timer) {
      _checkBackupStatus();
    });
  }

  Future<void> _startBackup() async {
    setState(() {
      _isBackingUp = true;
      _backupProgress = {
        'stage': 'Starting...',
        'overallPct': 0,
        'stageLabel': 'Preparing'
      };
    });

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/backup'),
        headers: {
          'Authorization': 'Bearer ' + widget.token,
          'Content-Type': 'application/json'
        },
      );

      if (response.statusCode == 200) {
        _startPolling();
      } else {
        final error = jsonDecode(response.body);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup failed: ${error['message']}')),
        );
        setState(() => _isBackingUp = false);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error starting backup: $e')),
      );
      setState(() => _isBackingUp = false);
    }
  }

  String _formatBytes(int? bytes) {
    if (bytes == null || bytes < 1) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatEta(int? seconds) {
    if (seconds == null || seconds <= 0) return 'Calculating...';
    if (seconds >= 3600) {
      final h = seconds ~/ 3600;
      final m = (seconds % 3600) ~/ 60;
      return '${h}h ${m}m';
    }
    if (seconds >= 60) {
      final m = seconds ~/ 60;
      final s = seconds % 60;
      return '${m}m ${s}s';
    }
    return '${seconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final status = _backupProgress?['lastStatus'];
    final isSuccess = status == 'success';
    final isFailed = status == 'failed';
    final isRunning = _isBackingUp && !isSuccess && !isFailed;

    Color getBackgroundGradientStart() {
      if (isSuccess) return const Color(0xFFecfdf5);
      if (isFailed) return const Color(0xFFFFF5F5);
      return const Color(0xFF1e1b4b);
    }

    Color getBackgroundGradientEnd() {
      if (isSuccess) return const Color(0xFFd1fae5);
      if (isFailed) return const Color(0xFFfee2e2);
      return const Color(0xFF312e81);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Google Drive Backup')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            if (_backupProgress != null)
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      getBackgroundGradientStart(),
                      getBackgroundGradientEnd(),
                    ],
                  ),
                  border: Border.all(
                    color: isSuccess
                        ? Colors.green.withOpacity(0.3)
                        : isFailed
                            ? Colors.red.withOpacity(0.3)
                            : Colors.indigo.withOpacity(0.3),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Text(
                                  isSuccess
                                      ? '✅ Backup Complete'
                                      : isFailed
                                          ? '❌ Backup Failed'
                                          : '☁️ Backing Up',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    color: isSuccess
                                        ? Colors.green[700]
                                        : isFailed
                                            ? Colors.red[700]
                                            : Colors.indigo[100],
                                  ),
                                ),
                                if (isRunning && _backupProgress?['stageLabel'] != null)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 8.0),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.indigo.withOpacity(0.15),
                                        borderRadius: BorderRadius.circular(99),
                                      ),
                                      child: Text(
                                        _backupProgress!['stageLabel'],
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.indigo[200],
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (isSuccess || isFailed)
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                setState(() => _backupProgress = null);
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // Success state
                      if (isSuccess) ...[
                        Text(
                          '✓ All files uploaded successfully to Google Drive',
                          style: TextStyle(color: Colors.green[700], fontSize: 13),
                        ),
                        const SizedBox(height: 4),
                        if (_backupProgress?['lastTimestamp'] != null)
                          Text(
                            'Completed: ${DateTime.parse(_backupProgress!['lastTimestamp']).toLocal()}',
                            style: TextStyle(color: Colors.green[700], fontSize: 12),
                          ),
                      ],

                      // Failed state
                      if (isFailed) ...[
                        Text(
                          _backupProgress?['lastError'] ?? 'Unknown error occurred',
                          style: TextStyle(color: Colors.red[700], fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry Backup'),
                          onPressed: _startBackup,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red[600],
                          ),
                        ),
                      ],

                      // In-progress state
                      if (isRunning) ...[
                        Text(
                          _backupProgress?['stage'] ?? 'Initializing...',
                          style: TextStyle(
                            color: Colors.indigo[100],
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            value: (_backupProgress?['overallPct'] ?? 0) / 100,
                            minHeight: 10,
                            backgroundColor: Colors.white.withOpacity(0.1),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.indigo[400]!,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text(
                              '${_backupProgress?['overallPct'] ?? 0}%',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                color: Colors.indigo,
                              ),
                            ),
                            const SizedBox(width: 16),
                            if (_backupProgress?['totalFiles'] != null)
                              Text(
                                '📁 ${_backupProgress!['processedFiles'] ?? 0}/${_backupProgress!['totalFiles']}',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.indigo[200]),
                              ),
                            const SizedBox(width: 16),
                            if (_backupProgress?['totalBytesLabel'] != null)
                              Text(
                                '💾 ${_backupProgress!['uploadedBytesLabel'] ?? '0 B'}/${_backupProgress!['totalBytesLabel']}',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.indigo[200]),
                              ),
                            const SizedBox(width: 16),
                            if (_backupProgress?['etaSeconds'] != null)
                              Text(
                                '⏱ ${_formatEta(_backupProgress!['etaSeconds'])}',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.indigo[200]),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: _isBackingUp ? const Icon(Icons.hourglass_empty) : const Icon(Icons.backup),
              label: Text(_isBackingUp ? 'Backup in Progress...' : 'Start Backup Now'),
              onPressed: _isBackingUp ? null : _startBackup,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
                backgroundColor: Colors.indigo[600],
                disabledBackgroundColor: Colors.grey[400],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
