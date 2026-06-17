// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../services/api_service.dart';

class AppManagementScreen extends StatefulWidget {
  final String token;
  const AppManagementScreen({required this.token});

  @override
  _AppManagementScreenState createState() => _AppManagementScreenState();
}

class _AppManagementScreenState extends State<AppManagementScreen> {
  bool _loadingVersion = true;
  bool _uploading = false;
  Map<String, dynamic>? _versionInfo;
  String? _errorMsg;

  final _versionController = TextEditingController();
  final _versionCodeController = TextEditingController();
  final _releaseNotesController = TextEditingController();

  Uint8List? _selectedFileBytes;
  String? _selectedFileName;

  @override
  void initState() {
    super.initState();
    _loadVersionInfo();
  }

  @override
  void dispose() {
    _versionController.dispose();
    _versionCodeController.dispose();
    _releaseNotesController.dispose();
    super.dispose();
  }

  Future<void> _loadVersionInfo() async {
    setState(() { _loadingVersion = true; _errorMsg = null; });
    try {
      final info = await ApiService.getAppVersion();
      setState(() { _versionInfo = info; });
    } catch (e) {
      setState(() { _errorMsg = e.toString(); });
    } finally {
      setState(() { _loadingVersion = false; });
    }
  }

  void _pickApkFile() {
    final input = html.FileUploadInputElement()..accept = '.apk';
    input.click();
    input.onChange.listen((event) {
      final file = input.files?.first;
      if (file == null) return;
      final reader = html.FileReader();
      reader.readAsArrayBuffer(file);
      reader.onLoadEnd.listen((_) {
        setState(() {
          _selectedFileBytes = reader.result as Uint8List;
          _selectedFileName = file.name;
        });
      });
    });
  }

  Future<void> _uploadApk() async {
    final version = _versionController.text.trim();
    final versionCode = _versionCodeController.text.trim();
    final releaseNotes = _releaseNotesController.text.trim();

    if (version.isEmpty || versionCode.isEmpty) {
      _showSnack('Version and Version Code are required', isError: true);
      return;
    }
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      _showSnack('Version must be in X.Y.Z format (e.g. 1.0.2)', isError: true);
      return;
    }
    if (_selectedFileBytes == null || _selectedFileName == null) {
      _showSnack('Please select an APK file first', isError: true);
      return;
    }

    setState(() { _uploading = true; });
    try {
      await ApiService.uploadApk(
        widget.token,
        version: version,
        versionCode: versionCode,
        releaseNotes: releaseNotes,
        fileBytes: _selectedFileBytes!,
        fileName: _selectedFileName!,
      );
      _showSnack('APK uploaded successfully as gpstracker_ver_${version.replaceAll('.', '_')}.apk');
      _versionController.clear();
      _versionCodeController.clear();
      _releaseNotesController.clear();
      setState(() { _selectedFileBytes = null; _selectedFileName = null; });
      await _loadVersionInfo();
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    } finally {
      setState(() { _uploading = false; });
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red[700] : Colors.green[700],
      behavior: SnackBarBehavior.floating,
    ));
  }

  String _downloadUrl(String fileName) {
    const base = String.fromEnvironment('API_URL', defaultValue: '/api');
    return '$base/app/download/$fileName';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(Icons.phone_android, 'Current App Version', const Color(0xFF1976D2)),
            const SizedBox(height: 12),
            _versionCard(),
            const SizedBox(height: 24),
            _sectionHeader(Icons.upload, 'Upload New APK', const Color(0xFF388E3C)),
            const SizedBox(height: 12),
            _uploadCard(),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(IconData icon, String title, Color color) {
    return Row(
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }

  Widget _versionCard() {
    if (_loadingVersion) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_errorMsg != null) {
      return Card(
        color: Colors.red[50],
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.red),
              const SizedBox(width: 12),
              Expanded(child: Text(_errorMsg!, style: const TextStyle(color: Colors.red))),
              TextButton(onPressed: _loadVersionInfo, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final info = _versionInfo;
    final hasRelease = info != null && (info['fileName'] ?? '').isNotEmpty;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: hasRelease
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _infoRow(Icons.tag, 'Version', 'v${info!['latestVersion']}', const Color(0xFF1976D2)),
                  const Divider(height: 20),
                  _infoRow(Icons.numbers, 'Version Code', '${info['versionCode']}', Colors.grey[700]!),
                  const Divider(height: 20),
                  _infoRow(Icons.insert_drive_file, 'File', info['fileName'], Colors.grey[700]!),
                  if ((info['releaseNotes'] ?? '').isNotEmpty) ...[
                    const Divider(height: 20),
                    _infoRow(Icons.notes, 'Release Notes', info['releaseNotes'], Colors.grey[700]!),
                  ],
                  if ((info['updatedAt'] ?? '').isNotEmpty) ...[
                    const Divider(height: 20),
                    _infoRow(Icons.schedule, 'Released', _formatDate(info['updatedAt']), Colors.grey[600]!),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.download),
                      label: Text('Download ${info['fileName']}'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF1976D2),
                        side: const BorderSide(color: Color(0xFF1976D2)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () {
                        html.window.open(_downloadUrl(info['fileName']), '_blank');
                      },
                    ),
                  ),
                ],
              )
            : const Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.grey),
                  SizedBox(width: 12),
                  Text('No APK uploaded yet.', style: TextStyle(color: Colors.grey)),
                ],
              ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value, Color valueColor) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: Colors.grey[500]),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[500], fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(value, style: TextStyle(fontSize: 14, color: valueColor, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _uploadCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _inputField(
                    controller: _versionController,
                    label: 'Version (X.Y.Z)',
                    hint: 'e.g. 1.0.2',
                    icon: Icons.tag,
                    keyboardType: TextInputType.visiblePassword,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _inputField(
                    controller: _versionCodeController,
                    label: 'Version Code',
                    hint: 'e.g. 102',
                    icon: Icons.numbers,
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _inputField(
              controller: _releaseNotesController,
              label: 'Release Notes (optional)',
              hint: "What's new in this version...",
              icon: Icons.notes,
              maxLines: 3,
            ),
            const SizedBox(height: 16),
            // File picker
            GestureDetector(
              onTap: _pickApkFile,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _selectedFileName != null ? const Color(0xFF388E3C) : Colors.grey[300]!,
                    width: 1.5,
                  ),
                  borderRadius: BorderRadius.circular(8),
                  color: _selectedFileName != null ? Colors.green[50] : Colors.grey[50],
                ),
                child: Row(
                  children: [
                    Icon(
                      _selectedFileName != null ? Icons.check_circle : Icons.upload_file,
                      color: _selectedFileName != null ? const Color(0xFF388E3C) : Colors.grey[500],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _selectedFileName ?? 'Click to select APK file',
                        style: TextStyle(
                          color: _selectedFileName != null ? const Color(0xFF388E3C) : Colors.grey[600],
                          fontWeight: _selectedFileName != null ? FontWeight.w600 : FontWeight.normal,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_selectedFileName != null)
                      Text(
                        '${(_selectedFileBytes!.length / 1024 / 1024).toStringAsFixed(1)} MB',
                        style: TextStyle(color: Colors.grey[500], fontSize: 12),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: _uploading
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.cloud_upload),
                label: Text(_uploading ? 'Uploading...' : 'Upload APK'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF388E3C),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                onPressed: _uploading ? null : _uploadApk,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inputField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 20),
        filled: true,
        fillColor: Colors.grey[50],
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF1976D2), width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        labelStyle: TextStyle(color: Colors.grey[700]),
      ),
    );
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.day}/${dt.month}/${dt.year}  ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}
